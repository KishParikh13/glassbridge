"""Offline tests for Claude Code voice-control routing.

No external deps, no API keys, no Agent SDK — a fake driver stands in for real
sessions so we can exercise intent parsing, switching, and spoken trimming.

Run: ``python -m backend.tests.test_code_router`` from the glassbridge/ dir.
"""

from __future__ import annotations

import asyncio
import time

from backend.code_sessions import (
    CodeReply,
    CodeSessionDriver,
    CodeSessionInfo,
    CodeSessionManager,
    _to_spoken,
    interpret,
)


class FakeDriver(CodeSessionDriver):
    name = "fake"

    def __init__(self) -> None:
        self._sessions: list[CodeSessionInfo] = []
        self.sent: list[tuple[str, str]] = []

    async def list_sessions(self):
        return list(self._sessions)

    async def create_session(self, title=None):
        n = len(self._sessions) + 1
        info = CodeSessionInfo(
            id=f"sess-{n}",
            title=title or f"Session {n}",
            driver=self.name,
            created_at=time.time(),
            last_activity=time.time(),
            turn_count=0,
        )
        self._sessions.append(info)
        return info

    async def send(self, session_id, text):
        self.sent.append((session_id, text))
        return CodeReply(text=f"(reply to {text!r} in {session_id})", session_id=session_id)


def check(name: str, cond: bool) -> None:
    print(f"  {'PASS' if cond else 'FAIL'}  {name}")
    assert cond, name


def test_interpret():
    print("interpret():")
    check("new session", interpret("start a new session").kind == "create")
    check("new chat", interpret("new chat").kind == "create")
    named = interpret("create a new session called parser refactor")
    check("named create", named.kind == "create" and named.title == "parser refactor")
    combo = interpret("new session, add a health check endpoint")
    check("create+task", combo.kind == "create" and combo.remainder == "add a health check endpoint")
    check("list", interpret("list my sessions").kind == "list")
    check("which sessions", interpret("which sessions do I have").kind == "list")
    sw = interpret("switch to the parser one")
    check("switch", sw.kind == "switch" and "parser" in (sw.target or ""))
    check("open named", interpret("open the tests session").kind == "switch")
    check("plain chat", interpret("add a docstring to the parser").kind == "chat")
    check("help", interpret("help").kind == "help")


def test_spoken():
    print("_to_spoken():")
    out = _to_spoken("Here is **bold** and `code` and a list:\n- one\n- two", 700)
    check("strips markdown", "**" not in out and "`" not in out)
    code = _to_spoken("Done.\n```python\nx=1\n```", 700)
    check("mentions code", "on screen" in code)
    long = _to_spoken("Sentence one. " * 200, 200)
    check("trims long", len(long) <= 260 and "more on screen" in long)


def test_manager_flow():
    print("manager flow:")

    async def run():
        mgr = CodeSessionManager(FakeDriver(), speak_max_chars=700)

        r = await mgr.handle_transcript("start a new session called parser")
        check("create action", r.action == "create")
        check("active set", r.active_session_id == "sess-1")

        r = await mgr.handle_transcript("add a docstring to the top of the file")
        check("chat forwarded", r.action == "chat")
        check("reply present", "reply to" in r.reply_full)

        await mgr.handle_transcript("new session called tests")
        r = await mgr.handle_transcript("list sessions")
        check("list mentions both", "parser" in r.spoken and "tests" in r.spoken)

        r = await mgr.handle_transcript("switch to one")
        check("switch by ordinal", r.action == "switch" and r.active_session_id == "sess-1")

        r = await mgr.handle_transcript("switch to tests")
        check("switch by name", r.active_session_id == "sess-2")

        # Chat with no prior active session auto-creates one.
        mgr2 = CodeSessionManager(FakeDriver(), speak_max_chars=700)
        r = await mgr2.handle_transcript("fix the failing build")
        check("auto-create on chat", r.action == "chat" and r.active_session_id is not None)

    asyncio.run(run())


if __name__ == "__main__":
    test_interpret()
    test_spoken()
    test_manager_flow()
    print("\nAll code-router tests passed.")
