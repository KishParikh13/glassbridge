"""Agent layer tests. Run: python -m unittest discover -s backend/tests -v

No network and no API keys: the gateway agent is exercised against a real local HTTP
server speaking the NDJSON contract, so the parsing is tested for real rather than mocked
into agreeing with itself.
"""

from __future__ import annotations

import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

from backend.agents import AgentError, AgentRegistry, AgentSpec, GatewayAgent


def spec(agent_id: str = "test", wake: str = "hey test", images: bool = False) -> AgentSpec:
    return AgentSpec(id=agent_id, label=agent_id.title(), wake_phrase=wake, accepts_images=images)


class _Handler(BaseHTTPRequestHandler):
    """Speaks the gateway contract. `script` decides what each request gets back."""

    script: list[str] = []
    status: int = 200
    last_body: dict | None = None
    last_auth: str | None = None

    def do_GET(self):  # noqa: N802
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        type(self).last_body = json.loads(raw) if raw else {}
        type(self).last_auth = self.headers.get("Authorization")
        self.send_response(type(self).status)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        for line in type(self).script:
            self.wfile.write((line + "\n").encode())
            self.wfile.flush()

    def log_message(self, *args):
        pass


class GatewayAgentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), _Handler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def agent(self, **kwargs) -> GatewayAgent:
        return GatewayAgent(
            spec=spec(),
            url=f"http://127.0.0.1:{self.port}/chat",
            timeout_s=5.0,
            **kwargs,
        )

    def setUp(self):
        _Handler.status = 200
        _Handler.script = []
        _Handler.last_body = None
        _Handler.last_auth = None

    def test_prefers_done_text(self):
        _Handler.script = [
            '{"type":"status","status":"queued"}',
            '{"type":"text","text":"partial "}',
            '{"type":"done","ok":true,"text":"the whole answer","ms":42}',
        ]
        reply = self.agent().respond(text="hi", images=[], session_id="s1")
        self.assertEqual(reply.text, "the whole answer")
        self.assertEqual(reply.meta["ms"], 42)

    def test_falls_back_to_streamed_text_when_done_has_none(self):
        _Handler.script = [
            '{"type":"text","text":"one "}',
            '{"type":"text","text":"two"}',
            '{"type":"done","ok":true}',
        ]
        reply = self.agent().respond(text="hi", images=[], session_id="s1")
        self.assertEqual(reply.text, "one two")

    def test_thread_id_is_stable_and_prefixed(self):
        _Handler.script = ['{"type":"done","ok":true,"text":"ok"}']
        self.agent(thread_prefix="gb").respond(text="hi", images=[], session_id="abc")
        self.assertEqual(_Handler.last_body["threadId"], "gb-abc")
        self.assertEqual(_Handler.last_body["text"], "hi")

    def test_bearer_token_is_sent(self):
        _Handler.script = ['{"type":"done","ok":true,"text":"ok"}']
        self.agent(token="sekret").respond(text="hi", images=[], session_id="s1")
        self.assertEqual(_Handler.last_auth, "Bearer sekret")

    def test_custom_field_names(self):
        _Handler.script = ['{"type":"done","ok":true,"body":"mapped"}']
        agent = self.agent(text_field="message", thread_field="conversation_id", reply_field="body")
        reply = agent.respond(text="hi", images=[], session_id="s1")
        self.assertEqual(reply.text, "mapped")
        self.assertIn("message", _Handler.last_body)
        self.assertIn("conversation_id", _Handler.last_body)

    def test_extra_body_is_merged(self):
        _Handler.script = ['{"type":"done","ok":true,"text":"ok"}']
        self.agent(extra_body={"stream": True}).respond(text="hi", images=[], session_id="s1")
        self.assertIs(_Handler.last_body["stream"], True)

    def test_error_event_raises(self):
        _Handler.script = ['{"type":"error","error":"upstream exploded"}']
        with self.assertRaises(AgentError) as ctx:
            self.agent().respond(text="hi", images=[], session_id="s1")
        self.assertIn("upstream exploded", str(ctx.exception))

    def test_empty_reply_raises_rather_than_returning_silence(self):
        _Handler.script = ['{"type":"done","ok":true,"text":"   "}']
        with self.assertRaises(AgentError):
            self.agent().respond(text="hi", images=[], session_id="s1")

    def test_non_200_raises(self):
        _Handler.status = 500
        _Handler.script = []
        with self.assertRaises(AgentError):
            self.agent().respond(text="hi", images=[], session_id="s1")

    def test_unreachable_raises_agent_error(self):
        agent = GatewayAgent(spec=spec(), url="http://127.0.0.1:1/chat", timeout_s=2.0)
        with self.assertRaises(AgentError):
            agent.respond(text="hi", images=[], session_id="s1")

    def test_malformed_lines_are_skipped(self):
        _Handler.script = [
            "not json at all",
            "",
            '{"type":"done","ok":true,"text":"survived"}',
        ]
        reply = self.agent().respond(text="hi", images=[], session_id="s1")
        self.assertEqual(reply.text, "survived")

    def test_images_are_dropped_not_fatal(self):
        _Handler.script = ['{"type":"done","ok":true,"text":"ok"}']
        reply = self.agent().respond(text="hi", images=[b"jpegbytes"], session_id="s1")
        self.assertEqual(reply.text, "ok")


class _Stub:
    def __init__(self, s: AgentSpec):
        self.spec = s

    def respond(self, **kwargs):
        raise NotImplementedError

    def health(self) -> bool:
        return True


class RegistryTests(unittest.TestCase):
    def registry(self) -> AgentRegistry:
        return AgentRegistry(
            [_Stub(spec("glass", "hey glass", images=True)), _Stub(spec("kishos", "hey kishos"))],
            default_id="glass",
        )

    def test_resolves_by_id(self):
        self.assertEqual(self.registry().get("kishos").spec.id, "kishos")

    def test_unknown_id_falls_back_to_default(self):
        # A renamed config entry must not cost the user their question.
        self.assertEqual(self.registry().get("nope").spec.id, "glass")

    def test_none_is_default(self):
        self.assertEqual(self.registry().get(None).spec.id, "glass")

    def test_id_is_case_and_space_insensitive(self):
        self.assertEqual(self.registry().get("  KishOS ").spec.id, "kishos")

    def test_default_is_listed_first(self):
        self.assertEqual([s.id for s in self.registry().specs()][0], "glass")

    def test_missing_default_is_a_startup_error(self):
        with self.assertRaises(RuntimeError):
            AgentRegistry([_Stub(spec("kishos", "hey kishos"))], default_id="glass")


if __name__ == "__main__":
    unittest.main()
