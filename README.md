# Claude Bridge

A macOS menu bar app that lets **Claude Desktop** talk to local and remote LLMs —
Ollama, LM Studio, llama.cpp, vLLM, OpenRouter, Groq, LiteLLM, or anything else
that speaks the OpenAI or Anthropic API. Switch providers from the status bar.

Ollama ships a one-provider version of this. Claude Bridge is the generic one:
any number of providers, any model, one click to switch.

## How it works

Claude Desktop has a built-in **third-party inference** mode. Point it at a
gateway that implements the Anthropic Messages API and it will use that instead
of Anthropic's servers. Claude Bridge is that gateway, running on loopback:

```
Claude Desktop  ──Anthropic Messages API──▶  Claude Bridge (127.0.0.1:8788)
                                                     │
                            ┌────────────────────────┼────────────────────────┐
                            ▼                        ▼                        ▼
                   Ollama / LM Studio        OpenRouter / Groq        LiteLLM / Portkey
                   (OpenAI, translated)      (OpenAI, translated)     (Anthropic, passed through)
```

Two things make this work that are not obvious:

**Anthropic ↔ OpenAI translation.** Claude Desktop speaks `POST /v1/messages`
with content blocks, `tool_use`/`tool_result` pairs, and a specific SSE event
sequence. OpenAI backends speak `POST /chat/completions` with `tool_calls` and a
different stream shape. Claude Bridge translates both directions, including
streaming, parallel tool calls, and images.

**Getting non-Claude models into the picker.** Claude Desktop filters discovered
models down to ones whose IDs look like Claude models, which would hide every
local model you have. The documented way around it is the `anthropic_family_tier`
field on the `/v1/models` response. Claude Bridge tags every model it serves, so
`qwen3-coder:30b` shows up in the picker under the tier you assign — without
having to rename it to `claude-sonnet-5`.

The tier is not just cosmetic: Claude Desktop routes sub-agent work to Haiku and
main-conversation work to whatever you selected, so mapping a small fast model to
Haiku and a large one to Opus gets you sensible routing for free.

## Requirements

- macOS 14 or later
- Claude Desktop with third-party inference available
- Swift 6 toolchain to build (Xcode 16+)

## Install

```sh
git clone https://github.com/YOU/claude-bridge.git
cd claude-bridge
make app
open dist/"Claude Bridge.app"
```

The build is ad-hoc signed, which is enough to run locally. Distributing it to
other machines needs a Developer ID identity and notarisation.

## Setup

1. **Enable third-party inference in Claude Desktop**, once:
   Help ▸ Troubleshooting ▸ Enable Developer Mode, then
   Developer ▸ Configure Third-Party Inference. This creates the config folder
   Claude Bridge writes to.
2. **Add a profile** in Claude Bridge ▸ Settings. Pick a preset (Ollama, LM
   Studio, …), then press **Discover** to pull in the models it serves.
3. **Assign tiers.** Each model maps to Haiku, Sonnet, or Opus. Mark one model
   per tier as the default.
4. **Point Claude Desktop at the bridge** from the menu bar.
5. **Restart Claude Desktop.** It reads its inference settings and model list
   only at launch.

Switching profiles later is one click in the menu bar — plus a Claude Desktop
restart if you want its model picker to refresh.

## Backends

| Preset | Format | Notes |
| --- | --- | --- |
| Ollama | OpenAI | `http://localhost:11434/v1` |
| LM Studio | OpenAI | `http://localhost:1234/v1` |
| llama.cpp server | OpenAI | `http://localhost:8080/v1` |
| vLLM | OpenAI | `http://localhost:8000/v1` |
| LiteLLM | either | OpenAI routes, or Anthropic passthrough on `/v1/messages` |
| OpenRouter, Groq, Together | OpenAI | remote, needs an API key |
| Anthropic API | Anthropic | passthrough |

Anything else that speaks either protocol works via the **Custom** preset.

