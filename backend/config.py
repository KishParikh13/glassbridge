from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    anthropic_api_key: str
    elevenlabs_api_key: str

    # Speech to text. "auto" uses Groq when a key is present and falls back to local
    # Whisper when it isn't, so the default works either way. Whisper dominates the
    # latency budget (5-8s of a 4-13s round trip); Groq is typically under a second.
    stt_provider: str = "auto"          # auto | groq | whisper
    groq_api_key: str = ""
    groq_stt_model: str = "whisper-large-v3-turbo"

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
            stt_provider=os.environ.get("STT_PROVIDER", cls.stt_provider),
            groq_api_key=os.environ.get("GROQ_API_KEY", "").strip(),
            groq_stt_model=os.environ.get("GROQ_STT_MODEL", cls.groq_stt_model),
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
        )


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}
