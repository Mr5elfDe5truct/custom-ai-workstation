"""Voice server: speech-to-text with Whisper large-v3-turbo and expressive text-to-speech with VoxCPM2.

OpenAI-compatible, so Open WebUI and Prestige use it like any speech API:
  POST /v1/audio/transcriptions   multipart file (+ language)       -> {"text": ...}
  POST /v1/audio/speech           {"input", "voice", "response_format"} -> audio (wav, or mp3 with ffmpeg)
  GET  /v1/audio/voices           VoxCPM2 voices: the built-in designed voices plus any clips in data\\voices
  POST /v1/audio/voices           multipart name + file (+ transcript): add a voice to clone
  POST /v1/audio/unload           frees the GPU (both models); Prestige calls it before a chat reply

Both models load on first use and unload after a few idle minutes. Whisper runs on the GPU (~1 GB, 0.1-0.3 s a
sentence; ~25 s on the CPU) and falls back to the CPU base model when the GPU is full. VoxCPM2 needs ~6 GB of GPU
memory, so it only fits next to the small chat models; when a chat model is in the way it is unloaded first.

Run: envs\\voice\\Scripts\\python.exe tools\\voice_server.py   (port 8890; start-all.ps1 does this)
"""
import asyncio
import io
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path

import httpx
import numpy as np
import soundfile as sf
import torch
import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response

ROOT = Path(__file__).resolve().parent.parent
WHISPER_DIR = ROOT / "models" / "whisper"
VOXCPM_DIR = ROOT / "models" / "tts" / "VoxCPM2"
VOICES = ROOT / "data" / "voices"
WHISPER_MODEL = os.getenv("VOICE_WHISPER_MODEL", "large-v3-turbo")
WHISPER_IDLE = int(os.getenv("VOICE_WHISPER_IDLE", "300"))  # seconds before Whisper leaves the GPU
VOXCPM_IDLE = int(os.getenv("VOICE_TTS_IDLE", "180"))
VOXCPM_STEPS = int(os.getenv("VOICE_TTS_STEPS", "6"))  # 10 is VoxCPM's default; 6 is ~30% faster and sounds the same
VOXCPM_VRAM = 6.2e9  # what VoxCPM2 needs free on the GPU (5.7 GB peak plus headroom)

# Designed voices: VoxCPM2 makes a voice from a description. Each one is rendered once into data\voices and cloned
# from then on, so every sentence of a reply uses the same voice.
DESIGNED = {
    "aria": "A warm, clear young woman's voice, friendly and relaxed, natural American accent",
    "sterling": "A calm, deep male voice with a refined British accent, measured and confident",
    "nova": "A bright, energetic young woman's voice, upbeat and expressive",
    "atlas": "A rich, steady middle-aged male narrator, warm and authoritative",
    "ember": "A soft, husky female voice, intimate and slow-paced",
}
SAMPLE = "Hello there. It's good to hear from you, and I'm ready whenever you are. What should we make today?"

app = FastAPI(title="Workstation voice")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
gpu_lock = threading.Lock()  # one GPU job at a time
state = {"whisper": None, "whisper_device": None, "whisper_used": 0.0, "tts": None, "tts_used": 0.0}


def _free_vram() -> int:
    # nvidia-smi, not torch.cuda.mem_get_info(): on Windows the driver lets CUDA spill into system RAM, so torch can
    # report gigabytes free on a full card, and a model loaded there runs several times slower.
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.total,memory.used", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10).stdout.splitlines()[0]
        total, used = (int(x) for x in out.split(","))
        return (total - used) * 1024 * 1024
    except Exception:
        return torch.cuda.mem_get_info()[0] if torch.cuda.is_available() else 0


def _free_chat_models():
    # Same as the tool server does for renders: unload Ollama's and llama.cpp's models (they reload on the next reply).
    try:
        for m in httpx.get("http://127.0.0.1:11434/api/ps", timeout=5).json().get("models", []):
            httpx.post("http://127.0.0.1:11434/api/generate", json={"model": m["name"], "keep_alive": 0}, timeout=30)
    except httpx.HTTPError:
        pass
    try:
        for m in httpx.get("http://127.0.0.1:8081/models", timeout=5).json().get("data", []):
            if m.get("status", {}).get("value") in ("loaded", "loading"):
                httpx.post("http://127.0.0.1:8081/models/unload", json={"model": m["id"]}, timeout=30)
    except httpx.HTTPError:
        pass
    for _ in range(20):  # wait for the memory to come back
        if _free_vram() >= VOXCPM_VRAM:
            return
        time.sleep(0.5)


