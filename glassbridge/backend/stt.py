from __future__ import annotations

import logging
import os
import tempfile
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from faster_whisper import WhisperModel

logger = logging.getLogger(__name__)


@dataclass
class TranscriptionResult:
    text: str
    language: str
    duration_s: float


class WhisperTranscriber:
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
