"""豆包 ASR WebSocket 二进制协议.

火山引擎大模型语音识别（bigmodel_async）使用自定义二进制协议通信：
- 4 字节 header（协议版本、消息类型、序列化、压缩）
- 4 字节 payload 大小（big-endian uint32）
- payload 数据

协议参考：scripts/benchmark_azure_vs_doubao.py
"""

from __future__ import annotations

import gzip
import json
import struct

# ── Header 常量 ──────────────────────────────────────────────

# Protocol version (4 bits) = 0b0001, Header size (4 bits) = 0b0001 (4 bytes)
HEADER_BYTE0 = 0x11

# Message types (upper 4 bits of byte 1)
MSG_FULL_CLIENT_REQUEST = 0x10  # 0b0001 << 4
MSG_AUDIO_ONLY = 0x20           # 0b0010 << 4
MSG_SERVER_RESPONSE = 0x90      # 0b1001 << 4
MSG_SERVER_ERROR = 0xF0         # 0b1111 << 4

# Message type flags (lower 4 bits of byte 1)
FLAG_NONE = 0x00        # 0b0000
FLAG_SEQ = 0x01         # 0b0001 (sequence number present)
FLAG_LAST_PACK = 0x02   # 0b0010
FLAG_FINAL = 0x03       # 0b0011 (negative seq = last response)

# Serialization (upper 4 bits of byte 2)
SERIAL_NONE = 0x00
SERIAL_JSON = 0x10  # 0b0001 << 4

# Compression (lower 4 bits of byte 2)
COMPRESS_NONE = 0x00
COMPRESS_GZIP = 0x01

# Reserved byte
RESERVED = 0x00


# ── 消息构建 ─────────────────────────────────────────────────


def build_header(
    msg_type: int, msg_flags: int, serialization: int, compression: int
) -> bytes:
    """构建 4 字节协议 header."""
    return bytes([
        HEADER_BYTE0,
        msg_type | msg_flags,
        serialization | compression,
        RESERVED,
    ])


def build_full_client_request(payload_json: dict) -> bytes:
    """构建 Full Client Request 消息（JSON + Gzip）."""
    header = build_header(MSG_FULL_CLIENT_REQUEST, FLAG_NONE, SERIAL_JSON, COMPRESS_GZIP)
    json_bytes = json.dumps(payload_json).encode("utf-8")
    compressed = gzip.compress(json_bytes)
    size = struct.pack(">I", len(compressed))
    return header + size + compressed


def build_audio_packet(
    audio_chunk: bytes, *, is_last: bool = False, compress: bool = False
) -> bytes:
    """构建 Audio Only 消息.

    Args:
        audio_chunk: 原始 PCM16 音频数据.
        is_last: 是否为最后一个音频包.
        compress: 是否 gzip 压缩（bigmodel_async 模式需要）.
    """
    flags = FLAG_LAST_PACK if is_last else FLAG_NONE
    compression = COMPRESS_GZIP if compress else COMPRESS_NONE
    header = build_header(MSG_AUDIO_ONLY, flags, SERIAL_NONE, compression)
    payload = gzip.compress(audio_chunk) if compress else audio_chunk
    size = struct.pack(">I", len(payload))
    return header + size + payload


# ── 消息解析 ─────────────────────────────────────────────────


def parse_server_response(data: bytes) -> dict:
    """解析服务端响应消息.

    Returns:
        dict with keys:
        - error (bool): 是否为错误响应
        - data (dict): 解析后的 JSON payload
        - is_final (bool): 是否为最后一条响应
        - ack (bool): 是否为 ACK 消息（非数据响应）
    """
    if len(data) < 4:
        raise ValueError(f"Response too short: {len(data)} bytes")

    msg_type = data[1] & 0xF0
    msg_flags = data[1] & 0x0F
    serialization = data[2] & 0xF0
    compression = data[2] & 0x0F

    # Header size in 4-byte units
    header_size = (data[0] & 0x0F) * 4

    if msg_type == MSG_SERVER_ERROR:
        if len(data) > header_size + 4:
            payload_size = struct.unpack(">I", data[header_size:header_size + 4])[0]
            payload_start = header_size + 4
            if payload_start + payload_size > len(data):
                raise ValueError(
                    f"Truncated error payload: need {payload_size}, "
                    f"have {len(data) - payload_start}"
                )
            payload_bytes = data[payload_start:payload_start + payload_size]
            if compression == COMPRESS_GZIP:
                payload_bytes = gzip.decompress(payload_bytes)
            error_info = json.loads(payload_bytes.decode("utf-8"))
            return {"error": True, "data": error_info, "is_final": True, "ack": False}
        return {"error": True, "data": {"message": "Unknown error"}, "is_final": True, "ack": False}

    if msg_type != MSG_SERVER_RESPONSE:
        # ACK 或其他非响应消息
        return {"error": False, "data": {}, "is_final": False, "ack": True}

    is_final = msg_flags in (FLAG_LAST_PACK, FLAG_FINAL)
    pos = header_size

    # 跳过 sequence number（FLAG_SEQ 或 FLAG_FINAL 时存在）
    if msg_flags in (FLAG_SEQ, FLAG_FINAL):
        pos += 4

    if pos + 4 > len(data):
        return {"error": False, "data": {}, "is_final": is_final, "ack": True}

    # 解析 payload
    payload_size = struct.unpack(">I", data[pos:pos + 4])[0]
    pos += 4

    if pos + payload_size > len(data):
        raise ValueError(
            f"Truncated payload: need {payload_size}, have {len(data) - pos}"
        )

    payload_bytes = data[pos:pos + payload_size]

    if compression == COMPRESS_GZIP:
        payload_bytes = gzip.decompress(payload_bytes)

    if serialization == SERIAL_JSON:
        payload = json.loads(payload_bytes.decode("utf-8"))
    else:
        payload = {"raw": payload_bytes.hex()}

    return {"error": False, "data": payload, "is_final": is_final, "ack": False}


# ── 音频格式转换 ─────────────────────────────────────────────


def float32_bytes_to_pcm16_bytes(float32_data: bytes) -> bytes:
    """将 Float32 PCM bytes 转为 int16 PCM bytes.

    客户端（Swift AudioEngine）发送 Float32 little-endian PCM，
    豆包 ASR 需要 int16 little-endian PCM。

    Args:
        float32_data: Float32 little-endian PCM bytes.

    Returns:
        int16 little-endian PCM bytes.
    """
    n_samples = len(float32_data) // 4
    if n_samples == 0:
        return b""
    float_samples = struct.unpack(f"<{n_samples}f", float32_data)
    int16_samples = [int(max(-32768, min(32767, s * 32768))) for s in float_samples]
    return struct.pack(f"<{n_samples}h", *int16_samples)
