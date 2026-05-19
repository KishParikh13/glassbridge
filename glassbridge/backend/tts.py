from __future__ import annotations

import logging
from collections.abc import Iterator

import httpx

logger = logging.getLogger(__name__)


class ElevenLabsStreamingTTS:
    def __init__(
        self,
        api_key: str,
        voice_id: str,
        model_id: str,
        output_format: str,
    ) -> None:
        self._api_key = api_key
        self._voice_id = voice_id
        self._model_id = model_id
        self._output_format = output_format
        self._endpoint = (
            f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream"
        )
        # Long-lived client. Glasses pipeline is bursty, not concurrent — cheap to keep.
        self._client = httpx.Client(timeout=httpx.Timeout(60.0, connect=10.0))

    def synthesize(self, text: str) -> Iterator[bytes]:
        if not text.strip():
            text = "I didn't catch that."

        params = {
            "output_format": self._output_format,
            "optimize_streaming_latency": "3",
        }
        headers = {
            "xi-api-key": self._api_key,
            "Content-Type": "application/json",
            "Accept": "audio/mpeg",
        }
        body = {
            "text": text,
            "model_id": self._model_id,
            "voice_settings": {
                "stability": 0.4,
                "similarity_boost": 0.7,
                "use_speaker_boost": True,
                "speed": 1.0,
            },
        }

        logger.info(
            "ElevenLabs synth: voice=%s model=%s format=%s len=%d",
            self._voice_id,
            self._model_id,
            self._output_format,
            len(text),
        )

        with self._client.stream(
            "POST",
            self._endpoint,
            params=params,
            headers=headers,
            json=body,
        ) as response:
            if response.status_code >= 400:
                detail = response.read().decode("utf-8", errors="replace")
                raise RuntimeError(
                    f"ElevenLabs returned {response.status_code}: {detail[:300]}"
                )
            for chunk in response.iter_bytes(chunk_size=4096):
                if chunk:
                    yield chunk
