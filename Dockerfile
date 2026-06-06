# dots.tts RunPod Serverless Worker
# Build: docker build -t dots-tts-runpod .
# Push:  docker tag dots-tts-runpod youruser/dots-tts-runpod:latest && docker push
# 
# GPU: RTX 3060+ (6GB+ VRAM)
# Min workers: 0 (scale to zero)
# Idle timeout: 120s
# Execution timeout: 120s

FROM nvidia/cuda:12.4-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 python3-pip python3.10-dev git curl ca-certificates ffmpeg \
    && ln -sf /usr/bin/python3.10 /usr/bin/python3 \
    && ln -sf /usr/bin/python3.10 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install PyTorch with CUDA 12.4
RUN pip3 install --no-cache-dir \
    torch==2.6.0 torchaudio==2.6.0 \
    --index-url https://download.pytorch.org/whl/cu124

# Install runpod worker SDK
RUN pip3 install --no-cache-dir runpod

# Clone and install dots.tts
RUN git clone https://github.com/rednote-hilab/dots.tts.git /app/dots-tts
WORKDIR /app/dots-tts
RUN pip3 install --no-cache-dir -e .

# Copy worker
COPY handler.py /app/handler.py
COPY download-model.sh /app/download-model.sh

# Download model
RUN bash /app/download-model.sh || echo "Model download will happen on first request"

# Voices directory (mount or build-time copy)
RUN mkdir -p /app/voices
COPY voices/ /app/voices/ 2>/dev/null || echo "No pre-loaded voices"

WORKDIR /app
ENV MODEL_DIR=/app/model
ENV VOICES_DIR=/app/voices

# RunPod Serverless entrypoint
CMD ["python3", "/app/handler.py"]
