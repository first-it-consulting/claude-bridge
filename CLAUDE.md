# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
make build                # swift build
make test                 # swift test
make app                  # assemble dist/Claude Bridge.app (release, ad-hoc signed)
make run                  # rebuild the .app and relaunch it
make clean

swift test --filter "SharedModelTests"                    # one suite
swift test --filter "advertisedIDsPassClaudeDesktopFilter" # one test
```

Live tests against a real backend are skipped unless both variables are set:

```sh
CLAUDE_BRIDGE_LIVE_BACKEND=http://localhost:11434/v1 \
CLAUDE_BRIDGE_LIVE_MODEL=qwen3-coder-next:latest \
swift test
```

Run the server without the menu bar app — it reads the same settings file, and
is the fastest way to see errors the GUI swallows:

```sh
swift build && .build/debug/claude-bridged --port 8799 --verbose
```

## What this is

A macOS menu bar app that makes Claude Desktop talk to local or remote LLMs.
Claude Desktop's third-party inference mode will use any gateway implementing
the Anthropic Messages API; Claude Bridge is that gateway, on loopback,
translating to OpenAI-compatible backends or passing through Anthropic ones.

## Architecture

Three targets over one library:

- `BridgeCore` — everything that is not UI. Server, router, translation,
  discovery, config, keychain.
- `ClaudeBridgeApp` — SwiftUI `MenuBarExtra`. `AppState` is the only thing that
  coordinates server, profile store, and Claude Desktop's config.
- `claude-bridged` — the same server headless.

Request path: `BridgeServer` (NIO) → `BridgeRouter` → `UpstreamClient` → backend.
`BridgeRouter` takes a `BridgeRequest` and writes to a `ResponseSink`, so it is
testable without a socket; `ChannelResponseSink` is the NIO implementation.

Translation works on `JSONValue`, a loss-free JSON tree, not on `Codable`
structs. The bridge is a proxy first: it rewrites the fields it understands and
forwards everything else untouched, so unknown Anthropic request fields and
provider extensions survive. Keep it that way.

Anthropic-kind backends are passed through with only the model name rewritten,
which is what preserves `cache_control` prompt caching. The OpenAI path must
strip `cache_control` because those backends reject unknown content-block
fields.

## Claude Desktop integration

Config lives at `~/Library/Application Support/Claude-3p/configLibrary/`: one
`<uuid>.json` per entry plus `_meta.json` holding `appliedId`. `ClaudeDesktopConfig`
writes exactly one entry named `Claude Bridge` and must never edit or delete
entries it did not create. An MDM profile at
`/Library/Managed Preferences/<user>/com.anthropic.claudefordesktop.plist`
overrides everything written locally — detect and report it rather than failing
silently.

**Claude Desktop reads its inference config and model list only at launch.** Any
change to either needs an app restart to take effect.

### The advertised-id scheme

Claude Desktop filters the model list twice and the two filters disagree.
Discovery keeps a model whose id looks Anthropic-ish *or* that carries
`anthropic_family_tier`. The picker is then built by re-filtering that list on
the **id alone**, tier field ignored, against a vendor denylist covering `qwen`,
`llama`, `gemma`, `gpt`, `mistral` and around forty more names. A local model
passes the first filter and is dropped by the second.

The second filter accepts one form unconditionally:
`^(sonnet|opus|haiku|fable|mythos)(-[\d.]+)?$`. So `Profile.servedModels`
advertises models under their tier name (`sonnet`, then `sonnet-2`, `sonnet-3`
within a tier) and puts the real model name in `display_name`, which is what the
picker labels entries with. `BridgeRouter.resolveModel` maps the alias back.

Do not advertise raw model names — it looks like it works (discovery reports
them) and then the picker is empty. Diagnose with
`~/Library/Logs/Claude-3p/main.log`:

```
Model discovery: 6 found in 161ms; picker = 6 (discovery)   # good
Model discovery: 4 found in 146ms; picker = 0 (empty)       # ids rejected
```

## Constraints learned the hard way

Each of these caused a real failure; the code carries comments explaining why.

- **Never block the main actor on the keychain.** `SecItemCopyMatching` does not
  return until an authorisation prompt is answered, and a read in
  `AppState.init` deadlocked the whole app before it could bind a port. Keychain
  access is async and hops to a private queue; `*Blocking` variants exist only
  for the daemon. Check `authScheme != .none` before touching it at all.
- **Never parse SSE through `AsyncLineSequence`.** It drops empty lines, which
  are exactly what separates events, so the whole stream collapses into one.
  Use `SSEParser.events(from:)`, which reads bytes.
- **NIO write promises only complete once flushed.** Awaiting an unflushed write
  deadlocks the response.
- **Top-level code in `main.swift` runs on the MainActor.** Blocking it to keep
  a process alive also stops the tasks it started. `claude-bridged` uses
  `@main` with an async `main()` for this reason.
- **New fields on persisted types must be optional.** Synthesized `Codable`
  ignores default values for missing keys, so a non-optional addition makes
  every existing `settings.json` fail to decode, and `ProfileStore.load()` falls
  back to starter profiles — silent data loss. `ModelMapping.origin` is optional
  for this reason, and a nil origin means "discovered".
- **Release builds must be universal.** `swift build` targets the host
  architecture, so a release cut on Apple Silicon produces an arm64-only app
  that will not launch on an Intel Mac. `scripts/build-app.sh` passes
  builds each slice with `--triple` and joins them with `lipo`. Do not switch
  it to `--arch arm64 --arch x86_64`: that form selects the Xcode build system,
  which fails on swift-collections' `_RopeModule` with the toolchain on GitHub's
  runners — and prints "Build complete!" before exiting non-zero, so it reads
  like a success.
- Ad-hoc signing changes the binary's cdhash on every build, so macOS re-prompts
  for keychain items. That is expected in development, not a bug to fix.

## Model list semantics

Discovery is a reconciliation, not an append. `ModelCatalog.reconcile` adds new
models, keeps the tier and label the user set, removes entries discovery itself
added once the backend stops listing them, and only *reports* hand-added entries
the backend does not list — some backends serve models their `/v1/models` never
mentions. An empty discovery result is treated as "no information" and changes
nothing.

## Commits

Conventional Commits, enforced from the first commit. Split unrelated fixes into
separate commits even when they touch the same files, and verify each one builds
and tests clean so `git bisect` stays useful.
