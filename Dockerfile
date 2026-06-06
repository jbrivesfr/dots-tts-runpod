# dots.tts RunPod Serverless — Clean (no conda)
# Built by GitHub Actions, deployed to RunPod Serverless
#
# GPU: RTX A4000+ (16GB+ VRAM)
# Min workers: 0 (scale to zero)
# Idle timeout: 120s
# Execution timeout: 180s

FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

# Python 3.10 + system deps (git needed for pip package metadata)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 python3-pip python3.10-dev \
    git curl ca-certificates ffmpeg \
    && ln -sf /usr/bin/python3.10 /usr/bin/python3 \
    && ln -sf /usr/bin/python3.10 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install PyTorch with CUDA (constraints version: 2.8.0)
RUN pip3 install --no-cache-dir \
    torch==2.8.0 torchaudio==2.8.0 \
    --index-url https://download.pytorch.org/whl/cu128

# Install RunPod worker SDK
RUN pip3 install --no-cache-dir runpod

# Clone dots.tts
RUN git clone https://github.com/rednote-hilab/dots.tts.git /app/dots-tts

# Install remaining constraints (skip torch/torchaudio already installed)
RUN pip3 install --no-cache-dir \
    transformers==4.57.0 \
    huggingface-hub \
    librosa==0.11.0 \
    soundfile==0.13.1 \
    numpy==2.2.6 \
    pydantic==2.12.5 \
    PyYAML==6.0.3 \
    safetensors==0.8.0rc0 \
    accelerate==1.12.0

# Install deps NOT in constraints but required by dots.tts
RUN pip3 install --no-cache-dir \
    loguru \
    langcodes \
    gradio \
    einops \
    torchdiffeq \
    tqdm \
    lingua-language-detector \
    WeTextProcessing

# Symlink dots_tts into site-packages (pip install broken for this package)
RUN ln -s /app/dots-tts/src/dots_tts /usr/local/lib/python3.10/dist-packages/dots_tts

# Verify transformers version
RUN python3 -c "import transformers; print(f'✅ transformers=={transformers.__version__}')"

# Copy worker and model downloader
COPY handler.py /app/handler.py
COPY download-model.sh /app/download-model.sh

# Download model during build
RUN bash /app/download-model.sh || echo "⚠️ Model will download on first request"

# Voices (empty at build, downloaded at runtime from FTP via env vars)
RUN mkdir -p /app/voices

WORKDIR /app
ENV MODEL_DIR=/app/model
ENV VOICES_DIR=/app/voices

# RunPod entrypoint
CMD ["python3", "/app/handler.py"]