def _unload(which: str):
    if state[which] is not None:
        state[which] = None
        if which == "whisper":
            state["whisper_device"] = None
        import gc

        gc.collect()
        torch.cuda.empty_cache()


# ---------- speech to text ----------
def _whisper():
    from faster_whisper import WhisperModel

    if state["whisper"] is None:
        try:
            state["whisper"] = WhisperModel(WHISPER_MODEL, device="cuda", compute_type="int8_float16",
                                            download_root=str(WHISPER_DIR))
            state["whisper_device"] = "cuda"
        except Exception as e:  # GPU full or no CUDA: the small model on the CPU stays quick enough to talk to
            print(f"Whisper on the GPU failed ({e}); using the CPU base model", flush=True)
            state["whisper"] = WhisperModel("base", device="cpu", compute_type="int8", download_root=str(WHISPER_DIR))
            state["whisper_device"] = "cpu"
    state["whisper_used"] = time.time()
    return state["whisper"]


def _transcribe(path: str, language: str | None) -> str:
    with gpu_lock:
        model = _whisper()
        try:
            segs, _ = model.transcribe(path, language=language or None, beam_size=5, vad_filter=True)
            text = " ".join(s.text.strip() for s in segs)
        except RuntimeError as e:  # out of GPU memory mid-run: retry once on the CPU
            if state["whisper_device"] != "cuda":
                raise
            print(f"Whisper GPU run failed ({e}); retrying on the CPU", flush=True)
            _unload("whisper")
            from faster_whisper import WhisperModel

            state["whisper"] = WhisperModel("base", device="cpu", compute_type="int8", download_root=str(WHISPER_DIR))
            state["whisper_device"] = "cpu"
            segs, _ = state["whisper"].transcribe(path, language=language or None, beam_size=5, vad_filter=True)
            text = " ".join(s.text.strip() for s in segs)
        state["whisper_used"] = time.time()
        return text.strip()


@app.post("/v1/audio/transcriptions")
async def transcriptions(file: UploadFile = File(...), model: str = Form(""), language: str = Form(""),
                         response_format: str = Form("json")):
    suffix = Path(file.filename or "audio.webm").suffix or ".webm"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as f:
        f.write(await file.read())
    try:
        text = await asyncio.to_thread(_transcribe, f.name, language.strip().lower() or None)
    finally:
        os.unlink(f.name)
    if response_format == "text":
        return Response(text, media_type="text/plain")
    return {"text": text}


# ---------- text to speech ----------
def _voxcpm():
    if state["tts"] is None:
        if _free_vram() < VOXCPM_VRAM:
            _unload("whisper")  # it reloads in a few seconds when it's needed
        if _free_vram() < VOXCPM_VRAM:
            _free_chat_models()
        if _free_vram() < VOXCPM_VRAM:
            raise HTTPException(503, "VoxCPM2 needs about 6 GB of free GPU memory; something else is using the GPU")
        from voxcpm import VoxCPM

        state["tts"] = VoxCPM.from_pretrained(str(VOXCPM_DIR), load_denoiser=False)
    state["tts_used"] = time.time()
    return state["tts"]


def _voice_files(name: str):
    wav = VOICES / f"{name}.wav"
    txt = VOICES / f"{name}.txt"
    return wav, (txt.read_text(encoding="utf-8").strip() if txt.exists() else None)


def _voice_list():
    names = set(DESIGNED)
    if VOICES.exists():
        names |= {p.stem for p in VOICES.glob("*.wav")}
    return sorted(names, key=lambda n: (n not in DESIGNED, n))


def _speak(text: str, voice: str, steps: int) -> tuple[np.ndarray, int]:
    with gpu_lock:
        model = _voxcpm()
        sr = model.tts_model.sample_rate
        wav_path, transcript = _voice_files(voice)
        if not wav_path.exists() and voice in DESIGNED:
            # First use of a designed voice: render it from its description, then clone it from now on.
            VOICES.mkdir(parents=True, exist_ok=True)
            sample = model.generate(text=f"({DESIGNED[voice]}){SAMPLE}", cfg_value=2.0, inference_timesteps=10)
            sf.write(wav_path, sample, sr)
            wav_path.with_suffix(".txt").write_text(SAMPLE, encoding="utf-8")
            transcript = SAMPLE
        kw = {}
        if wav_path.exists():
            kw["reference_wav_path"] = str(wav_path)
            if transcript:  # "ultimate cloning": the clip plus what it says keeps the voice closest
                kw["prompt_wav_path"] = str(wav_path)
                kw["prompt_text"] = transcript
        # A voice that isn't a file is a description: "(a cheerful old man)" style prompts.
        style = "" if wav_path.exists() or not voice or voice == "default" else f"({voice})"
        audio = model.generate(text=style + text, cfg_value=2.0, inference_timesteps=steps, **kw)
        state["tts_used"] = time.time()
        return audio, sr


