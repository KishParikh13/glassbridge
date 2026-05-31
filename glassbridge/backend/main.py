from __future__ import annotations

import json
import logging
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from urllib.parse import quote

import anyio
from fastapi import Body, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, StreamingResponse

from .code_sessions import CodeSessionManager, build_manager
from .config import Settings
from .llm import ClaudeVision, Turn
from .sessions import SessionStore
from .stt import WhisperTranscriber
from .tts import ElevenLabsStreamingTTS

logger = logging.getLogger("glassbridge")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")


class AppState:
    settings: Settings
    transcriber: WhisperTranscriber
    llm: ClaudeVision
    tts: ElevenLabsStreamingTTS
    sessions: SessionStore
    code: CodeSessionManager


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = Settings.from_env()
    state = AppState()
    state.settings = settings

    state.transcriber = WhisperTranscriber(
        model_name=settings.whisper_model,
        device=settings.whisper_device,
        compute_type=settings.whisper_compute_type,
    )
    # Heavy CPU load — push to a thread so startup isn't blocking the event loop.
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
    state.code = build_manager(settings)
    logger.info("Code session driver: %s", state.code.driver_name)

    app.state.gb = state
    logger.info("Glassbridge ready on %s:%d", settings.host, settings.port)
    try:
        yield
    finally:
        await state.code.aclose()


app = FastAPI(title="Glassbridge", lifespan=lifespan)


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/ask")
async def ask(
    audio: UploadFile = File(...),
    image: UploadFile = File(...),
    context_frames: list[UploadFile] = File(default=[]),
    session_id: str | None = Form(default=None),
    text_override: str | None = Form(default=None),
) -> StreamingResponse:
    state: AppState = app.state.gb
    t_start = time.perf_counter()

    audio_bytes = await audio.read()
    image_bytes = await image.read()
    if not audio_bytes:
        raise HTTPException(400, "audio file is empty")
    if not image_bytes:
        raise HTTPException(400, "image file is empty")

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

    history = state.sessions.get(session_id)

    t0 = time.perf_counter()
    reply = await anyio.to_thread.run_sync(
        lambda: state.llm.ask(
            user_text=user_text,
            image_bytes=image_bytes,
            image_media_type=image.content_type or "image/jpeg",
            history=history,
            context_images=context_bytes,
            session_id=session_id,
        )
    )
    t_llm = time.perf_counter() - t0
    logger.info(
        "LLM %.2fs in=%d out=%d tools=%s reply=%r",
        t_llm,
        reply.input_tokens,
        reply.output_tokens,
        ",".join(reply.tools_used) or "-",
        reply.text[:120],
    )

    state.sessions.append(session_id, Turn(user_text=user_text, assistant_text=reply.text))

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
        "X-Glassbridge-Tools": quote(",".join(reply.tools_used), safe=""),
        "Cache-Control": "no-store",
    }
    return StreamingResponse(stream_mp3(), media_type="audio/mpeg", headers=headers)


# MARK: – Claude Code voice control
#
# Talk to long-lived Claude Code sessions by voice: pick from active ones,
# start new ones, then just speak your request. /code/voice is the one the
# iOS app drives; /code/text and the /code/sessions JSON routes back it (and
# double as the wire protocol the "remote" driver proxies to).


@app.get("/code/sessions")
async def code_list_sessions() -> dict[str, object]:
    state: AppState = app.state.gb
    sessions = await state.code.list_sessions()
    return {"sessions": [s.to_dict() for s in sessions]}


@app.post("/code/sessions")
async def code_create_session(payload: dict | None = Body(default=None)) -> dict[str, object]:
    state: AppState = app.state.gb
    title = (payload or {}).get("title") if payload else None
    info = await state.code.create_session(title)
    return info.to_dict()


@app.post("/code/send")
async def code_send(
    text: str = Form(...),
    session_id: str = Form(...),
) -> dict[str, object]:
    """Forward raw text straight to a session — no intent routing.

    This is the driver-level primitive the "remote" driver proxies to: the
    routing already happened on the caller's side.
    """
    state: AppState = app.state.gb
    reply = await state.code.send_to(session_id, text)
    return {
        "reply": reply.text,
        "session_id": reply.session_id,
        "tools": reply.tools_used,
    }


@app.post("/code/text")
async def code_text(
    text: str = Form(...),
    session_id: str | None = Form(default=None),
) -> dict[str, object]:
    """Text-in / JSON-out twin of /code/voice. Used for testing + the remote proxy."""
    state: AppState = app.state.gb
    result = await state.code.handle_transcript(text, active_session_id=session_id)
    return {
        "action": result.action,
        "transcript": result.transcript,
        "reply": result.reply_full,
        "spoken": result.spoken,
        "session_id": result.active_session_id,
        "tools": result.tools_used,
        "sessions": [s.to_dict() for s in result.sessions],
    }


@app.post("/code/voice")
async def code_voice(
    audio: UploadFile = File(...),
    session_id: str | None = Form(default=None),
    text_override: str | None = Form(default=None),
) -> StreamingResponse:
    state: AppState = app.state.gb
    t_start = time.perf_counter()

    if text_override and text_override.strip():
        transcript = text_override.strip()
        transcript_lang = "override"
        t_stt = 0.0
    else:
        audio_bytes = await audio.read()
        if not audio_bytes:
            raise HTTPException(400, "audio file is empty")
        t0 = time.perf_counter()
        stt = await anyio.to_thread.run_sync(
            state.transcriber.transcribe, audio_bytes, audio.filename or "audio.wav"
        )
        t_stt = time.perf_counter() - t0
        transcript = stt.text
        transcript_lang = stt.language
        logger.info("CODE STT %.2fs lang=%s: %r", t_stt, transcript_lang, transcript[:80])

    t0 = time.perf_counter()
    result = await state.code.handle_transcript(transcript, active_session_id=session_id)
    t_agent = time.perf_counter() - t0
    logger.info(
        "CODE action=%s session=%s agent=%.2fs reply=%r",
        result.action,
        result.active_session_id,
        t_agent,
        result.reply_full[:120],
    )

    async def stream_mp3() -> AsyncIterator[bytes]:
        gen = state.tts.synthesize(result.spoken)
        try:
            while True:
                chunk = await anyio.to_thread.run_sync(next, gen, None)
                if chunk is None:
                    break
                yield chunk
        finally:
            logger.info("CODE DONE total=%.2fs", time.perf_counter() - t_start)

    sessions_json = json.dumps(
        [{"id": s.id, "title": s.title} for s in result.sessions], ensure_ascii=False
    )
    headers = {
        "X-Code-Action": result.action,
        "X-Code-Transcript": quote(result.transcript, safe=""),
        "X-Code-Reply": quote(result.reply_full, safe=""),
        "X-Code-Spoken": quote(result.spoken, safe=""),
        "X-Code-Active": result.active_session_id or "",
        "X-Code-Sessions": quote(sessions_json, safe=""),
        "X-Code-Tools": quote(",".join(result.tools_used), safe=""),
        "X-Code-Lang": transcript_lang,
        "X-Code-Latency-Stt": f"{t_stt:.3f}",
        "X-Code-Latency-Agent": f"{t_agent:.3f}",
        "Cache-Control": "no-store",
    }
    return StreamingResponse(stream_mp3(), media_type="audio/mpeg", headers=headers)


@app.exception_handler(Exception)
async def unhandled_exception(_, exc: Exception) -> JSONResponse:
    logger.exception("Unhandled exception")
    return JSONResponse(status_code=500, content={"detail": str(exc)})
