"""Azure Speech SDK integration — continuous recognition via PushAudioInputStream.

Each WebSocket session creates an independent ``ASRSession`` that maintains
its own ``SpeechRecognizer`` and ``PushAudioInputStream``.  Audio bytes are
pushed in via ``push_audio``, and recognition events are forwarded to the
WebSocket through an asyncio callback.

Audio format expected from the client:
  - PCM 16-bit signed integer (little-endian)
  - 16 kHz sample rate
  - Mono (single channel)
  - Sent as raw bytes in WebSocket binary frames

Lifecycle:
  1. ``start()`` — creates recognizer, wires callbacks, starts continuous recognition.
  2. ``push_audio(data)`` — writes raw PCM bytes into the push stream.
  3. ``stop()`` — stops recognition, closes the push stream, releases resources.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Callable, Awaitable

import azure.cognitiveservices.speech as speechsdk

logger = logging.getLogger(__name__)

# Type alias for the async callback that sends results back to the WebSocket.
# signature: (event_type: str, text: str) -> Awaitable[None]
ResultCallback = Callable[[str, str], Awaitable[None]]


class ASRSession:
    """Manages a single Azure Speech continuous-recognition session.

    Not thread-safe — callers must ensure that ``push_audio`` and ``stop``
    are not called concurrently from different tasks.
    """

    def __init__(
        self,
        speech_key: str,
        speech_region: str,
        language: str = "zh-CN",
    ) -> None:
        self._speech_key = speech_key
        self._speech_region = speech_region
        self._language = language

        self._push_stream: speechsdk.audio.PushAudioInputStream | None = None
        self._recognizer: speechsdk.SpeechRecognizer | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._on_result: ResultCallback | None = None
        self._started = False

    # ── Public API ────────────────────────────────────────────────

    async def start(self, on_result: ResultCallback) -> None:
        """Create the recognizer and begin continuous recognition.

        Args:
            on_result: Async callback ``(event_type, text)`` invoked for each
                recognition event.  ``event_type`` is ``"partial"`` (recognizing)
                or ``"final"`` (recognized).
        """
        if self._started:
            logger.warning("ASRSession.start() called but session already started")
            return

        self._on_result = on_result
        self._loop = asyncio.get_running_loop()

        # Audio stream format: 16-bit PCM, 16 kHz, mono
        audio_format = speechsdk.audio.AudioStreamFormat(
            samples_per_second=16000,
            bits_per_sample=16,
            channels=1,
        )
        self._push_stream = speechsdk.audio.PushAudioInputStream(audio_format)
        audio_config = speechsdk.audio.AudioConfig(stream=self._push_stream)

        speech_config = speechsdk.SpeechConfig(
            subscription=self._speech_key,
            region=self._speech_region,
        )
        speech_config.speech_recognition_language = self._language
        # Enable partial results
        speech_config.set_property(
            speechsdk.PropertyId.SpeechServiceResponse_RequestSentimentAnalysis,
            "false",
        )

        self._recognizer = speechsdk.SpeechRecognizer(
            speech_config=speech_config,
            audio_config=audio_config,
        )

        # Wire up callbacks.  Azure SDK fires these from a C++ background thread,
        # so we need to schedule the async callback onto the event loop.
        self._recognizer.recognizing.connect(self._on_recognizing)
        self._recognizer.recognized.connect(self._on_recognized)
        self._recognizer.canceled.connect(self._on_canceled)
        self._recognizer.session_stopped.connect(self._on_session_stopped)

        await asyncio.to_thread(
            self._recognizer.start_continuous_recognition_async().get
        )
        self._started = True
        logger.info("ASR session started (language=%s)", self._language)

    def push_audio(self, data: bytes) -> None:
        """Push raw PCM audio bytes into the recognition stream.

        Must only be called after ``start()`` and before ``stop()``.
        """
        if self._push_stream is None:
            logger.warning("push_audio called but push_stream is None")
            return
        self._push_stream.write(data)

    async def stop(self) -> None:
        """Stop recognition and release all resources."""
        if not self._started:
            return

        # Close the audio stream — this tells the recognizer no more data is coming.
        if self._push_stream is not None:
            self._push_stream.close()
            self._push_stream = None

        # Stop continuous recognition.
        if self._recognizer is not None:
            try:
                await asyncio.to_thread(
                    self._recognizer.stop_continuous_recognition_async().get
                )
            except Exception as exc:
                logger.warning("Error stopping recognizer: %s", exc)
            self._recognizer = None

        self._started = False
        self._on_result = None
        logger.info("ASR session stopped")

    @property
    def is_active(self) -> bool:
        return self._started

    # ── SDK Event Handlers (called from C++ background thread) ───

    def _schedule_callback(self, event_type: str, text: str) -> None:
        """Schedule the async callback on the event loop from a background thread."""
        if self._loop is None or self._on_result is None:
            return
        self._loop.call_soon_threadsafe(
            asyncio.ensure_future,
            self._on_result(event_type, text),
        )

    def _on_recognizing(self, evt: speechsdk.SpeechRecognitionEventArgs) -> None:
        text = evt.result.text
        if text:
            self._schedule_callback("partial", text)

    def _on_recognized(self, evt: speechsdk.SpeechRecognitionEventArgs) -> None:
        if evt.result.reason == speechsdk.ResultReason.RecognizedSpeech:
            text = evt.result.text
            if text:
                self._schedule_callback("final", text)
        elif evt.result.reason == speechsdk.ResultReason.NoMatch:
            logger.debug("No speech recognized in segment")

    def _on_canceled(self, evt: speechsdk.SpeechRecognitionCanceledEventArgs) -> None:
        reason = evt.cancellation_details.reason
        if reason == speechsdk.CancellationReason.Error:
            logger.error(
                "ASR canceled (error): code=%s, details=%s",
                evt.cancellation_details.error_code,
                evt.cancellation_details.error_details,
            )
            self._schedule_callback(
                "error",
                f"ASR error: {evt.cancellation_details.error_details}",
            )
        else:
            logger.info("ASR canceled: reason=%s", reason)

    def _on_session_stopped(self, evt: speechsdk.SessionEventArgs) -> None:
        logger.info("ASR session stopped (session_id=%s)", evt.session_id)
