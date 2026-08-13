from __future__ import annotations

import logging
import os
import tempfile
from dataclasses import dataclass
from typing import TYPE_CHECKING, Protocol

import httpx

if TYPE_CHECKING:
    from faster_whisper import WhisperModel

    from .config import Settings

logger = logging.getLogger(__name__)


@dataclass
class TranscriptionResult:
    text: str
    language: str
    duration_s: float


class Transcriber(Protocol):
    """What the rest of the app needs from speech-to-text.

    Kept deliberately small: one blocking call that takes bytes and returns text.
    `main.py` runs it in a thread either way, so a local model and a hosted API look the
    same from the outside.
    """

    def warmup(self) -> None: ...

    def transcribe(self, audio_bytes: bytes, filename_hint: str = "audio.wav") -> TranscriptionResult: ...


class WhisperTranscriber:
    """faster-whisper running locally on CPU.

    Accurate and free, but it dominates the latency budget: 5 to 8 seconds for a 5 second
    utterance, against roughly 3 for Claude and under 1 for TTS. It also pulls a ~1.5 GB
    model on first run, which is its own kind of failure when the download stalls.
    """

    def __init__(self, model_name: str, device: str, compute_type: str) -> None:
        self._model_name = model_name
        self._device = device
        self._compute_type = compute_type
        self._model: WhisperModel | None = None

    def warmup(self) -> None:
        from faster_whisper import WhisperModel

        logger.info(
            "Loading Whisper model=%s device=%s compute=%s",
            self._model_name,
            self._device,
            self._compute_type,
        )
        self._model = WhisperModel(
            self._model_name,
            device=self._device,
            compute_type=self._compute_type,
        )
        logger.info("Whisper model ready.")

    def transcribe(self, audio_bytes: bytes, filename_hint: str = "audio.wav") -> TranscriptionResult:
        if self._model is None:
            raise RuntimeError("Whisper model not loaded. Call warmup() first.")

        suffix = os.path.splitext(filename_hint)[1] or ".wav"
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
            tmp.write(audio_bytes)
            tmp_path = tmp.name

        try:
            segments_iter, info = self._model.transcribe(
                tmp_path,
                vad_filter=True,
                beam_size=1,
                condition_on_previous_text=False,
            )
            text = "".join(seg.text for seg in segments_iter).strip()
            return TranscriptionResult(
                text=text,
                language=info.language,
                duration_s=info.duration,
            )
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


class MlxTranscriber:
    """Whisper on Apple Silicon's GPU via MLX.

    `faster-whisper` uses CTranslate2, which has no Metal backend, so on an M-series Mac
    it is CPU-only and slow: 12 seconds for a 3 second clip on an M-series laptop. MLX
    runs the same size of model on the GPU. Measured on the M4 mini: 1.55 seconds for the
    same audio, using full `large-v3-turbo` rather than the distilled approximation, so it
    is both faster and more accurate.

    Audio never leaves the machine, which is the reason to prefer this over a hosted API.
    """

    def __init__(self, model: str) -> None:
        self._model = model

    def _load_wav(self, audio_bytes: bytes) -> tuple[object, int]:
        """16kHz mono PCM straight to float32.

        `mlx_whisper` shells out to ffmpeg to decode, which would be a system dependency
        for no reason: the app records exactly this format already (MicRecorder writes
        16k mono 16-bit), so the stdlib can do it.
        """
        import io
        import wave

        import numpy as np

        with wave.open(io.BytesIO(audio_bytes), "rb") as w:
            if w.getsampwidth() != 2:
                raise RuntimeError(f"expected 16-bit PCM, got {w.getsampwidth() * 8}-bit")
            frames = w.readframes(w.getnframes())
            rate, channels = w.getframerate(), w.getnchannels()

        audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
        if channels > 1:
            audio = audio.reshape(-1, channels).mean(axis=1)
        return audio, rate

    def warmup(self) -> None:
        import numpy as np
        import mlx_whisper

        logger.info("Loading MLX Whisper model=%s (Apple GPU)", self._model)
        # The first transcription pays a one-off ~4s to pull weights onto the GPU. Do it
        # at boot so the first real question doesn't.
        silence = np.zeros(16_000, dtype=np.float32)
        mlx_whisper.transcribe(silence, path_or_hf_repo=self._model)
        logger.info("MLX Whisper ready.")

    def transcribe(self, audio_bytes: bytes, filename_hint: str = "audio.wav") -> TranscriptionResult:
        import mlx_whisper

        audio, rate = self._load_wav(audio_bytes)
        result = mlx_whisper.transcribe(audio, path_or_hf_repo=self._model)
        return TranscriptionResult(
            text=(result.get("text") or "").strip(),
            language=result.get("language") or "unknown",
            duration_s=len(audio) / rate,
        )


