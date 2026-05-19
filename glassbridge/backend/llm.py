from __future__ import annotations

import base64
import logging
from dataclasses import dataclass, field
from typing import Any

import anthropic

logger = logging.getLogger(__name__)


@dataclass
class Turn:
    user_text: str
    assistant_text: str


@dataclass
class ClaudeReply:
    text: str
    input_tokens: int
    output_tokens: int


class ClaudeVision:
    def __init__(
        self,
        api_key: str,
        model: str,
        max_tokens: int,
        system_prompt: str,
    ) -> None:
        self._client = anthropic.Anthropic(api_key=api_key)
        self._model = model
        self._max_tokens = max_tokens
        self._system_prompt = system_prompt

    def ask(
        self,
        *,
        user_text: str,
        image_bytes: bytes,
        image_media_type: str = "image/jpeg",
        history: list[Turn] | None = None,
    ) -> ClaudeReply:
        history = history or []
        b64 = base64.standard_b64encode(image_bytes).decode("ascii")

        messages: list[dict[str, Any]] = []
        for turn in history:
            messages.append({"role": "user", "content": turn.user_text})
            messages.append({"role": "assistant", "content": turn.assistant_text})

        messages.append(
            {
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": image_media_type,
                            "data": b64,
                        },
                    },
                    {"type": "text", "text": user_text or "What am I looking at?"},
                ],
            }
        )

        logger.info(
            "Claude call: model=%s history_turns=%d user_text=%r",
            self._model,
            len(history),
            user_text[:80],
        )

        msg = self._client.messages.create(
            model=self._model,
            max_tokens=self._max_tokens,
            system=self._system_prompt,
            messages=messages,
        )

        text_parts: list[str] = []
        for block in msg.content:
            if getattr(block, "type", None) == "text":
                text_parts.append(block.text)
        reply_text = "".join(text_parts).strip()

        return ClaudeReply(
            text=reply_text,
            input_tokens=msg.usage.input_tokens,
            output_tokens=msg.usage.output_tokens,
        )
