# dots.tts RunPod Serverless — Queue-Based Worker
# Built by GitHub Actions, deployed to RunPod Serverless
#
# GPU: RTX A4000+ (16GB+ VRAM)
# Min workers: 0 (scale to zero)
# Idle timeout: 120s
# Execution timeout: 180s

FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-runtime

# System deps for dots.tts + ffmpeg for opus conversion
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install RunPod worker SDK + soundfile for WAV output
RUN pip install --no-cache-dir runpod soundfile

# Clone and install dots.tts
RUN git clone https://github.com/rednote-hilab/dots.tts.git /app/dots-tts
WORKDIR /app/dots-tts
RUN pip install --no-cache-dir -e .

# Copy worker and model downloader
COPY handler.py /app/handler.py
COPY download-model.sh /app/download-model.sh

# Download model during build (cached in image)
RUN bash /app/download-model.sh || echo "⚠️ Model will download on first request"

# Voices directory for voice cloning samples (optional)
RUN mkdir -p /app/voices
COPY voices/ /app/voices/

WORKDIR /app
ENV MODEL_DIR=/app/model
ENV VOICES_DIR=/app/voices

# RunPod Queue-Based Serverless entrypoint
CMD ["python", "/app/handler.py"]
