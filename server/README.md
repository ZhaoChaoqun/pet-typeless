# PetTypeless Relay Server

WebSocket relay server that proxies client audio to 豆包 bigmodel_async ASR for real-time speech recognition.

## Quick Start

```bash
# Install dependencies
cd server
uv sync

# Configure environment
cp .env.example .env
# Edit .env with your 豆包 credentials

# Run the server
uv run pet-typeless-server
```

## WebSocket Protocol

Connect to `ws://<host>:<port>/ws?token=<API_TOKEN>`.

### Client → Server

| Frame Type | Content | Description |
|-----------|---------|-------------|
| Binary | Float32 PCM 16kHz mono audio bytes | Raw audio data |
| Text | `{"type":"start_session"}` | Begin ASR session |
| Text | `{"type":"end_session"}` | End ASR session |

### Server → Client

| Message Type | Example | Description |
|-------------|---------|-------------|
| `partial` | `{"type":"partial","text":"帮我写一个"}` | Interim recognition result |
| `final` | `{"type":"final","text":"帮我写一个Python脚本。"}` | Sentence-final recognition |
| `session_started` | `{"type":"session_started"}` | ASR session ready |
| `session_ended` | `{"type":"session_ended"}` | ASR session stopped |
| `error` | `{"type":"error","message":"..."}` | Error |

## Audio Format

The client sends Float32 PCM audio, which the server converts to PCM16 for 豆包 ASR:
- **Sample rate:** 16,000 Hz
- **Bit depth:** Float32 (client) → 16-bit signed integer (server converts)
- **Channels:** 1 (mono)

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DOUBAO_APP_KEY` | Yes | — | 豆包 ASR app key |
| `DOUBAO_ACCESS_KEY` | Yes | — | 豆包 ASR access key |
| `DOUBAO_RESOURCE_ID` | No | `volc.bigasr.sauc.duration` | 豆包 resource ID |
| `API_TOKEN` | Yes | — | Client authentication token |
| `HOST` | No | `0.0.0.0` | Server bind host |
| `PORT` | No | `8000` | Server bind port |
