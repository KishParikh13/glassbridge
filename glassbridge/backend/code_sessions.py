"""Claude Code session management for voice control.

Glassbridge's original loop is a one-shot vision Q&A. This module adds a second
mode: a small registry of long-lived *Claude Code sessions* you talk to by
voice — "start a new session", "list my sessions", "switch to the parser one",
then just speak your request and hear the agent's reply.

Two drivers sit behind one interface so the same iOS app works either way:

* ``AgentSDKDriver`` — runs real Claude Code agent sessions in this process
  using the Claude Agent SDK. Use it when the backend runs where you want the
  work to happen (a cloud box, or your Mac).
* ``RemoteDriver`` — a thin HTTP proxy to another Glassbridge backend running
  the Agent SDK (e.g. on your Mac, reachable over Tailscale/LAN). This is the
  "remote control" path: the phone talks to a cloud backend, which relays
  code-session calls to your machine.

Everything is in-memory and single-user, matching the rest of Glassbridge.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
import uuid
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)


# MARK: – Data shapes


@dataclass
class CodeSessionInfo:
    """What the app needs to show + pick a session by voice."""

    id: str
    title: str
    driver: str
    created_at: float
    last_activity: float
    turn_count: int

    def to_dict(self) -> dict[str, object]:
        return {
            "id": self.id,
            "title": self.title,
            "driver": self.driver,
            "created_at": self.created_at,
            "last_activity": self.last_activity,
            "turn_count": self.turn_count,
        }


@dataclass
class CodeReply:
    """The agent's answer to one turn."""

    text: str
    session_id: str
    tools_used: list[str] = field(default_factory=list)


# MARK: – Driver interface


class CodeSessionDriver:
    """Manages a set of Claude Code conversations behind a uniform API."""

    name = "base"

    async def list_sessions(self) -> list[CodeSessionInfo]:  # pragma: no cover - abstract
        raise NotImplementedError

    async def create_session(self, title: str | None = None) -> CodeSessionInfo:  # pragma: no cover
        raise NotImplementedError

    async def send(self, session_id: str, text: str) -> CodeReply:  # pragma: no cover - abstract
        raise NotImplementedError

    async def aclose(self) -> None:  # pragma: no cover - optional
        return None


# MARK: – Agent SDK driver (sessions live in this process)


class _AgentSession:
    """One live Claude Code conversation via the Agent SDK."""

    def __init__(self, local_id: str, title: str) -> None:
        self.local_id = local_id
        self.title = title
        self.sdk_session_id: str | None = None
        self.created_at = time.time()
        self.last_activity = self.created_at
        self.turn_count = 0
        self._client: object | None = None  # ClaudeSDKClient, typed loosely to avoid import
        self._lock = asyncio.Lock()

    @property
    def public_id(self) -> str:
        return self.sdk_session_id or self.local_id


