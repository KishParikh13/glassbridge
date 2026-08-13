from __future__ import annotations

from typing import TYPE_CHECKING

from .base import AgentReply, AgentSpec

if TYPE_CHECKING:
    from ..llm import ClaudeVision
    from ..sessions import SessionStore


class ClaudeAgent:
    """The built-in agent: Claude, with eyes and web search.

    This is the general-purpose one and the reason the product exists — it answers about
    whatever is in front of you and knows nothing about you personally. Unlike a gateway
    agent it does not keep its own memory, so the rolling history lives here.
    """

    def __init__(self, spec: AgentSpec, llm: ClaudeVision, sessions: SessionStore) -> None:
        self.spec = spec
        self._llm = llm
        self._sessions = sessions

    def health(self) -> bool:
        return True

    def respond(
        self,
        *,
        text: str,
        images: list[bytes],
        session_id: str,
        model: str | None = None,
    ) -> AgentReply:
        history = self._sessions.get(session_id) if session_id else []
        current = images[-1] if images else None
        context = images[:-1] if len(images) > 1 else []

        reply = self._llm.ask(
            user_text=text,
            image_bytes=current,
            history=history,
            context_images=context,
            session_id=session_id,
            model=model,
        )

        if session_id:
            from ..llm import Turn

            self._sessions.append(session_id, Turn(user_text=text, assistant_text=reply.text))

        return AgentReply(
            text=reply.text,
            meta={
                "agent": self.spec.id,
                "tools": ",".join(reply.tools_used) if reply.tools_used else "",
                "inputTokens": reply.input_tokens,
                "outputTokens": reply.output_tokens,
            },
        )
