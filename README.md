## Highlights

- **OpenAI API compatible**: `/v1/models` and `/v1/chat/completions` (stream and non‑stream)
- **Ollama‑compatible**: `/chat` endpoint with NDJSON streaming for OllamaKit and other Ollama clients
- **Function/Tool calling**: OpenAI‑style `tools` + `tool_choice`, with `tool_calls` parsing and streaming deltas
- **Fast token streaming**: Server‑Sent Events for low‑latency output

## Requirements

- macOS 15.5+
- Apple Silicon (M1 or newer)
- Xcode 16.4+ (to build from source)

## Features
- Native MLX text generation with model
- Model manager with curated suggestions (Llama, Qwen, Gemma, Mistral, etc.)
- Multiple response formats: SSE (OpenAI‑style) and NDJSON (Ollama‑style)
- Compatible with OllamaKit and other Ollama client libraries
- OpenAI‑compatible function calling with robust parser for model outputs (handles code fences/formatting noise)

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
