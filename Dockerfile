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

# Install PyTorch with CUDA 12.4 (no conda!)
RUN pip3 install --no-cache-dir \
    torch==2.6.0 torchaudio==2.6.0 \
    --index-url https://download.pytorch.org/whl/cu124

# Install RunPod worker SDK + soundfile
RUN pip3 install --no-cache-dir runpod soundfile

# Clone dots.tts and install deps
RUN git clone https://github.com/rednote-hilab/dots.tts.git /app/dots-tts
RUN pip3 install --no-cache-dir -r /app/dots-tts/constraints/recommended.txt
ENV PYTHONPATH="/app/dots-tts/src:${PYTHONPATH}"

# Verify transformers version
RUN python3 -c "import transformers; print(f'✅ transformers=={transformers.__version__}')"

# Copy worker and model downloader
COPY handler.py /app/handler.py
COPY download-model.sh /app/download-model.sh

# Download model during build
RUN bash /app/download-model.sh || echo "⚠️ Model will download on first request"

# Voices
RUN mkdir -p /app/voices
COPY voices/ /app/voices/

WORKDIR /app
ENV MODEL_DIR=/app/model
ENV VOICES_DIR=/app/voices

# RunPod entrypoint
CMD ["python3", "/app/handler.py"]
