from __future__ import annotations

import threading
from collections import deque

from .llm import Turn


class SessionStore:
    """In-memory rolling history per session_id. Process-local; survives nothing."""

    def __init__(self, max_turns: int) -> None:
        self._max_turns = max_turns
        self._store: dict[str, deque[Turn]] = {}
        self._lock = threading.Lock()

    def get(self, session_id: str | None) -> list[Turn]:
        if not session_id:
            return []
        with self._lock:
            dq = self._store.get(session_id)
            return list(dq) if dq else []

    def append(self, session_id: str | None, turn: Turn) -> None:
        if not session_id:
            return
        with self._lock:
            dq = self._store.setdefault(session_id, deque(maxlen=self._max_turns))
            dq.append(turn)