class AgentSDKDriver(CodeSessionDriver):
    """Runs real Claude Code agent sessions here using ``claude-agent-sdk``.

    The SDK (and the ``claude`` CLI it drives) must be installed where this runs.
    Imports are lazy so the rest of the backend works without it installed.
    """

    name = "agent"

    def __init__(
        self,
        *,
        model: str | None = None,
        cwd: str | None = None,
        permission_mode: str = "bypassPermissions",
        system_prompt: str | None = None,
    ) -> None:
        self._model = model
        self._cwd = cwd
        self._permission_mode = permission_mode
        self._system_prompt = system_prompt
        self._sessions: dict[str, _AgentSession] = {}
        self._lock = asyncio.Lock()

    def _import_sdk(self):
        try:
            import claude_agent_sdk as sdk  # type: ignore
        except ImportError as exc:  # pragma: no cover - environment dependent
            raise RuntimeError(
                "claude-agent-sdk is not installed. Run `pip install claude-agent-sdk` "
                "and make sure the `claude` CLI is on PATH (npm i -g @anthropic-ai/claude-code)."
            ) from exc
        return sdk

    def _make_options(self):
        sdk = self._import_sdk()
        kwargs: dict[str, object] = {"permission_mode": self._permission_mode}
        if self._model:
            kwargs["model"] = self._model
        if self._cwd:
            kwargs["cwd"] = self._cwd
        if self._system_prompt:
            # Append to Claude Code's built-in agent prompt rather than replacing
            # it — a bare string would strip the coding/tool behavior we want.
            kwargs["system_prompt"] = {
                "type": "preset",
                "preset": "claude_code",
                "append": self._system_prompt,
            }
        return sdk.ClaudeAgentOptions(**kwargs)

    async def list_sessions(self) -> list[CodeSessionInfo]:
        async with self._lock:
            sessions = list(self._sessions.values())
        sessions.sort(key=lambda s: s.created_at)
        return [
            CodeSessionInfo(
                id=s.public_id,
                title=s.title,
                driver=self.name,
                created_at=s.created_at,
                last_activity=s.last_activity,
                turn_count=s.turn_count,
            )
            for s in sessions
        ]

    async def create_session(self, title: str | None = None) -> CodeSessionInfo:
        sdk = self._import_sdk()
        local_id = uuid.uuid4().hex[:12]
        async with self._lock:
            n = len(self._sessions) + 1
        sess = _AgentSession(local_id=local_id, title=(title or "").strip() or f"Session {n}")
        client = sdk.ClaudeSDKClient(options=self._make_options())
        await client.connect()
        sess._client = client
        async with self._lock:
            self._sessions[local_id] = sess
        logger.info("Created agent session local_id=%s title=%r", local_id, sess.title)
        return CodeSessionInfo(
            id=sess.public_id,
            title=sess.title,
            driver=self.name,
            created_at=sess.created_at,
            last_activity=sess.last_activity,
            turn_count=sess.turn_count,
        )

    def _find(self, session_id: str) -> _AgentSession | None:
        for s in self._sessions.values():
            if session_id in (s.local_id, s.sdk_session_id):
                return s
        return None

    async def send(self, session_id: str, text: str) -> CodeReply:
        sdk = self._import_sdk()
        async with self._lock:
            sess = self._find(session_id)
        if sess is None:
            raise KeyError(f"Unknown session: {session_id}")
        client = sess._client
        if client is None:
            raise RuntimeError("Session has no live client.")

        async with sess._lock:
            await client.query(text)  # type: ignore[attr-defined]
            chunks: list[str] = []
            tools: list[str] = []
            async for msg in client.receive_response():  # type: ignore[attr-defined]
                # Capture the SDK's own session id the first time we see it so the
                # app's public id matches what `claude --resume` would expect.
                sid = getattr(msg, "session_id", None)
                if sid and not sess.sdk_session_id:
                    sess.sdk_session_id = sid
                if isinstance(msg, sdk.AssistantMessage):
                    for block in msg.content:
                        if isinstance(block, sdk.TextBlock):
                            chunks.append(block.text)
                        elif isinstance(block, sdk.ToolUseBlock):
                            tools.append(block.name)
                elif isinstance(msg, sdk.ResultMessage):
                    if not chunks and getattr(msg, "result", None):
                        chunks.append(str(msg.result))

            sess.turn_count += 1
            sess.last_activity = time.time()
            # Name an untitled session after its first message.
            if sess.turn_count == 1 and re.fullmatch(r"Session \d+", sess.title):
                sess.title = _derive_title(text)

        reply = "".join(chunks).strip()
        return CodeReply(text=reply, session_id=sess.public_id, tools_used=tools)

    async def aclose(self) -> None:
        async with self._lock:
            sessions = list(self._sessions.values())
            self._sessions.clear()
        for s in sessions:
            client = s._client
            if client is not None:
                try:
                    await client.disconnect()  # type: ignore[attr-defined]
                except Exception:  # pragma: no cover - best effort
                    pass


# MARK: – Remote driver (proxy to another backend)


