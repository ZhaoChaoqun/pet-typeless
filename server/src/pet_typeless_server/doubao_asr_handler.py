"""豆包大模型 ASR（bigmodel_async）流式会话处理.

每个 WebSocket 客户端连接对应一个 ``DoubaoASRSession``，管理与豆包
ASR 服务器之间的完整双向流式通信生命周期。

生命周期：
  1. ``start(on_result)`` — 连接豆包、发送初始化请求、启动 sender 任务
  2. ``push_audio(data)`` — 将客户端 Float32 音频放入发送队列
  3. ``stop()`` — 发送结束标志、等待任务完成、清理资源

本 PR 只包含 session 骨架和 sender（音频发送）逻辑。
receiver（响应接收 + 回调）将在下个 PR 中添加。
"""

from __future__ import annotations

import asyncio
import logging
import time
import uuid
from typing import Awaitable, Callable

import websockets

from .doubao_protocol import (
    build_audio_packet,
    build_full_client_request,
    float32_bytes_to_pcm16_bytes,
)

logger = logging.getLogger(__name__)

# 回调签名: (event_type: str, text: str) -> Awaitable[None]
#   event_type: "partial" | "final" | "error"
ResultCallback = Callable[[str, str], Awaitable[None]]

# bigmodel_async 端点
DOUBAO_ENDPOINT = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"

# 每个音频包的大小：200ms @ 16kHz 16bit mono = 3200 bytes PCM16
CHUNK_SIZE = 3200

# 发包间隔（秒），bigmodel_async 需要模拟实时节拍
SEND_INTERVAL = 0.2

# stop() 等待 sender/receiver 完成的超时（秒）
STOP_TIMEOUT = 15.0


