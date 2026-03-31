"""豆包大模型 ASR（bigmodel_async）流式会话处理.

每个 WebSocket 客户端连接对应一个 ``DoubaoASRSession``，管理与豆包
ASR 服务器之间的完整双向流式通信生命周期。

音频格式（客户端发送）：
  - Float32 little-endian PCM
  - 16 kHz 采样率
  - 单声道
  - 以 WebSocket binary frame 发送

会话内部将 Float32 → PCM16 转换后转发给豆包 ASR。

生命周期：
  1. ``start(on_result)`` — 连接豆包、发送初始化请求、启动 sender/receiver 任务
  2. ``push_audio(data)`` — 将客户端 Float32 音频放入发送队列
  3. ``stop()`` — 发送结束标志、等待最终结果、清理资源
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
    parse_server_response,
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

# 等待豆包最终结果的超时（秒）
RECV_TIMEOUT = 30.0

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

        self._ws: websockets.WebSocketClientProtocol | None = None
        self._on_result: ResultCallback | None = None
        self._started = False

        # 音频发送队列，None 作为 sentinel 表示停止
        self._audio_queue: asyncio.Queue[bytes | None] = asyncio.Queue()
        self._sender_task: asyncio.Task | None = None
        self._receiver_task: asyncio.Task | None = None

        # 已确定的分句文本
        self._definite_texts: list[str] = []

        # 性能计时
        self._start_time: float = 0
        self._first_audio_time: float = 0
        self._first_partial_time: float = 0
        self._audio_bytes_received: int = 0
        self._audio_packets_sent: int = 0

    # ── Public API ────────────────────────────────────────────

    async def start(self, on_result: ResultCallback) -> None:
        """连接豆包 ASR 并开始流式识别."""
        if self._started:
            logger.warning("DoubaoASRSession.start() called but already started")
            return

        self._on_result = on_result
        self._definite_texts = []
        self._start_time = time.monotonic()
        self._first_audio_time = 0
        self._first_partial_time = 0
        self._audio_bytes_received = 0
        self._audio_packets_sent = 0

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
        await self._ws.send(full_request)

        # 启动 sender 和 receiver 协程
        self._sender_task = asyncio.create_task(self._sender_loop())
        self._receiver_task = asyncio.create_task(self._receiver_loop())

        self._started = True
        logger.info("Doubao ASR session started (connect_id=%s)", connect_id)

    def push_audio(self, data: bytes) -> None:
        """将客户端 Float32 PCM 音频推入发送队列."""
        if not self._started:
            return

        if not self._first_audio_time:
            self._first_audio_time = time.monotonic()

        self._audio_bytes_received += len(data)

        # Float32 → PCM16 转换
        pcm16_data = float32_bytes_to_pcm16_bytes(data)
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

        # 并行等待 sender 和 receiver 完成
        tasks = []
        if self._sender_task is not None:
            tasks.append(self._sender_task)
        if self._receiver_task is not None:
            tasks.append(self._receiver_task)

        if tasks:
            done, pending = await asyncio.wait(tasks, timeout=STOP_TIMEOUT)
            for t in pending:
                logger.warning("Task %s did not finish in %.0fs, cancelling",
                               t.get_name(), STOP_TIMEOUT)
                t.cancel()

        self._sender_task = None
        self._receiver_task = None

        # 关闭 WebSocket
        if self._ws is not None:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None

        stop_ms = (time.monotonic() - stop_start) * 1000
        total_ms = (time.monotonic() - self._start_time) * 1000
        logger.info("Doubao ASR session stopped (stop=%.0fms, total=%.0fms)", stop_ms, total_ms)
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
                        self._audio_queue.get(), timeout=wait_time or SEND_INTERVAL
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

    async def _receiver_loop(self) -> None:
        """持续接收豆包响应，解析并回调 partial/final."""
        response_count = 0
        try:
            for _ in range(2000):  # 安全上限
                if self._ws is None:
                    break

                try:
                    resp_data = await asyncio.wait_for(
                        self._ws.recv(), timeout=RECV_TIMEOUT
                    )
                except asyncio.TimeoutError:
                    logger.warning("Receiver timeout (%.0fs) after %d responses",
                                   RECV_TIMEOUT, response_count)
                    break

                response_count += 1
                resp = parse_server_response(resp_data)

                if resp.get("error"):
                    error_data = resp.get("data", {})
                    error_msg = error_data.get("message", str(error_data))
                    logger.error("Doubao ASR error: %s", error_msg)
                    await self._fire_callback("error", f"ASR error: {error_msg}")
                    break

                # ACK 消息，跳过
                if resp.get("ack"):
                    continue

                data = resp.get("data", {})
                if "result" in data:
                    await self._handle_result(data["result"])

                if resp.get("is_final"):
                    # 发送最终的 final 事件
                    final_text = "".join(self._definite_texts)
                    elapsed = (time.monotonic() - self._start_time) * 1000
                    logger.info("Receiver: is_final after %d responses (%.0fms), text=%s",
                                response_count, elapsed,
                                repr(final_text[:80]) if final_text else "(empty)")
                    if final_text:
                        await self._fire_callback("final", final_text)
                    break

        except websockets.exceptions.ConnectionClosed:
            logger.info("Doubao WebSocket connection closed (%d responses)", response_count)
        except Exception as exc:
            logger.error("Receiver loop error: %s", exc)
            await self._fire_callback("error", f"Receiver error: {exc}")

    async def _handle_result(self, result: dict) -> None:
        """处理豆包返回的 result 对象，提取 definite/pending 分句."""
        utterances = result.get("utterances", [])

        if utterances:
            new_definite = False
            pending_text = ""

            for utt in utterances:
                if utt.get("definite"):
                    text = utt.get("text", "")
                    if text and (
                        not self._definite_texts
                        or self._definite_texts[-1] != text
                    ):
                        self._definite_texts.append(text)
                        new_definite = True
                else:
                    pending_text = utt.get("text", "")

            if new_definite:
                final_text = "".join(self._definite_texts)
                if not self._first_partial_time:
                    self._first_partial_time = time.monotonic()
                    latency = (self._first_partial_time - self._first_audio_time) * 1000
                    logger.info("First definite result in %.0fms: %s",
                                latency, repr(final_text[:60]))
                await self._fire_callback("final", final_text)

            if pending_text:
                partial_text = "".join(self._definite_texts) + pending_text
                if not self._first_partial_time:
                    self._first_partial_time = time.monotonic()
                    latency = (self._first_partial_time - self._first_audio_time) * 1000
                    logger.info("First partial result in %.0fms: %s",
                                latency, repr(partial_text[:60]))
                await self._fire_callback("partial", partial_text)
        else:
            text = result.get("text", "")
            if text:
                if not self._first_partial_time:
                    self._first_partial_time = time.monotonic()
                    latency = (self._first_partial_time - self._first_audio_time) * 1000
                    logger.info("First partial result in %.0fms: %s",
                                latency, repr(text[:60]))
                await self._fire_callback("partial", text)

    async def _fire_callback(self, event_type: str, text: str) -> None:
        """安全地调用回调函数."""
        if self._on_result is not None:
            try:
                await self._on_result(event_type, text)
            except Exception as exc:
                logger.warning("Callback error (%s): %s", event_type, exc)
