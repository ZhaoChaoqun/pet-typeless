"""FastAPI application entry point — WebSocket relay for ASR and rewrite.

Protocol:
  - Client connects via ``ws://<host>:<port>/ws?token=<API_TOKEN>``
  - Client sends **binary frames** containing PCM 16-bit 16kHz mono audio
  - Client sends **text frames** containing JSON control messages:
      ``{"type":"start_session"}``     — create Azure ASR session
      ``{"type":"end_session"}``       — stop ASR, get final result
      ``{"type":"rewrite","text":"…"}`` — request LLM rewrite
  - Server sends **text frames** containing JSON responses:
      ``{"type":"partial","text":"…"}``        — interim recognition
      ``{"type":"final","text":"…"}``          — sentence-final recognition
      ``{"type":"rewrite_result","text":"…"}`` — rewrite result
      ``{"type":"error","message":"…"}``       — error
"""

from __future__ import annotations

import asyncio
import hmac
import json
import logging
import sys
from contextlib import asynccontextmanager
from typing import AsyncIterator

import uvicorn
from fastapi import FastAPI, Query, WebSocket, WebSocketDisconnect

from .asr_handler import ASRSession
from .config import Settings, load_settings
from .rewrite_handler import RewriteHandler

logger = logging.getLogger(__name__)

# ── Application Factory ──────────────────────────────────────────


def create_app(settings: Settings | None = None) -> FastAPI:
    """Build and return the FastAPI application.

    If *settings* is ``None``, they are loaded from the environment.
    """
    if settings is None:
        settings = load_settings()

    # Create a shared RewriteHandler (holds an AsyncAzureOpenAI client)
    rewrite = RewriteHandler(
        api_key=settings.azure_openai_api_key,
        endpoint=settings.azure_openai_endpoint,
        deployment=settings.azure_openai_deployment,
        api_version=settings.azure_openai_api_version,
        timeout=settings.rewrite_timeout,
    )

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        # Startup: nothing extra needed
        yield
        # Shutdown: release the OpenAI HTTP client
        await rewrite.close()

    app = FastAPI(
        title="PetTypeless Relay Server",
        version="0.1.0",
        description="Proxies client audio to Azure Speech SDK and rewrites via Azure OpenAI.",
        lifespan=lifespan,
    )

    # Stash settings on the app for access in routes
    app.state.settings = settings  # type: ignore[attr-defined]
    app.state.rewrite = rewrite  # type: ignore[attr-defined]

    # ── Health check ──────────────────────────────────────────

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    # ── WebSocket endpoint ────────────────────────────────────

    @app.websocket("/ws")
    async def ws_relay(
        websocket: WebSocket,
        token: str = Query(default=""),
    ) -> None:
        # Authenticate — constant-time comparison to prevent timing attacks
        if not token or not hmac.compare_digest(token, settings.api_token):
            await websocket.close(code=1008, reason="Invalid or missing API token")
            return

        await websocket.accept()
        logger.info("WebSocket connected (client=%s)", websocket.client)

        asr_session: ASRSession | None = None

        async def _send_json(data: dict) -> None:
            """Send a JSON text frame, swallowing errors on closed sockets."""
            try:
                await websocket.send_json(data)
            except Exception:
                pass

        async def _on_asr_result(event_type: str, text: str) -> None:
            """Callback from ASRSession — forward to WebSocket."""
            await _send_json({"type": event_type, "text": text})

        async def _handle_rewrite(text: str) -> None:
            """Run rewrite in background and send result when done."""
            result = await rewrite.rewrite(text)
            await _send_json({"type": "rewrite_result", "text": result})

        try:
            while True:
                message = await websocket.receive()

                if message["type"] == "websocket.disconnect":
                    break

                # Binary frame — audio data
                if "bytes" in message and message["bytes"]:
                    if asr_session is not None and asr_session.is_active:
                        asr_session.push_audio(message["bytes"])
                    continue

                # Text frame — JSON control message
                if "text" in message and message["text"]:
                    try:
                        payload = json.loads(message["text"])
                    except json.JSONDecodeError:
                        await _send_json({
                            "type": "error",
                            "message": "Invalid JSON",
                        })
                        continue

                    msg_type = payload.get("type", "")

                    if msg_type == "start_session":
                        # Create a new ASR session
                        if asr_session is not None and asr_session.is_active:
                            await asr_session.stop()

                        language = payload.get("language", "zh-CN")
                        asr_session = ASRSession(
                            speech_key=settings.azure_speech_key,
                            speech_region=settings.azure_speech_region,
                            language=language,
                        )
                        await asr_session.start(on_result=_on_asr_result)
                        await _send_json({
                            "type": "session_started",
                            "language": language,
                        })

                    elif msg_type == "end_session":
                        # Stop ASR session
                        if asr_session is not None:
                            await asr_session.stop()
                            asr_session = None
                        await _send_json({"type": "session_ended"})

                    elif msg_type == "rewrite":
                        # Rewrite request — run asynchronously to avoid
                        # blocking the WS receive loop
                        text = payload.get("text", "")
                        if text:
                            asyncio.create_task(_handle_rewrite(text))
                        else:
                            await _send_json({
                                "type": "error",
                                "message": "rewrite: empty text",
                            })

                    else:
                        await _send_json({
                            "type": "error",
                            "message": f"Unknown message type: {msg_type}",
                        })

        except WebSocketDisconnect:
            logger.info("WebSocket disconnected (client=%s)", websocket.client)
        except Exception as exc:
            logger.exception("WebSocket error: %s", exc)
        finally:
            # Always clean up the ASR session
            if asr_session is not None:
                await asr_session.stop()
            logger.info("WebSocket cleanup complete (client=%s)", websocket.client)

    return app


# ── CLI entry point ───────────────────────────────────────────


def cli_main() -> None:
    """Start the server from the command line."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-8s [%(name)s] %(message)s",
    )

    try:
        settings = load_settings()
    except EnvironmentError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        sys.exit(1)

    print(
        f"🐱 PetTypeless Relay Server starting on {settings.host}:{settings.port}"
    )

    app = create_app(settings)
    uvicorn.run(
        app,
        host=settings.host,
        port=settings.port,
        log_level="info",
    )