**Prefer an Anthropic-compatible backend when you have the choice.** Those are
passed through untouched, which preserves `cache_control` prompt-caching
breakpoints and thinking blocks. The OpenAI path has to strip `cache_control`,
because OpenAI backends reject unknown content-block fields — so long
conversations reprocess more of their context.

## What is and isn't translated

Handled on the OpenAI path:

- System prompts, multi-turn history, images
- Tools, including parallel tool calls and streamed argument fragments
- Streaming, mapped onto Anthropic's block-structured SSE events
- Token usage, including OpenAI's cached-token accounting
- `reasoning_content` from reasoning models — discarded by default, or shown as
  text

Not translated, by design:

- **Thinking blocks.** Anthropic signs them and replays them on the next turn.
  No other backend can produce a valid signature, so reasoning is either dropped
  or surfaced as ordinary text rather than forged.
- **`cache_control`.** Stripped for OpenAI backends; passed through for
  Anthropic ones.
- **Anthropic server-side tools** (web search, computer use). They have no
  `input_schema` and no OpenAI equivalent, so they are skipped rather than sent
  as functions the backend cannot honour.

## Headless

The same server runs without the UI:

```sh
swift build -c release
.build/release/claude-bridged --port 8788 --verbose
```

It reads the profiles the app writes, so configure once in the UI and run it
anywhere.

## Security

- The server binds to `127.0.0.1` only.
- Every request needs a gateway token, generated on first launch. Loopback is
  reachable by any process on the machine, so the token keeps other local
  software from using the bridge as an open relay to your paid providers.
- Backend API keys live in the login keychain, never in the settings file — so a
  profile file is safe to share.
- Request and response bodies are recorded only while **Capture bodies** is on,
  and only in memory.

## Files it touches

| Path | What |
| --- | --- |
| `~/Library/Application Support/ClaudeBridge/settings.json` | profiles, port, token |
| `~/Library/Application Support/Claude-3p/configLibrary/` | Claude Desktop's config; the bridge writes one entry named "Claude Bridge" and never edits others |
| login keychain, service `com.claudebridge.backend-key` | backend API keys |

If your Mac has an MDM configuration profile for Claude Desktop
(`/Library/Managed Preferences/<user>/com.anthropic.claudefordesktop.plist`), it
overrides anything written locally and the bridge will not be used. Claude Bridge
detects this and says so rather than failing quietly.

## Development

```sh
make build      # compile
make test       # unit tests
make app        # build dist/Claude Bridge.app
make run        # rebuild and relaunch
```

Live tests against a real backend are opt-in:

```sh
CLAUDE_BRIDGE_LIVE_BACKEND=http://localhost:11434/v1 \
CLAUDE_BRIDGE_LIVE_MODEL=qwen3-coder-next:latest \
swift test
```

### Layout

| Path | What |
| --- | --- |
| `Sources/BridgeCore/Model` | profiles, backends, model mappings |
| `Sources/BridgeCore/Config` | settings storage, presets, Claude Desktop config |
| `Sources/BridgeCore/Server` | NIO HTTP server and the router |
| `Sources/BridgeCore/Upstream` | protocol translation, SSE, discovery, health |
| `Sources/ClaudeBridgeApp` | SwiftUI menu bar app |
| `Sources/claude-bridged` | headless server |

## Troubleshooting

**The model picker is empty.** Claude Desktop only reads the model list at
launch. Restart it. If it is still empty, check the bridge is running and that
the profile has enabled models.

**Requests fail with 401.** The gateway token in Claude Desktop's config is
stale. Use "Point Claude Desktop at the Bridge" again, then restart it.

**A backend rejects requests.** Turn on **Capture bodies** in the Request Log,
reproduce, and read the exact request that went upstream.

**Long generations time out.** Claude Desktop gives up after about five minutes
of silence on a stream. Backends that send SSE keep-alive pings avoid this;
Claude Desktop's `inferenceStreamIdleTimeoutSec` raises the limit further, but
only when pings are actually arriving.

## License

MIT
