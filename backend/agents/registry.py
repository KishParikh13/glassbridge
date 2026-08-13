from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import TYPE_CHECKING, Any

from .base import Agent, AgentSpec
from .claude_agent import ClaudeAgent
from .gateway_agent import GatewayAgent

if TYPE_CHECKING:
    from ..config import Settings
    from ..llm import ClaudeVision
    from ..sessions import SessionStore

logger = logging.getLogger(__name__)

DEFAULT_AGENT_ID = "glass"


class AgentRegistry:
    """Every agent the glasses can talk to, keyed by id and by wake phrase.

    The device asks `GET /agents` at launch and arms one trigger phrase per entry, so
    adding an assistant is an `agents.json` edit and a backend restart — no app rebuild,
    no Swift. Someone cloning this repo points the same file at their own service.
    """

    def __init__(self, agents: list[Agent], default_id: str = DEFAULT_AGENT_ID) -> None:
        self._agents = {agent.spec.id: agent for agent in agents}
        if default_id not in self._agents:
            raise RuntimeError(
                f"Default agent {default_id!r} is not configured. "
                f"Known agents: {sorted(self._agents)}"
            )
        self._default_id = default_id

    @property
    def default(self) -> Agent:
        return self._agents[self._default_id]

    def get(self, agent_id: str | None) -> Agent:
        """Resolve an id, falling back to the default rather than failing a turn.

        A question that reaches the wrong agent is a much better outcome than a question
        that gets no answer because a config entry was renamed.
        """
        if not agent_id:
            return self.default
        agent = self._agents.get(agent_id.strip().lower())
        if agent is None:
            logger.warning("Unknown agent %r, using %r", agent_id, self._default_id)
            return self.default
        return agent

    def specs(self) -> list[AgentSpec]:
        # Default first: it is the one the app treats as the plain wake phrase.
        ordered = sorted(self._agents.values(), key=lambda a: a.spec.id != self._default_id)
        return [agent.spec for agent in ordered]


def _config_path(settings: Settings) -> Path | None:
    explicit = os.environ.get("GB_AGENTS_CONFIG", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    # Repo root, next to run.sh.
    candidate = Path(__file__).resolve().parents[2] / "agents.json"
    return candidate if candidate.is_file() else None


def _spec_from(entry: dict[str, Any]) -> AgentSpec:
    missing = [k for k in ("id", "wakePhrase") if not entry.get(k)]
    if missing:
        raise RuntimeError(f"Agent entry {entry!r} is missing {missing}.")
    return AgentSpec(
        id=str(entry["id"]).strip().lower(),
        label=str(entry.get("label") or entry["id"]),
        wake_phrase=str(entry["wakePhrase"]).strip().lower(),
        accepts_images=bool(entry.get("acceptsImages", False)),
        description=str(entry.get("description") or ""),
    )


def build_registry(
    settings: Settings,
    llm: ClaudeVision,
    sessions: SessionStore,
) -> AgentRegistry:
    """Assemble the registry from `agents.json`, falling back to the built-in agent.

    A broken or absent config must never take the product down: the built-in Claude agent
    is always registered, and a bad entry is logged and skipped rather than raised.
    """
    built_in = ClaudeAgent(
        spec=AgentSpec(
            id=DEFAULT_AGENT_ID,
            label="Glass",
            wake_phrase=settings.wake_phrase,
            accepts_images=True,
            description="Claude with eyes and web search. Knows what you are looking at, "
                        "not who you are.",
        ),
        llm=llm,
        sessions=sessions,
    )
    agents: list[Agent] = [built_in]

    path = _config_path(settings)
    if path is None:
        logger.info("No agents.json; running with the built-in agent only.")
        return AgentRegistry(agents)

    try:
        raw = json.loads(path.read_text())
    except Exception as exc:
        logger.warning("Could not read %s (%s); built-in agent only.", path, exc)
        return AgentRegistry(agents)

    for entry in raw.get("agents", []):
        try:
            spec = _spec_from(entry)
            if spec.id == DEFAULT_AGENT_ID:
                logger.warning("Agent id %r is reserved for the built-in agent; skipping.", spec.id)
                continue
            kind = str(entry.get("type") or "gateway").lower()
            if kind != "gateway":
                logger.warning("Unknown agent type %r for %r; skipping.", kind, spec.id)
                continue
            agents.append(
                GatewayAgent(
                    spec=spec,
                    url=str(entry["url"]),
                    token=entry.get("token"),
                    token_file=entry.get("tokenFile"),
                    timeout_s=float(entry.get("timeoutSeconds", 90)),
                    health_url=entry.get("healthUrl"),
                    thread_prefix=str(entry.get("threadPrefix") or "glassbridge"),
                    text_field=str(entry.get("textField") or "text"),
                    thread_field=str(entry.get("threadField") or "threadId"),
                    reply_field=str(entry.get("replyField") or "text"),
                    context=entry.get("context") or None,
                    context_field=str(entry.get("contextField") or "context"),
                    extra_body=entry.get("extraBody") or {},
                )
            )
            logger.info("Registered agent %r on wake phrase %r", spec.id, spec.wake_phrase)
        except Exception as exc:
            logger.warning("Skipping agent entry %r: %s", entry.get("id", "?"), exc)

    return AgentRegistry(agents)
