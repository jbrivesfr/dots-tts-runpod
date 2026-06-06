# dots.tts → RunPod Serverless

2B-parameter TTS with zero-shot voice cloning, deployed on-demand.

## Architecture

```
Agent (Mac mini / iMac)
  │
  │  POST /generate {"text":"...", "voice":"jb"}
  ▼
RunPod Serverless (RTX 3060, $0.19/hr)
  │
  │  dots.tts 2B @ FP16 (~4GB VRAM)
  ▼
WAV/Opus audio → WhatsApp voice message
```

## Quick Start

### 1. Deploy to RunPod

```bash
# Get API key from https://www.runpod.io/console/user/api-keys
export RUNPOD_API_KEY="your-key"

# Build & push Docker image
docker build -t dots-tts-runpod .
docker tag dots-tts-runpod yourdockerhub/dots-tts-runpod:latest
docker push yourdockerhub/dots-tts-runpod:latest

# Go to https://www.runpod.io/console/serverless
# → Create Serverless
# → Image: yourdockerhub/dots-tts-runpod:latest
# → GPU: RTX 3060 (6GB)
# → Min workers: 0 (scale to zero when idle)
# → Idle timeout: 60s
# → Max workers: 2
```

### 2. Upload voice samples (optional)

Add `.wav` reference files to `/app/voices/` for voice cloning:
```
/app/voices/jb.wav     # 5-10s of JB speaking
/app/voices/jb.txt     # Transcript of the reference audio
```

### 3. Configure agents

```bash
# Big Bot, Lucy, Luna, Blade — add to ~/.bashrc:
export DOTS_TTS_ENDPOINT="https://your-endpoint.runpod.io/generate"
export DOTS_TTS_VOICE="jb"
export DOTS_TTS_FORMAT="opus"
```

### 4. Use it

```bash
# From any agent:
source client.sh https://your-endpoint.runpod.io/generate
dots-tts "Bonjour JB, voici ton briefing du matin." --voice jb
```

## Cost

| GPU | $/hr | Gen time (10s audio) | Cost/msg | $5 = |
|-----|------|---------------------|----------|------|
| RTX 3060 (6GB) | $0.19 | ~6s | <$0.001 | 5000+ msgs |
| RTX 4090 (24GB) | $0.79 | ~2s | <$0.001 | 1200+ msgs |

Scale-to-zero: $0 when not generating.

## Features

- ✅ 24 languages including French
- ✅ Zero-shot voice cloning
- ✅ 48 kHz output
- ✅ Emotional expressiveness
- ✅ Whisper support
- ✅ Apache 2.0 license

## Troubleshooting

- **Cold start:** First request after idle timeout takes ~30s (model load)
- **Voice not found:** Upload `.wav` to `/app/voices/` and rebuild
- **CUDA OOM:** Use RTX 3060+ (6GB+ VRAM)