def _encode(audio: np.ndarray, sr: int, fmt: str) -> tuple[bytes, str]:
    buf = io.BytesIO()
    sf.write(buf, audio, sr, format="WAV", subtype="PCM_16")
    data = buf.getvalue()
    if fmt in ("mp3", "opus", "aac") and shutil.which("ffmpeg"):
        codec = {"mp3": ["-f", "mp3", "-b:a", "160k"], "opus": ["-f", "ogg", "-c:a", "libopus"], "aac": ["-f", "adts"]}
        out = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", "pipe:0", *codec[fmt], "pipe:1"],
                             input=data, capture_output=True)
        if out.returncode == 0:
            return out.stdout, {"mp3": "audio/mpeg", "opus": "audio/ogg", "aac": "audio/aac"}[fmt]
    return data, "audio/wav"


@app.post("/v1/audio/speech")
async def speech(body: dict):
    text = re.sub(r"\s+", " ", str(body.get("input", ""))).strip()
    if not text:
        raise HTTPException(400, "input is empty")
    voice = str(body.get("voice") or "aria").strip()
    steps = int(body.get("steps") or VOXCPM_STEPS)
    audio, sr = await asyncio.to_thread(_speak, text, voice, steps)
    # No "speed": VoxCPM2 takes pace from the text, or from a style note like "(slightly faster)".
    data, mime = _encode(audio, sr, body.get("response_format", "wav"))
    return Response(data, media_type=mime)


@app.get("/v1/audio/voices")
def voices():
    return {"voices": _voice_list(), "designed": DESIGNED}


@app.post("/v1/audio/voices")
async def add_voice(name: str = Form(...), file: UploadFile = File(...), transcript: str = Form("")):
    name = re.sub(r"[^a-z0-9_-]+", "-", name.strip().lower()).strip("-")
    if not name:
        raise HTTPException(400, "give the voice a name")
    VOICES.mkdir(parents=True, exist_ok=True)
    raw = await file.read()
    try:  # store as 16-bit WAV; ffmpeg handles webm/mp3/m4a recordings
        audio, sr = sf.read(io.BytesIO(raw))
    except Exception:
        if not shutil.which("ffmpeg"):
            raise HTTPException(400, "use a WAV or FLAC file (ffmpeg isn't installed for other formats)")
        out = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", "pipe:0", "-ac", "1", "-ar", "16000", "-f", "wav",
                              "pipe:1"], input=raw, capture_output=True)
        if out.returncode:
            raise HTTPException(400, "couldn't read that audio file")
        audio, sr = sf.read(io.BytesIO(out.stdout))
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    audio = audio[: sr * 30]  # a 5-30 s clip is plenty
    sf.write(VOICES / f"{name}.wav", audio, sr, subtype="PCM_16")
    txt = VOICES / f"{name}.txt"
    if transcript.strip():
        txt.write_text(transcript.strip(), encoding="utf-8")
    elif txt.exists():
        txt.unlink()
    return {"voice": name, "seconds": round(len(audio) / sr, 1)}


@app.post("/v1/audio/unload")
def unload(body: dict | None = None):
    which = (body or {}).get("model", "all")
    with gpu_lock:
        if which in ("all", "tts", "voxcpm2"):
            _unload("tts")
        if which in ("all", "stt", "whisper"):
            _unload("whisper")
    return {"ok": True}


@app.get("/health")
def health():
    return {"status": "ok", "whisper": state["whisper_device"], "voxcpm2": state["tts"] is not None,
            "free_vram_gb": round(_free_vram() / 1e9, 1)}


@app.get("/v1/models")
def models():
    return {"data": [{"id": "whisper-large-v3-turbo", "object": "model"}, {"id": "voxcpm2", "object": "model"}]}


def _janitor():
    while True:
        time.sleep(15)
        now = time.time()
        for which, idle in (("tts", VOXCPM_IDLE), ("whisper", WHISPER_IDLE)):
            if state[which] is not None and now - state[f"{which}_used"] > idle and gpu_lock.acquire(blocking=False):
                try:
                    _unload(which)
                    print(f"unloaded {which} after {idle} s idle", flush=True)
                finally:
                    gpu_lock.release()


if __name__ == "__main__":
    threading.Thread(target=_janitor, daemon=True).start()
    uvicorn.run(app, host="127.0.0.1", port=int(os.getenv("VOICE_PORT", "8890")), log_level="warning")
