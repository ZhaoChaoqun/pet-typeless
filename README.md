# PetTypeless

Cloud-native speech-to-text tool powered by Azure Speech SDK and Azure OpenAI. A cloud variant of [Nano Typeless](https://github.com/ZhaoChaoqun/nano-typeless).

## Architecture

```
macOS Client ← WebSocket → Relay Server ← Azure Speech SDK → Azure ASR
                                        ← Azure OpenAI SDK → GPT rewrite
```

- **`server/`** — Python FastAPI relay server (see [server/README.md](server/README.md))
- **Client** — macOS app (coming soon)

## Getting Started

See [server/README.md](server/README.md) for server setup.
