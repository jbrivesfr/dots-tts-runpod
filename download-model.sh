#!/bin/bash
# download-model.sh — Download dots.tts model during Docker build
# This pre-caches the 2B model so cold starts are fast (~30s vs ~5min)
set -e

MODEL_DIR="${MODEL_DIR:-/app/model}"
mkdir -p "$MODEL_DIR"

echo "📥 Downloading dots.tts MeanFlow-distilled model..."
python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    'rednote-hilab/dots.tts-soar',
    local_dir='$MODEL_DIR',
    local_dir_use_symlinks=False
)
print(f'✅ Model downloaded to $MODEL_DIR')
" || {
    echo "⚠️  Could not download model — will download on first request"
    touch "$MODEL_DIR/.pending-download"
}
