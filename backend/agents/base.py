from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable


@dataclass
class AgentReply:
    """What any agent gives back. Everything past `text` is for logs and headers."""

    text: str
    meta: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class AgentSpec:
    """The part of an agent the rest of the system needs to know about.

    `wake_phrase` is the contract with the glasses: the app asks the backend which agents
    exist and arms a trigger phrase for each. Adding an agent is a config entry, not a
    code change, and the phrase shows up on the device without rebuilding it.
    """

    id: str
    label: str
    wake_phrase: str
    accepts_images: bool
    description: str = ""

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "label": self.label,
            "wakePhrase": self.wake_phrase,
            "acceptsImages": self.accepts_images,
            "description": self.description,
        }


@runtime_checkable
class Agent(Protocol):
    """Something that can answer a spoken question.

    Deliberately narrow. An agent gets text, optionally what the camera saw, and an id for
    the conversation it belongs to. How it remembers, what tools it has, and where it runs
    are entirely its own business — which is what makes a local Claude call and somebody
    else's HTTP service interchangeable here.

    Implementations block; the caller runs them off the event loop.
    """

    spec: AgentSpec

    def respond(
        self,
        *,
        text: str,
        images: list[bytes],
        session_id: str,
        model: str | None = None,
    ) -> AgentReply: ...

    def health(self) -> bool: ...


class AgentError(RuntimeError):
    """Raised for a failure the user should hear about, phrased for speaking aloud."""
