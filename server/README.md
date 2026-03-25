# PetTypeless Relay Server

WebSocket relay server that proxies client audio to Azure Speech SDK for real-time ASR, and rewrites transcriptions via Azure OpenAI GPT.

## Quick Start

```bash
# Install dependencies
cd server
uv sync

# Configure environment
cp .env.example .env
# Edit .env with your Azure credentials

# Run the server
uv run pet-typeless-server
```

## WebSocket Protocol

Connect to `ws://<host>:<port>/ws?token=<API_TOKEN>`.

### Client → Server

| Frame Type | Content | Description |
|-----------|---------|-------------|
| Binary | PCM 16-bit 16kHz mono audio bytes | Raw audio data |
| Text | `{"type":"start_session"}` | Begin ASR session |
| Text | `{"type":"end_session"}` | End ASR session |
| Text | `{"type":"rewrite","text":"..."}` | Request LLM rewrite |

### Server → Client

| Message Type | Example | Description |
|-------------|---------|-------------|
| `partial` | `{"type":"partial","text":"帮我写一个"}` | Interim recognition result |
| `final` | `{"type":"final","text":"帮我写一个Python脚本。"}` | Sentence-final recognition |
| `rewrite_result` | `{"type":"rewrite_result","text":"..."}` | Rewrite result |
| `session_started` | `{"type":"session_started","language":"zh-CN"}` | ASR session ready |
| `session_ended` | `{"type":"session_ended"}` | ASR session stopped |
| `error` | `{"type":"error","message":"..."}` | Error |

## Audio Format

The server expects raw PCM audio:
- **Sample rate:** 16,000 Hz
- **Bit depth:** 16-bit signed integer (little-endian)
- **Channels:** 1 (mono)
- **Frame size:** ~3,200 bytes recommended (100ms of audio)

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AZURE_SPEECH_KEY` | Yes | — | Azure Speech Service subscription key |
| `AZURE_SPEECH_REGION` | Yes | — | Azure region (e.g., `eastasia`) |
| `AZURE_OPENAI_API_KEY` | Yes | — | Azure OpenAI API key |
| `AZURE_OPENAI_ENDPOINT` | Yes | — | Azure OpenAI endpoint URL |
| `AZURE_OPENAI_DEPLOYMENT` | No | `gpt-5.4-mini` | Model deployment name |
| `AZURE_OPENAI_API_VERSION` | No | `2024-10-21` | API version |
| `API_TOKEN` | Yes | — | Client authentication token |
| `HOST` | No | `0.0.0.0` | Server bind host |
| `PORT` | No | `8000` | Server bind port |
| `REWRITE_TIMEOUT` | No | `5.0` | Rewrite timeout in seconds |
