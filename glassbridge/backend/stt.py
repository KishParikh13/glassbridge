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


def make_transcriber(settings: Settings) -> Transcriber:
    """Pick a transcriber from config.

    The fallback is at selection time, not per request: if Groq is chosen we do not load
    Whisper at all, because keeping a 1.5 GB model warm as insurance against an API that
    is usually up costs more than it saves. A Groq outage surfaces as a failed ask with a
    clear message rather than a silent slow path.
    """
    provider = (settings.stt_provider or "auto").strip().lower()

    if provider == "auto":
        provider = "groq" if settings.groq_api_key else "whisper"

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
        raise RuntimeError(f"Unknown STT_PROVIDER {provider!r}. Use 'auto', 'groq', or 'whisper'.")

    return WhisperTranscriber(
        model_name=settings.whisper_model,
        device=settings.whisper_device,
        compute_type=settings.whisper_compute_type,
    )