class RemoteDriver(CodeSessionDriver):
    """Proxies code-session calls to another Glassbridge backend over HTTP.

    Point ``base_url`` at a machine running this same backend with the Agent SDK
    driver (your Mac over Tailscale/LAN). That box does the real work; this one
    just relays. The remote endpoints are the JSON shapes in ``main.py``:
    ``GET/POST /code/sessions`` and ``POST /code/text``.
    """

    name = "remote"

    def __init__(self, base_url: str, timeout: float = 120.0) -> None:
        if not base_url:
            raise RuntimeError("GB_REMOTE_BRIDGE_URL is required for the remote driver.")
        import httpx

        self._base = base_url.rstrip("/")
        self._client = httpx.AsyncClient(timeout=httpx.Timeout(timeout, connect=10.0))

    @staticmethod
    def _info(d: dict) -> CodeSessionInfo:
        return CodeSessionInfo(
            id=str(d.get("id", "")),
            title=str(d.get("title", "")),
            driver=str(d.get("driver", "remote")),
            created_at=float(d.get("created_at", 0.0)),
            last_activity=float(d.get("last_activity", 0.0)),
            turn_count=int(d.get("turn_count", 0)),
        )

    async def list_sessions(self) -> list[CodeSessionInfo]:
        r = await self._client.get(f"{self._base}/code/sessions")
        r.raise_for_status()
        return [self._info(d) for d in r.json().get("sessions", [])]

    async def create_session(self, title: str | None = None) -> CodeSessionInfo:
        r = await self._client.post(f"{self._base}/code/sessions", json={"title": title})
        r.raise_for_status()
        return self._info(r.json())

    async def send(self, session_id: str, text: str) -> CodeReply:
        # /code/send forwards raw text to a specific session — no intent routing
        # (the local manager already decided this is a chat turn).
        r = await self._client.post(
            f"{self._base}/code/send",
            data={"session_id": session_id, "text": text},
        )
        r.raise_for_status()
        body = r.json()
        return CodeReply(
            text=str(body.get("reply", "")),
            session_id=str(body.get("session_id", session_id)),
            tools_used=list(body.get("tools", [])),
        )

    async def aclose(self) -> None:
        await self._client.aclose()


# MARK: – Manager (driver + "active session" pointer + intent dispatch)


@dataclass
class CodeTurnResult:
    action: str  # create | list | switch | chat | help | error
    spoken: str  # spoken-friendly text (TTS this)
    reply_full: str  # full text for on-screen display
    transcript: str
    active_session_id: str | None
    sessions: list[CodeSessionInfo]
    tools_used: list[str] = field(default_factory=list)


class CodeSessionManager:
    """Holds the driver, the currently-active session, and routes spoken intents."""

    def __init__(self, driver: CodeSessionDriver, *, speak_max_chars: int = 700) -> None:
        self._driver = driver
        self._speak_max_chars = speak_max_chars
        self._active_id: str | None = None

    @property
    def driver_name(self) -> str:
        return self._driver.name

    async def list_sessions(self) -> list[CodeSessionInfo]:
        return await self._driver.list_sessions()

    async def create_session(self, title: str | None = None) -> CodeSessionInfo:
        info = await self._driver.create_session(title)
        self._active_id = info.id
        return info

    async def send_to(self, session_id: str, text: str) -> CodeReply:
        reply = await self._driver.send(session_id, text)
        # The SDK may assign its real session id on first turn; track it.
        self._active_id = reply.session_id
        return reply

    async def handle_transcript(
        self, transcript: str, *, active_session_id: str | None = None
    ) -> CodeTurnResult:
        """Interpret one spoken line and either run a command or forward to chat."""
        if active_session_id:
            self._active_id = active_session_id

        text = (transcript or "").strip()
        intent = interpret(text)
        sessions = await self._driver.list_sessions()

        if intent.kind == "help" or not text:
            spoken = (
                "Say 'new session' to start one, 'list sessions' to hear them, "
                "'switch to' a name or number to pick one, or just tell me what to build."
            )
            return CodeTurnResult("help", spoken, spoken, text, self._active_id, sessions)

        if intent.kind == "list":
            sessions = await self._driver.list_sessions()
            spoken = _describe_sessions(sessions)
            return CodeTurnResult("list", spoken, spoken, text, self._active_id, sessions)

        if intent.kind == "create":
            info = await self.create_session(intent.title)
            sessions = await self._driver.list_sessions()
            spoken = f"Started a new session: {info.title}. What should it do?"
            # If the user said "new session AND <task>", forward the task right away.
            if intent.remainder:
                reply = await self.send_to(info.id, intent.remainder)
                spoken = _to_spoken(reply.text, self._speak_max_chars)
                sessions = await self._driver.list_sessions()
                return CodeTurnResult(
                    "chat", spoken, reply.text, text, self._active_id, sessions, reply.tools_used
                )
            return CodeTurnResult("create", spoken, spoken, text, self._active_id, sessions)

        if intent.kind == "switch":
            target = _resolve_target(intent.target, sessions)
            if target is None:
                spoken = (
                    f"I couldn't find a session matching '{intent.target}'. "
                    + _describe_sessions(sessions)
                )
                return CodeTurnResult("switch", spoken, spoken, text, self._active_id, sessions)
            self._active_id = target.id
            spoken = f"Switched to {target.title}."
            return CodeTurnResult("switch", spoken, spoken, text, target.id, sessions)

        # Default: forward to the active session, creating one if needed.
        if self._active_id is None:
            info = await self.create_session(None)
            sessions = await self._driver.list_sessions()
        reply = await self.send_to(self._active_id, text)  # type: ignore[arg-type]
        spoken = _to_spoken(reply.text, self._speak_max_chars)
        sessions = await self._driver.list_sessions()
        return CodeTurnResult(
            "chat", spoken, reply.text, text, self._active_id, sessions, reply.tools_used
        )

    async def aclose(self) -> None:
        await self._driver.aclose()


