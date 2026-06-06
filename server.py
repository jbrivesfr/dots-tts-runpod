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
DEFAULT_MODEL = "rednote-hilab/dots-tts-meanflow-distilled"

# Check if model was pre-downloaded
MODEL_READY = (MODEL_DIR / "pytorch_model.bin").exists() or \
              (MODEL_DIR / "model.safetensors").exists() or \
              len(list(MODEL_DIR.glob("*.safetensors"))) > 0

if not MODEL_READY:
    logger.warning("Model not pre-downloaded — will download on first request (this is slow)")

# Model cache
_model = None
_model_path = None

def get_model():
    """Lazy-load the dots.tts model."""
    global _model, _model_path
    
    if _model is not None:
        return _model
    
    logger.info("Loading dots.tts model...")
    start = time.time()
    
    try:
        from dots_tts import DotsTTS
        _model = DotsTTS.from_pretrained(
            str(MODEL_DIR) if MODEL_READY else DEFAULT_MODEL,
            device="cuda",
            torch_dtype="float16"
        )
    except ImportError:
        # Fallback: use CLI via subprocess
        logger.warning("dots.tts Python API unavailable — falling back to CLI")
        _model = "cli"
    except Exception as e:
        logger.error(f"Failed to load model: {e}")
        raise HTTPException(status_code=500, detail=f"Model load failed: {e}")
    
    elapsed = time.time() - start
    logger.info(f"Model loaded in {elapsed:.1f}s")
    return _model


class GenerateRequest(BaseModel):
    text: str
    voice: Optional[str] = "default"  # "jb", "default", or null for random
    speed: Optional[float] = 1.0
    format: Optional[str] = "wav"  # wav or opus


@app.get("/health")
def health():
    return {"status": "ok", "model_ready": MODEL_READY}


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
    
    model = get_model()
    
    # Prepare reference audio for voice cloning
    ref_audio = None
    ref_text = None
    
    if voice != "default":
        ref_path = VOICES_DIR / f"{voice}.wav"
        ref_txt_path = VOICES_DIR / f"{voice}.txt"
        if ref_path.exists():
            ref_audio = ref_path
            if ref_txt_path.exists():
                ref_text = ref_txt_path.read_text().strip()
            logger.info(f"Voice cloning: {voice} ({ref_path})")
        else:
            logger.warning(f"Voice '{voice}' not found, using default")
    
    try:
        if model == "cli" or not MODEL_READY:
            # Use CLI fallback
            audio = generate_cli(text, ref_audio, ref_text)
        else:
            # Use Python API
            audio = generate_api(model, text, ref_audio, ref_text)
    except Exception as e:
        logger.error(f"Generation failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    
    elapsed = time.time() - start
    duration = len(audio) / 48000  # 48 kHz
    rtf = elapsed / duration if duration > 0 else 0
    logger.info(f"Generated {len(audio)} samples ({duration:.1f}s) in {elapsed:.1f}s (RTF: {rtf:.1f}x)")
    
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
            "X-Audio-Duration": f"{duration:.2f}",
            "X-RTF": f"{rtf:.1f}"
        }
    )


def generate_api(model, text: str, ref_audio, ref_text) -> bytes:
    """Generate using dots.tts Python API."""
    import torch
    
    kwargs = {"text": text}
    if ref_audio:
        kwargs["prompt_audio"] = str(ref_audio)
        if ref_text:
            kwargs["prompt_text"] = ref_text
    
    with torch.no_grad():
        output = model.generate(**kwargs)
    
    # Convert to WAV bytes
    import torchaudio
    buffer = io.BytesIO()
    torchaudio.save(buffer, output.cpu(), 48000, format="wav")
    return buffer.getvalue()


def generate_cli(text: str, ref_audio, ref_text) -> bytes:
    """Generate using dots.tts CLI as fallback."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        out_path = tmp.name
    
    cmd = [
        "dots.tts",
        "--model-name-or-path", str(MODEL_DIR) if MODEL_READY else DEFAULT_MODEL,
        "--text", text,
        "--output", out_path,
        "--num-steps", "10",
    ]
    
    if ref_audio:
        cmd += ["--prompt-audio", str(ref_audio)]
        if ref_text:
            cmd += ["--prompt-text", ref_text]
    
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
