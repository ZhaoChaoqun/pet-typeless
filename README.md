# PetTypeless

Cloud-native speech-to-text tool powered by 豆包 bigmodel_async ASR. A cloud variant of [Nano Typeless](https://github.com/ZhaoChaoqun/nano-typeless).

## Architecture

```
macOS Client ← WebSocket → Relay Server ← 豆包 bigmodel_async → ASR
```

- **`server/`** — Python FastAPI relay server (see [server/README.md](server/README.md))
- **`client/`** — macOS app

## Getting Started

See [server/README.md](server/README.md) for server setup.