# MARK: – Intent parsing


@dataclass
class Intent:
    kind: str  # create | list | switch | chat | help
    title: str | None = None  # for create
    target: str | None = None  # for switch
    remainder: str | None = None  # for create-and-chat


_CREATE_RE = re.compile(
    r"^\s*(?:start|create|open|begin|make|new)\s+"
    r"(?:a\s+)?(?:new\s+)?(?:session|chat|conversation)\b",
    re.IGNORECASE,
)
_CREATE_NAMED_RE = re.compile(
    r"(?:called|named|for|about|to)\s+(?P<title>.+)$", re.IGNORECASE
)
_LIST_RE = re.compile(
    r"^\s*(?:list|show|what(?:'s|\s+are)?|which)\b.*\b(?:session|sessions|chat|chats|conversation|conversations)\b",
    re.IGNORECASE,
)
_SWITCH_RE = re.compile(
    r"^\s*(?:switch|go|change|move|jump)\s+(?:to|over\s+to|into|back\s+to)\s+(?P<target>.+)$",
    re.IGNORECASE,
)
_SWITCH_OPEN_RE = re.compile(
    r"^\s*(?:open|select|use|resume|pick)\s+(?:the\s+)?(?P<target>.+?)\s*"
    r"(?:session|chat|conversation)?\s*$",
    re.IGNORECASE,
)
_HELP_RE = re.compile(r"^\s*(?:help|what can you do|commands?)\s*\??\s*$", re.IGNORECASE)


def interpret(text: str) -> Intent:
    """Map a spoken line to a command, defaulting to free-form chat."""
    t = text.strip()
    if not t:
        return Intent("help")
    if _HELP_RE.match(t):
        return Intent("help")

    if _CREATE_RE.match(t):
        title = None
        remainder = None
        # "...called X" / "...about X" gives an explicit title.
        m = _CREATE_NAMED_RE.search(t)
        if m:
            title = m.group("title").strip(" .")
        else:
            # "new session, <task>" — split on the first comma / "and then" / "and".
            parts = re.split(r"\s*(?:,|;|\band then\b|\bthen\b|\band\b)\s+", t, maxsplit=1)
            if len(parts) == 2 and len(parts[1].split()) >= 2:
                remainder = parts[1].strip()
        return Intent("create", title=title, remainder=remainder)

    if _LIST_RE.match(t):
        return Intent("list")

    m = _SWITCH_RE.match(t)
    if m:
        return Intent("switch", target=_clean_target(m.group("target")))

    m = _SWITCH_OPEN_RE.match(t)
    if m and ("session" in t.lower() or "chat" in t.lower() or "conversation" in t.lower()):
        return Intent("switch", target=_clean_target(m.group("target")))

    return Intent("chat")


def _clean_target(s: str) -> str:
    s = s.strip(" .")
    s = re.sub(r"\b(?:session|chat|conversation)\b", "", s, flags=re.IGNORECASE).strip()
    return s


