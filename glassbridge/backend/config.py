from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    anthropic_api_key: str
    elevenlabs_api_key: str

    whisper_model: str = "distil-large-v3"
    whisper_device: str = "cpu"
    whisper_compute_type: str = "int8"

    anthropic_model: str = "claude-sonnet-4-6"
    anthropic_max_tokens: int = 256

    elevenlabs_voice_id: str = "21m00Tcm4TlvDq8ikWAM"  # Rachel
    elevenlabs_model_id: str = "eleven_flash_v2_5"
    elevenlabs_output_format: str = "mp3_44100_64"

    host: str = "0.0.0.0"
    port: int = 8082

    enable_web_search: bool = True
    enable_local_tools: bool = True

    # MARK: – Claude Code voice-control mode
    # Driver: "agent" runs Claude Code sessions here via the Agent SDK; "remote"
    # proxies to another Glassbridge backend (e.g. your Mac over Tailscale/LAN).
    code_driver: str = "agent"
    remote_bridge_url: str = ""
    code_agent_model: str = ""  # blank = SDK/CLI default
    code_agent_cwd: str = ""  # working dir for agent sessions; blank = backend cwd
    code_permission_mode: str = "bypassPermissions"
    code_speak_max_chars: int = 700
    code_system_prompt: str = (
        "You are a Claude Code agent the user is driving by voice. They cannot "
        "see long output while speaking, so when you finish a task, summarize "
        "what you did in 1-3 plain spoken sentences. Do the work first, then the "
        "summary. Avoid reading code or file paths aloud unless asked."
    )

    system_prompt: str = (
        "You are a helpful assistant the user talks to through smart glasses. "
        "Answer in 1-3 spoken sentences. Be direct and useful. "
        "The image is what they're looking at right now; if several frames are "
        "provided they are recent views in time order (the last is current). "
        "You can search the web and use tools when they would genuinely help; "
        "otherwise just answer. "
        "Do not use markdown formatting (no asterisks, no bold, no bullets) — "
        "your reply will be spoken aloud and shown on a small screen."
    )

    history_turns: int = 3

    @classmethod
    def from_env(cls) -> "Settings":
        anthropic_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
        eleven_key = os.environ.get("ELEVENLABS_API_KEY", "").strip()
        if not anthropic_key:
            raise RuntimeError("ANTHROPIC_API_KEY missing — put it in .env or export it.")
        if not eleven_key:
            raise RuntimeError("ELEVENLABS_API_KEY missing — put it in .env or export it.")
        return cls(
            anthropic_api_key=anthropic_key,
            elevenlabs_api_key=eleven_key,
            whisper_model=os.environ.get("WHISPER_MODEL", cls.whisper_model),
            whisper_device=os.environ.get("WHISPER_DEVICE", cls.whisper_device),
            whisper_compute_type=os.environ.get("WHISPER_COMPUTE", cls.whisper_compute_type),
            anthropic_model=os.environ.get("ANTHROPIC_MODEL", cls.anthropic_model),
            anthropic_max_tokens=int(os.environ.get("ANTHROPIC_MAX_TOKENS", cls.anthropic_max_tokens)),
            elevenlabs_voice_id=os.environ.get("ELEVENLABS_VOICE_ID", cls.elevenlabs_voice_id),
            elevenlabs_model_id=os.environ.get("ELEVENLABS_MODEL_ID", cls.elevenlabs_model_id),
            elevenlabs_output_format=os.environ.get(
                "ELEVENLABS_OUTPUT_FORMAT", cls.elevenlabs_output_format
            ),
            port=int(os.environ.get("PORT", cls.port)),
            host=os.environ.get("HOST", cls.host),
            enable_web_search=_env_bool("GB_WEB_SEARCH", cls.enable_web_search),
            enable_local_tools=_env_bool("GB_LOCAL_TOOLS", cls.enable_local_tools),
            code_driver=os.environ.get("GB_CODE_DRIVER", cls.code_driver),
            remote_bridge_url=os.environ.get("GB_REMOTE_BRIDGE_URL", cls.remote_bridge_url),
            code_agent_model=os.environ.get("GB_CODE_MODEL", cls.code_agent_model),
            code_agent_cwd=os.environ.get("GB_CODE_CWD", cls.code_agent_cwd),
            code_permission_mode=os.environ.get("GB_CODE_PERMISSION_MODE", cls.code_permission_mode),
            code_speak_max_chars=int(
                os.environ.get("GB_CODE_SPEAK_MAX_CHARS", cls.code_speak_max_chars)
            ),
        )


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}
