from __future__ import annotations

import base64
import logging
import threading
from dataclasses import dataclass
from datetime import datetime
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
    tools_used: list[str]


class ClaudeVision:
    def __init__(
        self,
        api_key: str,
        model: str,
        max_tokens: int,
        system_prompt: str,
        enable_web_search: bool = True,
        enable_local_tools: bool = True,
    ) -> None:
        self._client = anthropic.Anthropic(api_key=api_key)
        self._model = model
        self._max_tokens = max_tokens
        self._system_prompt = system_prompt
        self._enable_web_search = enable_web_search
        self._enable_local_tools = enable_local_tools
        # Per-session scratch notes for the save_note / recall_notes tools.
        self._notes: dict[str, list[str]] = {}
        self._notes_lock = threading.Lock()

    # MARK: – Tools

    def _tools(self) -> list[dict[str, Any]]:
        tools: list[dict[str, Any]] = []
        if self._enable_web_search:
            # Anthropic-hosted server tool — the API runs the search itself.
            tools.append({"type": "web_search_20250305", "name": "web_search", "max_uses": 3})
        if self._enable_local_tools:
            tools += [
                {
                    "name": "get_datetime",
                    "description": "Get the current local date and time.",
                    "input_schema": {"type": "object", "properties": {}, "required": []},
                },
                {
                    "name": "save_note",
                    "description": "Save a short note so it can be recalled later in this session.",
                    "input_schema": {
                        "type": "object",
                        "properties": {"text": {"type": "string", "description": "The note to remember."}},
                        "required": ["text"],
                    },
                },
                {
                    "name": "recall_notes",
                    "description": "List the notes saved earlier in this session.",
                    "input_schema": {"type": "object", "properties": {}, "required": []},
                },
            ]
        return tools

    def _run_local_tool(self, name: str, tool_input: dict[str, Any] | None, session_id: str | None) -> str:
        key = session_id or "_default"
        tool_input = tool_input or {}
        if name == "get_datetime":
            return datetime.now().astimezone().strftime("%A, %B %d %Y, %-I:%M %p %Z")
        if name == "save_note":
            text = str(tool_input.get("text", "")).strip()
            if not text:
                return "No note text provided."
            with self._notes_lock:
                self._notes.setdefault(key, []).append(text)
            return f"Saved note: {text}"
        if name == "recall_notes":
            with self._notes_lock:
                notes = list(self._notes.get(key, []))
            if not notes:
                return "No notes saved yet."
            return "\n".join(f"- {n}" for n in notes)
        return f"Unknown tool: {name}"

    # MARK: – Message helpers

    @staticmethod
    def _image_block(data: bytes, media_type: str = "image/jpeg") -> dict[str, Any]:
        return {
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": media_type,
                "data": base64.standard_b64encode(data).decode("ascii"),
            },
        }

    @staticmethod
    def _extract_text(msg: Any) -> str:
        parts = [b.text for b in msg.content if getattr(b, "type", None) == "text"]
        return "".join(parts).strip()

    # MARK: – Ask

    def ask(
        self,
        *,
        user_text: str,
        image_bytes: bytes,
        image_media_type: str = "image/jpeg",
        history: list[Turn] | None = None,
        context_images: list[bytes] | None = None,
        session_id: str | None = None,
        model: str | None = None,
    ) -> ClaudeReply:
        history = history or []
        context_images = context_images or []
        selected_model = (model or "").strip() or self._model

        messages: list[dict[str, Any]] = []
        for turn in history:
            messages.append({"role": "user", "content": turn.user_text})
            messages.append({"role": "assistant", "content": turn.assistant_text})

        content: list[dict[str, Any]] = []
        if context_images:
            content.append({"type": "text", "text": "Recent frames from my view (oldest to newest):"})
            for frame in context_images:
                content.append(self._image_block(frame))
            content.append({"type": "text", "text": "Current view:"})
        content.append(self._image_block(image_bytes, image_media_type))
        content.append({"type": "text", "text": user_text or "What am I looking at?"})
        messages.append({"role": "user", "content": content})

        tools = self._tools()
        total_in = total_out = 0
        tools_used: list[str] = []
        msg: Any = None

        logger.info(
            "Claude call: model=%s history=%d context_frames=%d tools=%d user_text=%r",
            selected_model,
            len(history),
            len(context_images),
            len(tools),
            user_text[:80],
        )

        # Agentic loop: keep going while the model requests client-side tools.
        # (web_search is a server tool the API resolves itself, so it won't pause here.)
        for _ in range(6):
            kwargs: dict[str, Any] = {
                "model": selected_model,
                "max_tokens": self._max_tokens,
                "system": self._system_prompt,
                "messages": messages,
            }
            if tools:
                kwargs["tools"] = tools
            msg = self._client.messages.create(**kwargs)
            total_in += msg.usage.input_tokens
            total_out += msg.usage.output_tokens

            if msg.stop_reason != "tool_use":
                break

            messages.append({"role": "assistant", "content": msg.content})
            tool_results: list[dict[str, Any]] = []
            for block in msg.content:
                if getattr(block, "type", None) == "tool_use":
                    tools_used.append(block.name)
                    output = self._run_local_tool(block.name, dict(block.input or {}), session_id)
                    tool_results.append(
                        {"type": "tool_result", "tool_use_id": block.id, "content": output}
                    )
            if not tool_results:
                break
            messages.append({"role": "user", "content": tool_results})

        # Note server-tool usage (web_search) for logging/headers.
        if msg is not None:
            for block in msg.content:
                if getattr(block, "type", None) == "server_tool_use":
                    tools_used.append(getattr(block, "name", "server_tool"))

        return ClaudeReply(
            text=self._extract_text(msg) if msg is not None else "",
            input_tokens=total_in,
            output_tokens=total_out,
            tools_used=tools_used,
        )