class GroqTranscriber:
    """Whisper large v3 turbo on Groq, over plain HTTP.

    Same trick `tts.py` uses for ElevenLabs: this is one multipart POST, so an SDK would
    be a dependency for no gain. Typically returns in well under a second for a short
    clip, which is the difference between a demo people watch and one they don't.

    Nothing is downloaded and there is no warmup, so the backend is serving the moment it
    boots instead of after a 1.5 GB model load.
    """

    ENDPOINT = "https://api.groq.com/openai/v1/audio/transcriptions"

    def __init__(self, api_key: str, model: str, timeout_s: float = 30.0) -> None:
        self._api_key = api_key
        self._model = model
        self._timeout = timeout_s

    def warmup(self) -> None:
        logger.info("STT: Groq %s (hosted, no local model)", self._model)

    def transcribe(self, audio_bytes: bytes, filename_hint: str = "audio.wav") -> TranscriptionResult:
        files = {
            "file": (filename_hint or "audio.wav", audio_bytes, "audio/wav"),
        }
        data = {
            "model": self._model,
            # verbose_json also gives language and duration, which the result type wants
            # and which are genuinely useful when debugging a bad transcript.
            "response_format": "verbose_json",
            # The glasses mic is HFP, so the audio is narrowband and noisy. Temperature 0
            # keeps it from inventing words to fill gaps.
            "temperature": "0",
        }
        headers = {"Authorization": f"Bearer {self._api_key}"}

        try:
            with httpx.Client(timeout=self._timeout) as client:
                response = client.post(self.ENDPOINT, files=files, data=data, headers=headers)
        except httpx.HTTPError as exc:
            raise RuntimeError(f"Groq transcription request failed: {exc}") from exc

        if response.status_code != 200:
            detail = response.text[:300]
            raise RuntimeError(f"Groq transcription failed ({response.status_code}): {detail}")

        payload = response.json()
        return TranscriptionResult(
            text=(payload.get("text") or "").strip(),
            language=payload.get("language") or "unknown",
            duration_s=float(payload.get("duration") or 0.0),
        )


def _mlx_available() -> bool:
    """Apple Silicon only, and an optional dependency, so never assume it is there."""
    import importlib.util

    return importlib.util.find_spec("mlx_whisper") is not None


def make_transcriber(settings: Settings) -> Transcriber:
    """Pick a transcriber from config.

    The fallback is at selection time, not per request: if Groq is chosen we do not load
    Whisper at all, because keeping a 1.5 GB model warm as insurance against an API that
    is usually up costs more than it saves. A Groq outage surfaces as a failed ask with a
    clear message rather than a silent slow path.
    """
    provider = (settings.stt_provider or "auto").strip().lower()

    if provider == "auto":
        # Prefer the GPU on this machine over a hosted API over the CPU. MLX keeps audio
        # local and still beats a round trip; Whisper on CPU is the last resort because it
        # is 8x slower than either.
        if _mlx_available():
            provider = "mlx"
        elif settings.groq_api_key:
            provider = "groq"
        else:
            provider = "whisper"

    if provider == "mlx":
        if not _mlx_available():
            raise RuntimeError(
                "STT_PROVIDER=mlx but mlx-whisper is not installed. "
                "pip install mlx-whisper (Apple Silicon only), or set STT_PROVIDER=whisper."
            )
        return MlxTranscriber(model=settings.mlx_stt_model)

    if provider == "groq":
        if not settings.groq_api_key:
            raise RuntimeError(
                "STT_PROVIDER=groq but GROQ_API_KEY is missing. Put it in .env, "
                "or set STT_PROVIDER=whisper to run locally."
            )
        return GroqTranscriber(
            api_key=settings.groq_api_key,
            model=settings.groq_stt_model,
        )

    if provider != "whisper":
        raise RuntimeError(
            f"Unknown STT_PROVIDER {provider!r}. Use 'auto', 'mlx', 'groq', or 'whisper'."
        )

    return WhisperTranscriber(
        model_name=settings.whisper_model,
        device=settings.whisper_device,
        compute_type=settings.whisper_compute_type,
    )