class DoubaoASRSession:
    """管理一个与豆包 bigmodel_async ASR 的流式会话.

    不是线程安全的 —— 调用者需保证 ``push_audio`` 和 ``stop``
    不会从不同的 asyncio tasks 并发调用。
    """

    def __init__(
        self,
        app_key: str,
        access_key: str,
        resource_id: str = "volc.bigasr.sauc.duration",
    ) -> None:
        self._app_key = app_key
        self._access_key = access_key
        self._resource_id = resource_id

        self._ws: websockets.ClientConnection | None = None
        self._on_result: ResultCallback | None = None
        self._started = False

        # 音频发送队列，None 作为 sentinel 表示停止
        self._audio_queue: asyncio.Queue[bytes | None] = asyncio.Queue()
        self._sender_task: asyncio.Task | None = None

        # 性能计时
        self._start_time: float = 0
        self._audio_bytes_received: int = 0
        self._audio_packets_sent: int = 0

    # ── Public API ────────────────────────────────────────────

    async def start(self, on_result: ResultCallback) -> None:
        """连接豆包 ASR 并开始流式识别."""
        if self._started:
            logger.warning("DoubaoASRSession.start() called but already started")
            return

        self._on_result = on_result
        self._start_time = time.monotonic()
        self._audio_bytes_received = 0
        self._audio_packets_sent = 0
        self._audio_queue = asyncio.Queue()  # 重建队列，防止残留数据

        connect_id = str(uuid.uuid4())

        headers = {
            "X-Api-App-Key": self._app_key,
            "X-Api-Access-Key": self._access_key,
            "X-Api-Resource-Id": self._resource_id,
            "X-Api-Connect-Id": connect_id,
        }

        t0 = time.monotonic()
        try:
            self._ws = await websockets.connect(
                DOUBAO_ENDPOINT,
                additional_headers=headers,
                max_size=10 * 1024 * 1024,  # 10MB
                close_timeout=5,
            )
        except Exception as exc:
            logger.error("Failed to connect to Doubao ASR (%.0fms): %s",
                         (time.monotonic() - t0) * 1000, exc)
            await self._fire_callback("error", f"Connection failed: {exc}")
            return

        connect_ms = (time.monotonic() - t0) * 1000
        logger.info("Doubao WS connected in %.0fms", connect_ms)

        # 发送 Full Client Request
        request_payload = self._build_request_payload()
        full_request = build_full_client_request(request_payload)
        try:
            await self._ws.send(full_request)
        except Exception as exc:
            logger.error("Failed to send Full Client Request: %s", exc)
            await self._ws.close()
            self._ws = None
            await self._fire_callback("error", f"Init request failed: {exc}")
            return

        # 启动 sender 协程
        self._sender_task = asyncio.create_task(self._sender_loop())

        self._started = True
        logger.info("Doubao ASR session started (connect_id=%s)", connect_id)

    def push_audio(self, data: bytes) -> None:
        """将客户端 Float32 PCM 音频推入发送队列."""
        if not self._started:
            return

        self._audio_bytes_received += len(data)

        # Float32 → PCM16 转换
        try:
            pcm16_data = float32_bytes_to_pcm16_bytes(data)
        except ValueError as exc:
            logger.warning("Dropping malformed audio frame (%d bytes): %s",
                           len(data), exc)
            return
        if pcm16_data:
            self._audio_queue.put_nowait(pcm16_data)

    async def stop(self) -> None:
        """停止识别并释放所有资源."""
        if not self._started:
            return

        self._started = False
        stop_start = time.monotonic()
        logger.info("Stopping ASR session (audio_received=%.1fKB, packets_sent=%d)",
                     self._audio_bytes_received / 1024, self._audio_packets_sent)

        # 发送停止信号给 sender
        self._audio_queue.put_nowait(None)

        # 等待 sender 完成
        tasks: list[asyncio.Task] = []
        if self._sender_task is not None:
            tasks.append(self._sender_task)

        if tasks:
            done, pending = await asyncio.wait(tasks, timeout=STOP_TIMEOUT)
            for t in pending:
                logger.warning("Task %s did not finish in %.0fs, cancelling",
                               t.get_name(), STOP_TIMEOUT)
                t.cancel()
                try:
                    await t
                except asyncio.CancelledError:
                    pass

        self._sender_task = None

        # 关闭 WebSocket
        if self._ws is not None:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None

        stop_ms = (time.monotonic() - stop_start) * 1000
        total_ms = (time.monotonic() - self._start_time) * 1000
        logger.info("Doubao ASR session stopped (stop=%.0fms, total=%.0fms)",
                     stop_ms, total_ms)
        self._on_result = None

    @property
    def is_active(self) -> bool:
        return self._started

    # ── Internal ──────────────────────────────────────────────

    def _build_request_payload(self) -> dict:
        """构建 bigmodel_async 初始化 JSON payload."""
        return {
            "user": {"uid": "pet_typeless"},
            "audio": {
                "format": "pcm",
                "rate": 16000,
                "bits": 16,
                "channel": 1,
            },
            "request": {
                "model_name": "bigmodel",
                "enable_itn": True,
                "enable_punc": True,
                "result_type": "single",
                "show_utterances": True,
                "enable_nonstream": True,
                "end_window_size": 800,
            },
        }

    async def _sender_loop(self) -> None:
        """从 audio_queue 取数据，按 200ms 节拍发送到豆包."""
        buffer = bytearray()
        last_send_time = time.monotonic()

        try:
            while True:
                # 计算距离上次发送还需等多久
                elapsed = time.monotonic() - last_send_time
                wait_time = max(0, SEND_INTERVAL - elapsed)

                try:
                    data = await asyncio.wait_for(
                        self._audio_queue.get(),
                        timeout=wait_time if wait_time > 0 else 0.001,
                    )
                except asyncio.TimeoutError:
                    # 超时 → 发送当前 buffer（如果有）
                    if buffer and self._ws is not None:
                        packet = build_audio_packet(
                            bytes(buffer), is_last=False, compress=True
                        )
                        await self._ws.send(packet)
                        self._audio_packets_sent += 1
                        buffer.clear()
                        last_send_time = time.monotonic()
                    continue

                if data is None:
                    # Sentinel: 发送剩余 buffer + last_pack
                    if self._ws is not None:
                        if buffer:
                            packet = build_audio_packet(
                                bytes(buffer), is_last=True, compress=True
                            )
                        else:
                            packet = build_audio_packet(
                                b"", is_last=True, compress=True
                            )
                        await self._ws.send(packet)
                        self._audio_packets_sent += 1
                        logger.info("Sender: last_pack sent (total %d packets)",
                                    self._audio_packets_sent)
                    break

                buffer.extend(data)

                # 当 buffer 足够大时，按 CHUNK_SIZE 切片发送
                while len(buffer) >= CHUNK_SIZE and self._ws is not None:
                    chunk = bytes(buffer[:CHUNK_SIZE])
                    buffer = buffer[CHUNK_SIZE:]
                    packet = build_audio_packet(chunk, is_last=False, compress=True)
                    await self._ws.send(packet)
                    self._audio_packets_sent += 1
                    last_send_time = time.monotonic()

                    # 如果还有更多 chunk 要发，按节拍等
                    if len(buffer) >= CHUNK_SIZE:
                        await asyncio.sleep(SEND_INTERVAL)

        except Exception as exc:
            logger.error("Sender loop error: %s", exc)
            await self._fire_callback("error", f"Sender error: {exc}")

    async def _fire_callback(self, event_type: str, text: str) -> None:
        """安全地调用回调函数."""
        if self._on_result is not None:
            try:
                await self._on_result(event_type, text)
            except Exception as exc:
                logger.warning("Callback error (%s): %s", event_type, exc)
