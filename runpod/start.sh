#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[trellis] $*"; }

log "start.sh begin"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
log "repo: $REPO_ROOT"

# Hugging Face cache
export HF_HOME="${HF_HOME:-/workspace/.cache/huggingface}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-$HF_HOME/hub}"

# Submodules (eigen)
if [ -f .gitmodules ]; then
  log "updating git submodules"
  git submodule update --init --recursive
fi

# System deps for builds + ssh access
log "installing apt dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  git curl ca-certificates bzip2 \
  build-essential pkg-config ninja-build \
  libjpeg-dev ffmpeg \
  openssh-server
rm -rf /var/lib/apt/lists/*

# Install Miniconda (base image does not guarantee conda)
CONDA_DIR="/opt/conda"
if [ ! -x "$CONDA_DIR/bin/conda" ]; then
  log "installing Miniconda to $CONDA_DIR"
  curl -fsSL "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh" -o /tmp/miniconda.sh
  bash /tmp/miniconda.sh -b -p "$CONDA_DIR"
  rm -f /tmp/miniconda.sh
fi
export PATH="$CONDA_DIR/bin:$PATH"
# shellcheck disable=SC1091
source "$CONDA_DIR/etc/profile.d/conda.sh"

# Accept Anaconda Terms of Service (required for non-interactive conda operations)
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r || true
conda config --set always_yes yes || true


# Create env
if ! conda env list | awk '{print $1}' | grep -qx trellis2; then
  log "creating conda env trellis2 (python 3.10)"
  conda create -y -n trellis2 python=3.10
fi

log "upgrading pip tooling"
conda run -n trellis2 python -m pip install -U pip setuptools wheel

# Torch/Torchvision
log "installing torch + torchvision (cu124)"
conda run -n trellis2 python -m pip install \
  torch==2.6.0 torchvision==0.21.0 \
  --index-url https://download.pytorch.org/whl/cu124

# Basic deps (matches setup.sh --basic)
log "installing basic python deps"
conda run -n trellis2 python -m pip install \
  imageio imageio-ffmpeg tqdm easydict opencv-python-headless ninja trimesh transformers \
  gradio==6.0.1 tensorboard pandas lpips zstandard kornia timm
conda run -n trellis2 python -m pip install \
  "git+https://github.com/EasternJournalist/utils3d.git@9a4eb15e4021b67b12c460c7057d642626897ec8"
conda run -n trellis2 python -m pip install pillow-simd

# Required: flash-attn (no fallback)
log "installing flash-attn (required)"
export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-8.6}"
export MAX_JOBS="${MAX_JOBS:-8}"
conda run -n trellis2 python -m pip install --no-build-isolation --no-cache-dir flash-attn==2.7.3

# GPU extensions
mkdir -p /tmp/extensions

log "installing nvdiffrast"
rm -rf /tmp/extensions/nvdiffrast
git clone -b v0.4.0 https://github.com/NVlabs/nvdiffrast.git /tmp/extensions/nvdiffrast
conda run -n trellis2 python -m pip install /tmp/extensions/nvdiffrast --no-build-isolation

log "installing nvdiffrec_render"
rm -rf /tmp/extensions/nvdiffrec
git clone -b renderutils https://github.com/JeffreyXiang/nvdiffrec.git /tmp/extensions/nvdiffrec
conda run -n trellis2 python -m pip install /tmp/extensions/nvdiffrec --no-build-isolation

log "installing CuMesh"
rm -rf /tmp/extensions/CuMesh
git clone https://github.com/JeffreyXiang/CuMesh.git /tmp/extensions/CuMesh --recursive
conda run -n trellis2 python -m pip install /tmp/extensions/CuMesh --no-build-isolation

log "installing o-voxel"
rm -rf /tmp/extensions/o-voxel
cp -r "$REPO_ROOT/o-voxel" /tmp/extensions/o-voxel
conda run -n trellis2 python -m pip install /tmp/extensions/o-voxel --no-build-isolation

# Ensure repo modules importable
export PYTHONPATH="$REPO_ROOT:${PYTHONPATH:-}"

log "smoke test imports"
conda run -n trellis2 python - <<'PY'
import torch
print("torch:", torch.__version__, "cuda:", torch.cuda.is_available())
import flash_attn
import cumesh
import nvdiffrast.torch as dr
from nvdiffrec_render.light import EnvironmentLight
import o_voxel
import trellis2
print("imports OK")
PY

log "installing root authorized_keys (for direct TCP SSH/SCP)";
mkdir -p /root/.ssh;
chmod 700 /root/.ssh;
print qq(ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN2xm322pjDE8ijQPS0nut4Up+maDxkO1LIVzaYuO8o5 tribulation66official@gmail.com
) > "/root/.ssh/authorized_keys";
chmod 600 /root/.ssh/authorized_keys;

log "starting sshd (keeps container alive)"
ssh-keygen -A
mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e