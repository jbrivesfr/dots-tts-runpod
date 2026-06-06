#!/bin/bash
# download-model.sh — Download dots.tts model from HuggingFace
# Runs during Docker build to cache weights in the image
set -e

MODEL_DIR="/app/model"
mkdir -p "$MODEL_DIR"

# Download the pretrained checkpoint from HuggingFace
# dots.tts provides checkpoints at: https://huggingface.co/collections/rednote-hilab/dotstts
# Using the MeanFlow-distilled checkpoint for faster inference
echo "📥 Downloading dots.tts MeanFlow-distilled checkpoint..."
python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    'rednote-hilab/dots-tts-meanflow-distilled',
    local_dir='$MODEL_DIR',
    local_dir_use_symlinks=False,
    ignore_patterns=['*.safetensors.index.json']
)
" 2>/dev/null || {
    # Fallback: if huggingface_hub not available, download minimal
    echo "⚠️  huggingface_hub not available in build — will download at first start"
    touch "$MODEL_DIR/.pending-download"
}

echo "✅ Model setup complete"
