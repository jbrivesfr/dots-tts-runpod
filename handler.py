#!/usr/bin/env python3
"""
dots.tts RunPod Serverless Worker
Compatible with RunPod Serverless v2 worker protocol.

Environment:
  MODEL_DIR=/app/model   (pre-downloaded model path)
  VOICES_DIR=/app/voices (voice reference samples)
"""

import os
import io
import json
import time
import base64
import tempfile
import subprocess
import logging
from pathlib import Path
from typing import Dict, Any

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("dots-tts-worker")

# ── Config ──────────────────────────────────────────
MODEL_DIR = Path(os.environ.get("MODEL_DIR", "/app/model"))
VOICES_DIR = Path(os.environ.get("VOICES_DIR", "/app/voices"))

# Check model status
MODEL_READY = len(list(MODEL_DIR.glob("*.safetensors"))) > 0 or \
              (MODEL_DIR / "model.safetensors").exists()

# Model cache (persists across warm requests)
_model = None
_model_info = None

def load_model():
    """Lazy-load dots.tts runtime. Cached between requests."""
    global _model, _model_info
    
    if _model is not None:
        return _model
    
    logger.info("Loading dots.tts 2B model...")
    start = time.time()
    
    try:
        from dots_tts.runtime import DotsTtsRuntime
        _model = DotsTtsRuntime.from_pretrained(
            str(MODEL_DIR),
            precision="float16",
        )
    except Exception as e:
        # Fallback: try downloading from HF
        logger.warning(f"Local model load failed ({e}), downloading from HuggingFace...")
        from dots_tts.runtime import DotsTtsRuntime
        _model = DotsTtsRuntime.from_pretrained(
            "rednote-hilab/dots.tts-soar",
            precision="float16",
        )
    
    elapsed = time.time() - start
    _model_info = {"load_time_s": round(elapsed, 1)}
    logger.info(f"Model loaded in {elapsed:.1f}s")
    return _model


def generate_audio(text: str, voice: str = "default", steps: int = 10) -> bytes:
    """Generate speech audio using dots.tts."""
    import torch
    import soundfile as sf
    import tempfile
    
    runtime = load_model()
    
    # Prepare reference audio for voice cloning
    prompt_audio = None
    prompt_text = None
    
    if voice != "default":
        ref_path = VOICES_DIR / f"{voice}.wav"
        ref_txt = VOICES_DIR / f"{voice}.txt"
        if ref_path.exists():
            prompt_audio = str(ref_path)
            if ref_txt.exists():
                prompt_text = ref_txt.read_text().strip()
            logger.info(f"Voice cloning: {voice}")
        else:
            logger.warning(f"Voice '{voice}' not found — using default")
    
    # Generate
    gen_kwargs = {
        "text": text,
        "num_steps": steps,
        "language": "fr",
    }
    if prompt_audio:
        gen_kwargs["prompt_audio_path"] = prompt_audio
        if prompt_text:
            gen_kwargs["prompt_text"] = prompt_text
    
    with torch.no_grad():
        result = runtime.generate(**gen_kwargs)
    
    # Convert to WAV bytes
    audio = result["audio"].float().cpu().squeeze().numpy()
    sample_rate = result["sample_rate"]
    
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        sf.write(tmp.name, audio, sample_rate)
        wav_bytes = Path(tmp.name).read_bytes()
        Path(tmp.name).unlink()
    
    return wav_bytes


def convert_to_opus(wav_bytes: bytes) -> bytes:
    """Convert WAV to Opus for smaller WhatsApp delivery."""
    import tempfile
    wav_path = None
    opus_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            f.write(wav_bytes)
            wav_path = f.name
        
        opus_path = wav_path.replace(".wav", ".opus")
        subprocess.run([
            "ffmpeg", "-y", "-i", wav_path,
            "-c:a", "libopus", "-b:a", "32k",
            "-application", "voip",
            "-loglevel", "error",
            opus_path
        ], check=True, timeout=30)
        
        return Path(opus_path).read_bytes()
    finally:
        if wav_path: Path(wav_path).unlink(missing_ok=True)
        if opus_path: Path(opus_path).unlink(missing_ok=True)


def handler(job: Dict[str, Any]) -> Dict[str, Any]:
    """
    RunPod Serverless handler.
    
    Input:  {"input": {"text": "...", "voice": "jb", "format": "opus"}}
    Output: {"output": {"audio_base64": "...", "format": "opus", "duration_s": 3.2}}
    """
    job_input = job.get("input", {})
    text = job_input.get("text", "").strip()
    voice = job_input.get("voice", "default")
    fmt = job_input.get("format", "opus")
    steps = job_input.get("steps", 10)
    
    if not text:
        return {"error": "text is required"}
    
    logger.info(f"Generating: voice={voice}, text_len={len(text)}, format={fmt}")
    start = time.time()
    
    # Generate WAV
    wav_bytes = generate_audio(text, voice, steps)
    gen_time = time.time() - start
    
    # Convert if needed
    if fmt == "opus":
        audio_bytes = convert_to_opus(wav_bytes)
    else:
        audio_bytes = wav_bytes
    
    total_time = time.time() - start
    duration_s = len(wav_bytes) / (48000 * 2)  # rough: 16-bit stereo would be *4, mono *2
    
    # More accurate duration from WAV header
    import struct
    wav_header = wav_bytes[:44]
    if len(wav_header) >= 44:
        # Channels at offset 22 (2 bytes), Sample rate at 24, Bits at 34
        channels = struct.unpack_from('<H', wav_header, 22)[0]
        bits = struct.unpack_from('<H', wav_header, 34)[0]
        data_size = struct.unpack_from('<I', wav_header, 40)[0]
        duration_s = data_size / (48000 * channels * bits / 8)
    
    result = {
        "output": {
            "audio_base64": base64.b64encode(audio_bytes).decode("utf-8"),
            "format": fmt,
            "duration_s": round(duration_s, 2),
            "gen_time_s": round(gen_time, 2),
            "total_time_s": round(total_time, 2),
            "size_bytes": len(audio_bytes),
            "voice": voice,
            "rtf": round(gen_time / duration_s, 2) if duration_s > 0 else 0,
        }
    }
    
    logger.info(f"Done: {duration_s:.1f}s audio in {total_time:.1f}s (RTF: {result['output']['rtf']:.1f}x)")
    return result


# ── RunPod Serverless Entrypoint ────────────────────
if __name__ == "__main__":
    import runpod
    logger.info("Starting dots.tts RunPod Serverless worker")
    logger.info(f"Model dir: {MODEL_DIR} (ready: {MODEL_READY})")
    logger.info(f"Voices dir: {VOICES_DIR}")
    
    runpod.serverless.start({
        "handler": handler
    })
