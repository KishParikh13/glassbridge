from __future__ import annotations

import logging
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from urllib.parse import quote

import anyio
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, StreamingResponse

from .config import Settings
from .llm import ClaudeVision
from .agents import AgentError, AgentRegistry, build_registry
from .sessions import SessionStore
from .stt import Transcriber, make_transcriber
from .tts import ElevenLabsStreamingTTS

logger = logging.getLogger("glassbridge")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")


class AppState:
    settings: Settings
    transcriber: Transcriber
    llm: ClaudeVision
    tts: ElevenLabsStreamingTTS
    sessions: SessionStore
    agents: AgentRegistry


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = Settings.from_env()
    state = AppState()
    state.settings = settings

    state.transcriber = make_transcriber(settings)
    # Whisper's warmup is a heavy model load, so push it to a thread rather than block the
    # event loop. Groq's is a log line, and costs nothing to run the same way.
    await anyio.to_thread.run_sync(state.transcriber.warmup)

    state.llm = ClaudeVision(
        api_key=settings.anthropic_api_key,
        model=settings.anthropic_model,
        max_tokens=settings.anthropic_max_tokens,
        system_prompt=settings.system_prompt,
        enable_web_search=settings.enable_web_search,
        enable_local_tools=settings.enable_local_tools,
    )
    state.tts = ElevenLabsStreamingTTS(
        api_key=settings.elevenlabs_api_key,
        voice_id=settings.elevenlabs_voice_id,
        model_id=settings.elevenlabs_model_id,
        output_format=settings.elevenlabs_output_format,
    )
    state.sessions = SessionStore(max_turns=settings.history_turns)
    state.agents = build_registry(settings, state.llm, state.sessions)

    app.state.gb = state
    logger.info(
        "Glassbridge ready on %s:%d — agents: %s",
        settings.host,
        settings.port,
        ", ".join(f"{s.id} ({s.wake_phrase!r})" for s in state.agents.specs()),
    )
    yield


app = FastAPI(title="Glassbridge", lifespan=lifespan)


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/agents")
async def agents_list() -> dict[str, object]:
    """What the glasses can talk to, and the phrase that reaches each one.

    The device calls this at launch and arms a trigger phrase per entry, which is what
    makes adding an assistant a config edit rather than an app release.
    """
    state: AppState = app.state.gb
    return {
        "default": state.agents.default.spec.id,
        "agents": [spec.as_dict() for spec in state.agents.specs()],
    }


@app.post("/ask")
async def ask(
    audio: UploadFile = File(...),
    # Optional: the app only captures when the user says "look". Most questions are
    # language, not vision, and a photo nobody asked for costs latency and tokens.
    image: UploadFile | None = File(default=None),
    context_frames: list[UploadFile] = File(default=[]),
    session_id: str | None = Form(default=None),
    text_override: str | None = Form(default=None),
    model: str | None = Form(default=None),
    # Which assistant to route to; see GET /agents. Absent means the built-in one.
    agent: str | None = Form(default=None),
) -> StreamingResponse:
    state: AppState = app.state.gb
    t_start = time.perf_counter()

    audio_bytes = await audio.read()
    image_bytes = await image.read() if image is not None else None
    if not audio_bytes:
        raise HTTPException(400, "audio file is empty")

    # Optional rolling-context frames (oldest -> newest) for live-vision awareness.
    context_bytes: list[bytes] = []
    for frame in context_frames:
        data = await frame.read()
        if data:
            context_bytes.append(data)

    if text_override and text_override.strip():
        user_text = text_override.strip()
        transcript_lang = "override"
        t_stt = 0.0
        logger.info("Using text_override (skipping STT): %r", user_text[:80])
    else:
        t0 = time.perf_counter()
        result = await anyio.to_thread.run_sync(
            state.transcriber.transcribe, audio_bytes, audio.filename or "audio.wav"
        )
        t_stt = time.perf_counter() - t0
        user_text = result.text
        transcript_lang = result.language
        logger.info("STT %.2fs lang=%s: %r", t_stt, transcript_lang, user_text[:80])

    # Which assistant answers. The device sends the id that matches the wake phrase it
    # heard; an unknown id falls back to the built-in agent rather than failing the turn.
    selected = state.agents.get(agent)
    images = [*context_bytes, image_bytes] if image_bytes else list(context_bytes)

    t0 = time.perf_counter()
    try:
        reply = await anyio.to_thread.run_sync(
            lambda: selected.respond(
                text=user_text,
                images=images,
                session_id=session_id or "",
                model=model,
            )
        )
    except AgentError as exc:
        # Phrased to be spoken aloud: this comes back through the glasses, not a console.
        logger.warning("Agent %s failed: %s", selected.spec.id, exc)
        raise HTTPException(502, str(exc)) from exc
    t_llm = time.perf_counter() - t0
    logger.info(
        "AGENT %s %.2fs meta=%s reply=%r",
        selected.spec.id,
        t_llm,
        {k: v for k, v in reply.meta.items() if k != "agent"},
        reply.text[:120],
    )

    async def stream_mp3() -> AsyncIterator[bytes]:
        # ElevenLabs SDK is sync; bridge each chunk through a worker thread.
        gen = state.tts.synthesize(reply.text)
        loop_t0 = time.perf_counter()
        chunk_count = 0
        first_chunk_t = None
        try:
            while True:
                chunk = await anyio.to_thread.run_sync(next, gen, None)
                if chunk is None:
                    break
                if first_chunk_t is None:
                    first_chunk_t = time.perf_counter() - loop_t0
                chunk_count += 1
                yield chunk
        finally:
            total = time.perf_counter() - t_start
            logger.info(
                "DONE total=%.2fs stt=%.2fs llm=%.2fs tts_first=%.2fs tts_chunks=%d",
                total,
                t_stt,
                t_llm,
                first_chunk_t or 0.0,
                chunk_count,
            )

    headers = {
        "X-Glassbridge-Transcript": quote(user_text, safe=""),
        "X-Glassbridge-Reply": quote(reply.text, safe=""),
        "X-Glassbridge-Lang": transcript_lang,
        "X-Glassbridge-Latency-Stt": f"{t_stt:.3f}",
        "X-Glassbridge-Latency-Llm": f"{t_llm:.3f}",
        "X-Glassbridge-Tools": quote(str(reply.meta.get("tools") or ""), safe=""),
        "X-Glassbridge-Agent": quote(selected.spec.id, safe=""),
        "Cache-Control": "no-store",
    }
    return StreamingResponse(stream_mp3(), media_type="audio/mpeg", headers=headers)


@app.exception_handler(Exception)
async def unhandled_exception(_, exc: Exception) -> JSONResponse:
    logger.exception("Unhandled exception")
    return JSONResponse(status_code=500, content={"detail": str(exc)})
