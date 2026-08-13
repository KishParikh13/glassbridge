from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

import httpx

from .base import AgentError, AgentReply, AgentSpec

logger = logging.getLogger(__name__)


class GatewayAgent:
    """An agent that lives behind an HTTP endpoint and streams NDJSON back.

    Written against the KishOS gateway, but nothing here knows that. Anything that accepts
    a JSON POST and answers with newline-delimited JSON events works, and the field names
    are configurable for the ones that do it differently. That is the whole point: someone
    cloning this repo should be able to point it at their own assistant by editing
    `agents.json`, not by writing Python.

    The agent owns its own memory. We hand it a stable thread id and it decides what that
    means — KishOS serialises per thread and keeps the transcript itself, so Glassbridge
    deliberately does not send history for these.
    """

    def __init__(
        self,
        spec: AgentSpec,
        url: str,
        *,
        token: str | None = None,
        token_file: str | None = None,
        timeout_s: float = 90.0,
        health_url: str | None = None,
        thread_prefix: str = "glassbridge",
        text_field: str = "text",
        thread_field: str = "threadId",
        reply_field: str = "text",
        context: str | None = None,
        context_field: str = "context",
        extra_body: dict[str, Any] | None = None,
    ) -> None:
        self.spec = spec
        self._url = url
        self._token = token
        self._token_file = Path(token_file).expanduser() if token_file else None
        self._timeout = timeout_s
        self._health_url = health_url
        self._thread_prefix = thread_prefix
        self._text_field = text_field
        self._thread_field = thread_field
        self._reply_field = reply_field
        self._context = context
        self._context_field = context_field
        self._extra_body = extra_body or {}
        self._cached_token: str | None = None

    # MARK: - Auth

    def _auth_token(self) -> str | None:
        if self._token:
            return self._token
        if self._cached_token:
            return self._cached_token
        if not self._token_file:
            return None
        try:
            token = self._token_file.read_text().strip()
        except OSError as exc:
            raise AgentError(
                f"{self.spec.label} is configured but its token file "
                f"({self._token_file}) could not be read: {exc}"
            ) from exc
        if not token:
            raise AgentError(f"{self.spec.label}'s token file ({self._token_file}) is empty.")
        self._cached_token = token
        return token

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        token = self._auth_token()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        return headers

    # MARK: - Agent

    def health(self) -> bool:
        if not self._health_url:
            return True
        try:
            with httpx.Client(timeout=5.0) as client:
                response = client.get(self._health_url, headers=self._headers())
            return response.status_code == 200
        except Exception:
            return False

    def respond(
        self,
        *,
        text: str,
        images: list[bytes],
        session_id: str,
        model: str | None = None,
    ) -> AgentReply:
        if images:
            # No image transport in the generic contract. Say so out loud rather than
            # dropping it silently, so "look" against a text-only agent is explainable.
            logger.info("%s does not accept images; %d dropped", self.spec.id, len(images))

        payload: dict[str, Any] = dict(self._extra_body)
        payload[self._thread_field] = f"{self._thread_prefix}-{session_id}"
        payload[self._text_field] = text
        # An agent built for a screen writes for a screen: the first live KishOS turn came
        # back as 45 seconds of speech with markdown in it. This tells it where the answer
        # is going. Sent per-turn rather than stored, so it shapes the reply without
        # polluting the agent's own transcript.
        if self._context:
            payload[self._context_field] = self._context

        collected: list[str] = []
        done: dict[str, Any] | None = None

        try:
            with httpx.Client(timeout=self._timeout) as client:
                with client.stream("POST", self._url, json=payload, headers=self._headers()) as response:
                    if response.status_code != 200:
                        response.read()
                        raise AgentError(
                            f"{self.spec.label} returned {response.status_code}: {response.text[:200]}"
                        )
                    for line in response.iter_lines():
                        if not line.strip():
                            continue
                        try:
                            event = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        kind = event.get("type")
                        if kind == "text":
                            collected.append(str(event.get(self._reply_field) or ""))
                        elif kind == "error":
                            raise AgentError(str(event.get("error") or f"{self.spec.label} reported an error."))
                        elif kind == "done":
                            done = event
        except AgentError:
            raise
        except httpx.HTTPError as exc:
            raise AgentError(f"{self.spec.label} is unreachable: {exc}") from exc

        # `done` carries the whole reply; the streamed text events are the same content in
        # pieces. Prefer the former, fall back to the latter so a shape change degrades
        # into a worse answer rather than into silence.
        reply = ""
        if done and isinstance(done.get(self._reply_field), str) and done[self._reply_field].strip():
            reply = done[self._reply_field].strip()
        elif collected:
            reply = "".join(collected).strip()

        if not reply:
            raise AgentError(f"{self.spec.label} finished without saying anything.")

        meta: dict[str, Any] = {"agent": self.spec.id}
        if done:
            for key in ("runtime", "runtimeLabel", "sessionId", "ms", "costUsd"):
                if key in done:
                    meta[key] = done[key]
        return AgentReply(text=reply, meta=meta)
