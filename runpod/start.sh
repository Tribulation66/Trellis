#!/usr/bin/env bash
set -euo pipefail

echo "[trellis] start.sh begin"
echo "[trellis] pwd: $(pwd)"

# Ensure we are in repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Hugging Face cache (RunPod volume-friendly)
export HF_HOME="${HF_HOME:-/workspace/.cache/huggingface}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-$HF_HOME/hub}"

# Optional: user supplies token via env at pod launch; do NOT hardcode tokens.
# export HF_TOKEN=...
# export HUGGINGFACE_HUB_TOKEN=...

# Create/activate conda env if missing
if ! /opt/conda/bin/conda env list | awk '{print $1}' | grep -qx trellis2; then
  echo "[trellis] creating conda env trellis2"
  /opt/conda/bin/conda create -y -n trellis2 python=3.10
fi

echo "[trellis] installing deps"
# Use conda run to avoid needing interactive activation
/opt/conda/bin/conda run -n trellis2 python -m pip install -U pip setuptools wheel

# Core Python deps from repo (if you hav
