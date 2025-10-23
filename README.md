
Native, Apple Silicon–only local LLM server. Built on Apple's MLX for maximum performance on M‑series chips. SwiftUI app + SwiftNIO server with OpenAI‑compatible and Ollama‑compatible endpoints.

## Highlights

- **OpenAI API compatible**: `/v1/models` and `/v1/chat/completions` (stream and non‑stream)
- **Ollama‑compatible**: `/chat` endpoint with NDJSON streaming for OllamaKit and other Ollama clients
- **Function/Tool calling**: OpenAI‑style `tools` + `tool_choice`, with `tool_calls` parsing and streaming deltas
- **Fast token streaming**: Server‑Sent Events for low‑latency output


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
│   ├── ResponseWriters.swift       # SSE and NDJSON response writers
│   ├── ServerConfiguration.swift
│   └── ServerHealth.swift
├── Networking/
│   ├── HTTPHandler.swift           # Request parsing & routing entry
│   ├── Router.swift                # Routes → handlers with path normalization
│   └── AsyncHTTPHandler.swift      # Unified streaming handler
├── Services/
│   ├── MLXService.swift            # MLX loading, session caching, generation
│   ├── SearchService.swift
│   └── SystemMonitorService.swift  # Real-time CPU and RAM monitoring
├── Theme/
│   └── Theme.swift
├── Views/
│   ├── Components/SimpleComponents.swift
│   ├── ContentView.swift           # Start/stop server, quick controls
│   └── ModelDownloadView.swift     # Browse/download/manage models
└── Assets.xcassets/
```

## Features

- Native MLX text generation with model
- Model manager with curated suggestions (Llama, Qwen, Gemma, Mistral, etc.)
- Multiple response formats: SSE (OpenAI‑style) and NDJSON (Ollama‑style)
- Compatible with OllamaKit and other Ollama client libraries
- OpenAI‑compatible function calling with robust parser for model outputs (handles code fences/formatting noise)

## API Endpoints

- `GET /` → Plain text status
- `GET /health` → JSON health info
- `GET /models` → OpenAI‑compatible models list
- `GET /tags` → Ollama‑compatible models list
- `POST /chat/completions` → OpenAI‑compatible chat completions
- `POST /chat` → Ollama‑compatible chat endpoint

**Path normalization**: All endpoints support common API prefixes (`/v1`, `/api`, `/v1/api`). For example:

- `/v1/models` → `/models`
- `/api/chat/completions` → `/chat/completions`
- `/api/chat` → `/chat` (Ollama‑style)

## Getting Started


### Install with Homebrew

The easiest way to install Osaurus is through Homebrew cask (app bundle):

```bash
brew install --cask osaurus
```

This installs `Osaurus.app`. The CLI (`osaurus`) is embedded inside the app and will be auto-linked by the cask if available. If the `osaurus` command isn't found on your PATH, run one of the following:

```bash
# One-liner: symlink the embedded CLI into your Homebrew bin
ln -sf "/Applications/Osaurus.app/Contents/Helpers/osaurus" "$(brew --prefix)/bin/osaurus" || \
ln -sf "$HOME/Applications/Osaurus.app/Contents/Helpers/osaurus" "$(brew --prefix)/bin/osaurus"

# Or use the helper script (auto-detects paths and Homebrew prefix)
curl -fsSL https://raw.githubusercontent.com/dinoki-ai/osaurus/main/scripts/install_cli_symlink.sh | bash
```

Once installed, you can launch Osaurus from:

- **Spotlight**: Press `⌘ Space` and type "osaurus"
- **Applications folder**: Find Osaurus in `/Applications`
- **Terminal**: Run `open -a osaurus`

The app will appear in your menu bar, ready to serve local LLMs on your Mac.

### Build and run

1. Open `osaurus.xcodeproj` in Xcode 16.4+
2. Build and run the `osaurus` target
3. In the UI, configure the port via the gear icon (default `1337`) and press Start
4. Open the model manager to download a model (e.g., "Llama 3.2 3B Instruct 4bit")

Models are stored by default at `~/MLXModels`. Override with the environment variable `OSU_MODELS_DIR`.

### Command-line server management

The CLI lets you start/stop the server programmatically. If `osaurus` isn’t found in your `PATH` after installing the app:

- Run the one-liner above to create the symlink, or
- From a cloned repo, run: `scripts/install_cli_symlink.sh`, or
- For development builds: `make install-cli` (uses DerivedData output)

```bash
# Start on localhost (default)
osaurus serve --port 1337

# Start exposed on your LAN (will prompt for confirmation)
osaurus serve --port 1337 --expose

# Start exposed without prompt (non-interactive)
osaurus serve --port 1337 --expose --yes

# Check status
osaurus status

# Stop the server
osaurus stop
```

Notes:

- When started via CLI without `--expose`, Osaurus binds to `127.0.0.1` only.
- `--expose` binds to `0.0.0.0` (LAN). There is no authentication; use only on trusted networks.
- Management is local-only via macOS Distributed Notifications; there are no HTTP start/stop endpoints.


Notes

- Leave the field empty to disable CORS entirely.
- `*` cannot be combined with credentials; Osaurus does not use cookies, so this is typically fine for local use.

## Models

- Curated suggestions include Llama, Qwen, Gemma, Mistral, Phi, DeepSeek, etc. (4‑bit variants for speed)
- Discovery pulls from Hugging Face `mlx-community` and computes size estimates
- Required files are fetched automatically (tokenizer/config/weights)
- Change the models directory with `OSU_MODELS_DIR`

## Notes & Limitations

- Apple Silicon only (requires MLX); Intel Macs are not supported
- Localhost by default; `--expose` enables LAN access. No authentication; use only on trusted networks or behind a reverse proxy.
- `/transcribe` endpoints are placeholders pending Whisper integration

## Dependencies

- SwiftNIO (HTTP server)
- SwiftUI/AppKit (UI)
- MLX‑Swift, MLXLLM (runtime and generation)

