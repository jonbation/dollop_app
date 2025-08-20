# Osaurus 🦕

Native, Apple Silicon–only local LLM server. Similar to Ollama, but built on Apple's MLX for maximum performance on M‑series chips. SwiftUI app + SwiftNIO server with OpenAI‑compatible endpoints.

Created by Dinoki Labs ([dinoki.ai](https://dinoki.ai)), a fully native desktop AI assistant and companion.

## Highlights

- **Native MLX runtime**: Optimized for Apple Silicon using MLX/MLXLLM
- **Apple Silicon only**: Designed and tested for M‑series Macs
- **OpenAI API compatible**: `/v1/models` and `/v1/chat/completions` (stream and non‑stream)
- **Fast token streaming**: Server‑Sent Events for low‑latency output
- **Model manager UI**: Browse, download, and manage MLX models from `mlx-community`
- **Self‑contained**: SwiftUI app with an embedded SwiftNIO HTTP server

## Requirements

- macOS 15.5+
- Apple Silicon (M1 or newer)
- Xcode 16.4+ (to build from source)

```
osaurus/
├── Core/
│   ├── AppDelegate.swift
│   └── osaurusApp.swift
├── Controllers/
│   ├── ServerController.swift      # NIO server lifecycle
│   └── ModelManager.swift          # Model discovery & downloads (Hugging Face)
├── Models/
│   ├── MLXModel.swift
│   ├── OpenAIAPI.swift             # OpenAI‑compatible DTOs
│   ├── ServerConfiguration.swift
│   └── ServerHealth.swift
├── Networking/
│   ├── HTTPHandler.swift           # Request parsing & routing entry
│   ├── Router.swift                # Routes → handlers
│   └── AsyncHTTPHandler.swift      # SSE streaming for chat completions
├── Services/
│   ├── MLXService.swift            # MLX loading, session caching, generation
│   └── SearchService.swift
├── Theme/
│   └── Theme.swift
├── Views/
│   ├── Components/SimpleComponents.swift
│   ├── ContentView.swift           # Start/stop server, quick controls
│   └── ModelDownloadView.swift     # Browse/download/manage models
└── Assets.xcassets/
```

## Features

- Native MLX text generation with model session caching
- Model manager with curated suggestions (Llama, Qwen, Gemma, Mistral, etc.)
- Download sizes estimated via Hugging Face metadata
- Streaming and non‑streaming chat completions
- Health endpoint and simple status UI

## API Endpoints

- `GET /` → Plain text status
- `GET /health` → JSON health info
- `GET /models` and `GET /v1/models` → OpenAI‑compatible models list
- `POST /chat/completions` and `POST /v1/chat/completions` → OpenAI‑compatible chat completions

## Getting Started

### Build and run

1. Open `osaurus.xcodeproj` in Xcode 16.4+
2. Build and run the `osaurus` target
3. In the UI, pick a port (default `8080`) and press Start
4. Open the model manager to download a model (e.g., “Llama 3.2 3B Instruct 4bit”)

Models are stored by default at `~/Documents/MLXModels`. Override with the environment variable `OSU_MODELS_DIR`.

### Use the API

Base URL: `http://127.0.0.1:8080` (or your chosen port)

List models:

```bash
curl -s http://127.0.0.1:8080/v1/models | jq
```

Non‑streaming chat completion:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "llama-3.2-3b-instruct-4bit",
        "messages": [{"role":"user","content":"Write a haiku about dinosaurs"}],
        "max_tokens": 200
      }'
```

Streaming chat completion (SSE):

```bash
curl -N http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "llama-3.2-3b-instruct-4bit",
        "messages": [{"role":"user","content":"Summarize Jurassic Park in one paragraph"}],
        "stream": true
      }'
```

Tip: Model names are lower‑cased with hyphens (derived from the friendly name), for example: `Llama 3.2 3B Instruct 4bit` → `llama-3.2-3b-instruct-4bit`.

### Use with OpenAI SDKs

Point your client at Osaurus and use any placeholder API key.

Python example:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="osaurus")

resp = client.chat.completions.create(
    model="llama-3.2-3b-instruct-4bit",
    messages=[{"role": "user", "content": "Hello there!"}],
)

print(resp.choices[0].message.content)
```

## Models

- Curated suggestions include Llama, Qwen, Gemma, Mistral, Phi, DeepSeek, etc. (4‑bit variants for speed)
- Discovery pulls from Hugging Face `mlx-community` and computes size estimates
- Required files are fetched automatically (tokenizer/config/weights)
- Change the models directory with `OSU_MODELS_DIR`

## Notes & Limitations

- Apple Silicon only (requires MLX); Intel Macs are not supported
- Localhost only, no authentication; put behind a proxy if exposing externally
- `/transcribe` endpoints are placeholders pending Whisper integration

## Dependencies

- SwiftNIO (HTTP server)
- SwiftUI/AppKit (UI)
- MLX‑Swift, MLXLLM (runtime and chat session)
