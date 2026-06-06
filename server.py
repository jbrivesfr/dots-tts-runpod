#!/usr/bin/env python3
"""
dots.tts Serverless API — RunPod-compatible
POST /generate  {"text": "...", "voice": "jb" | null}  →  WAV audio
GET  /health    →  {"status": "ok"}
GET  /voices    →  ["jb", "default"]
"""

import os
import io
import json
import time
import tempfile
import subprocess
import hashlib
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel
from typing import Optional
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("dots-tts-server")

app = FastAPI(title="dots.tts API")

# ── Config ──────────────────────────────────────────
MODEL_DIR = Path(os.environ.get("MODEL_DIR", "/app/model"))
VOICES_DIR = Path(os.environ.get("VOICES_DIR", "/app/voices"))
DEFAULT_MODEL = "rednote-hilab/dots.tts-soar"

# Check if model was pre-downloaded
MODEL_READY = (MODEL_DIR / "pytorch_model.bin").exists() or \
              (MODEL_DIR / "model.safetensors").exists() or \
              len(list(MODEL_DIR.glob("*.safetensors"))) > 0

if not MODEL_READY:
    logger.warning("Model not pre-downloaded — will download on first request (this is slow)")

# Model cache
_model = None
_model_path = None

def get_runtime():
    """Lazy-load the dots.tts model runtime."""
    global _model, _model_path
    
    if _model is not None:
        return _model
    
    logger.info("Loading dots.tts model runtime...")
    start = time.time()
    
    try:
        from dots_tts.runtime import DotsTtsRuntime
        model_path = str(MODEL_DIR) if MODEL_READY else DEFAULT_MODEL
        _model = DotsTtsRuntime.from_pretrained(
            model_path,
            precision="float16",
        )
        logger.info(f"Model loaded from: {model_path}")
    except ImportError as e:
        logger.warning(f"dots.tts Python API unavailable: {e} — falling back to CLI")
        _model = "cli"
    except Exception as e:
        logger.error(f"Failed to load model: {e}")
        raise HTTPException(status_code=500, detail=f"Model load failed: {e}")
    
    elapsed = time.time() - start
    logger.info(f"Model loaded in {elapsed:.1f}s")
    return _model


class GenerateRequest(BaseModel):
    text: str
    voice: Optional[str] = "default"
    speed: Optional[float] = 1.0
    format: Optional[str] = "wav"
    num_steps: Optional[int] = 10


@app.get("/health")
def health():
    return {"status": "ok", "model_ready": MODEL_READY}

@app.get("/ping")
def ping():
    """RunPod LB health check."""
    return {"status": "ok"}


@app.get("/voices")
def list_voices():
    voices = ["default"]
    if VOICES_DIR.exists():
        voices.extend([
            p.stem for p in VOICES_DIR.glob("*.wav")
        ])
    return {"voices": voices}


@app.post("/generate")
def generate(req: GenerateRequest):
    if not req.text.strip():
        raise HTTPException(status_code=400, detail="text is required")
    
    text = req.text.strip()
    voice = req.voice or "default"
    
    logger.info(f"Generate: voice={voice}, text_len={len(text)}")
    start = time.time()
    
    runtime = get_runtime()
    
    # Prepare reference audio for voice cloning
    prompt_audio = None
    prompt_text = None
    
    if voice != "default":
        ref_path = VOICES_DIR / f"{voice}.wav"
        ref_txt_path = VOICES_DIR / f"{voice}.txt"
        if ref_path.exists():
            prompt_audio = str(ref_path)
            if ref_txt_path.exists():
                prompt_text = ref_txt_path.read_text().strip()
            logger.info(f"Voice cloning: {voice} ({ref_path})")
        else:
            logger.warning(f"Voice '{voice}' not found, using default")
    
    try:
        if runtime == "cli" or not MODEL_READY:
            audio = generate_cli(text, prompt_audio, prompt_text)
        else:
            audio = generate_api(runtime, text, prompt_audio, prompt_text)
    except Exception as e:
        logger.error(f"Generation failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    
    elapsed = time.time() - start
    duration_s = 0
    
    # Convert to opus if requested
    if req.format == "opus":
        audio = convert_to_opus(audio)
        media_type = "audio/ogg; codecs=opus"
    else:
        media_type = "audio/wav"
    
    return Response(
        content=audio,
        media_type=media_type,
        headers={
            "X-Generation-Time": f"{elapsed:.2f}",
            "X-Audio-Duration": f"{duration_s:.2f}"
        }
    )


def generate_api(runtime, text: str, prompt_audio: str = None, prompt_text: str = None) -> bytes:
    """Generate using dots.tts Python API."""
    import torch
    import soundfile as sf
    import tempfile
    
    kwargs = {
        "text": text,
        "num_steps": 10,
        "language": "fr",
    }
    if prompt_audio:
        kwargs["prompt_audio_path"] = prompt_audio
        if prompt_text:
            kwargs["prompt_text"] = prompt_text
    
    with torch.no_grad():
        result = runtime.generate(**kwargs)
    
    # Convert to WAV bytes
    audio = result["audio"].float().cpu().squeeze().numpy()
    sample_rate = result["sample_rate"]
    
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        sf.write(tmp.name, audio, sample_rate)
        wav_bytes = Path(tmp.name).read_bytes()
        Path(tmp.name).unlink()
    
    return wav_bytes


def generate_cli(text: str, prompt_audio: str = None, prompt_text: str = None) -> bytes:
    """Generate using dots.tts CLI as fallback."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        out_path = tmp.name
    
    cmd = [
        "dots.tts",
        "--model-name-or-path", str(MODEL_DIR) if MODEL_READY else DEFAULT_MODEL,
        "--text", text,
        "--output", out_path,
        "--num-steps", "10",
        "--precision", "float16",
    ]
    
    if prompt_audio:
        cmd += ["--prompt-audio", prompt_audio]
        if prompt_text:
            cmd += ["--prompt-text", prompt_text]
    
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise RuntimeError(f"CLI failed: {result.stderr}")
    
    audio = Path(out_path).read_bytes()
    Path(out_path).unlink(missing_ok=True)
    return audio


def convert_to_opus(wav_bytes: bytes) -> bytes:
    """Convert WAV to Opus using ffmpeg."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp_in:
        tmp_in.write(wav_bytes)
        wav_path = tmp_in.name
    
    opus_path = wav_path.replace(".wav", ".opus")
    
    subprocess.run([
        "ffmpeg", "-y", "-i", wav_path,
        "-c:a", "libopus", "-b:a", "32k",
        "-application", "voip",
        opus_path
    ], capture_output=True, timeout=30)
    
    audio = Path(opus_path).read_bytes()
    Path(wav_path).unlink(missing_ok=True)
    Path(opus_path).unlink(missing_ok=True)
    return audio


if __name__ == "__main__":
    import uvicorn
    logger.info("Starting dots.tts server on port 8000")
    uvicorn.run(app, host="0.0.0.0", port=8000)