# MARK: – Helpers


_NUMBER_WORDS = {
    "one": 1, "first": 1, "two": 2, "second": 2, "three": 3, "third": 3,
    "four": 4, "fourth": 4, "five": 5, "fifth": 5, "six": 6, "sixth": 6,
    "seven": 7, "seventh": 7, "eight": 8, "eighth": 8, "nine": 9, "ninth": 9,
    "ten": 10, "tenth": 10, "last": -1,
}


def _resolve_target(target: str | None, sessions: list[CodeSessionInfo]) -> CodeSessionInfo | None:
    if not target or not sessions:
        return None
    t = target.strip().lower()

    # By ordinal/number ("session two", "the third one", "last").
    word = t.replace("the", "").replace("one", "").strip() or t
    for token in (t, word):
        if token in _NUMBER_WORDS:
            idx = _NUMBER_WORDS[token]
            if idx == -1:
                return sessions[-1]
            if 1 <= idx <= len(sessions):
                return sessions[idx - 1]
    digits = re.search(r"\d+", t)
    if digits:
        idx = int(digits.group())
        if 1 <= idx <= len(sessions):
            return sessions[idx - 1]

    # By exact id.
    for s in sessions:
        if s.id == target:
            return s
    # By title: exact, then substring either direction.
    for s in sessions:
        if s.title.lower() == t:
            return s
    best: CodeSessionInfo | None = None
    best_overlap = 0
    for s in sessions:
        title = s.title.lower()
        if t in title or title in t:
            return s
        overlap = len(set(t.split()) & set(title.split()))
        if overlap > best_overlap:
            best_overlap, best = overlap, s
    return best if best_overlap > 0 else None


def _describe_sessions(sessions: list[CodeSessionInfo]) -> str:
    if not sessions:
        return "You have no sessions yet. Say 'new session' to start one."
    parts = [f"You have {len(sessions)} session{'s' if len(sessions) != 1 else ''}."]
    ordinals = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    for i, s in enumerate(sessions):
        label = ordinals[i] if i < len(ordinals) else str(i + 1)
        parts.append(f"{label.capitalize()}: {s.title}.")
    parts.append("Which one?")
    return " ".join(parts)


def _derive_title(text: str, max_words: int = 6) -> str:
    words = re.sub(r"\s+", " ", text.strip()).split(" ")
    title = " ".join(words[:max_words])
    return (title[:48] + "…") if len(title) > 48 else (title or "Session")


def _to_spoken(text: str, max_chars: int) -> str:
    """Strip markdown noise and trim long replies for comfortable speech."""
    if not text:
        return "Done."
    # Drop fenced code blocks — they're unspeakable; mention them instead.
    had_code = "```" in text
    text = re.sub(r"```.*?```", " ", text, flags=re.DOTALL)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"^#{1,6}\s*", "", text, flags=re.MULTILINE)
    text = re.sub(r"[*_]{1,3}([^*_]+)[*_]{1,3}", r"\1", text)
    text = re.sub(r"^\s*[-*]\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"\n{2,}", ". ", text)
    text = re.sub(r"\s+", " ", text).strip()
    if had_code:
        text += " I left the code on screen."
    if len(text) <= max_chars:
        return text or "Done."
    # Cut at the last sentence boundary before the limit.
    cut = text[:max_chars]
    last = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "))
    if last > max_chars // 2:
        cut = cut[: last + 1]
    return cut.rstrip() + " There's more on screen."


def build_manager(settings) -> CodeSessionManager:
    """Construct the manager + driver from Settings."""
    driver_name = (getattr(settings, "code_driver", "agent") or "agent").lower()
    if driver_name == "remote":
        driver: CodeSessionDriver = RemoteDriver(getattr(settings, "remote_bridge_url", ""))
    else:
        driver = AgentSDKDriver(
            model=getattr(settings, "code_agent_model", None),
            cwd=getattr(settings, "code_agent_cwd", None) or None,
            permission_mode=getattr(settings, "code_permission_mode", "bypassPermissions"),
            system_prompt=getattr(settings, "code_system_prompt", None) or None,
        )
    return CodeSessionManager(driver, speak_max_chars=getattr(settings, "code_speak_max_chars", 700))
