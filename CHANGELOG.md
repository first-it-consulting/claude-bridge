# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-09-06

### Fixed

- Release builds are now universal. 0.1.0 shipped an arm64-only binary, because
  `swift build` targets the host architecture and the release was cut on Apple
  Silicon, so it could not launch on an Intel Mac at all. CI now fails if either
  architecture is missing from the packaged app.

## [0.1.0] - 2026-09-06

First release.

### Added

- Menu bar app that serves Claude Desktop's third-party inference mode from
  loopback, with one click to switch between configured providers.
- Translation between the Anthropic Messages API and OpenAI
  `/chat/completions`, covering streaming, tool use including parallel calls,
  images, and token accounting. Anthropic-compatible backends are passed
  through untouched so prompt caching survives.
- Presets for Ollama, LM Studio, llama.cpp, vLLM, LiteLLM, OpenRouter, Groq,
  Together and the Anthropic API, plus a custom option for anything else
  speaking either protocol.
- Model discovery that reconciles against the backend, with per-model mapping
  to a Claude tier. One backend model can back several tiers, which is what a
  machine with room for a single loaded model needs.
- Writes Claude Desktop's third-party configuration and restarts it on request,
  leaving configurations it did not create alone and reporting when an MDM
  profile overrides it.
- Live request log with per-request timing, token counts and optional body
  capture, and a reachability check per backend.
- `claude-bridged`, the same server without the UI, sharing the app's profiles.
- Backend credentials stored in the login keychain rather than the settings
  file.
- An app icon, drawn by `scripts/make-icon.swift` and simplified at small sizes
  rather than downsampled, so it stays legible at 16pt in a Finder list.
- **About Claude Bridge** in the menu bar, showing the version and build number,
  the licence, a link to the repository, and a note that the project is not
  affiliated with Anthropic. The build number is the commit count, so two builds
  of the same version can be told apart in a bug report.

### Notes

- Models are advertised to Claude Desktop under Claude tier aliases. Claude
  Desktop filters its picker on the model id against a vendor denylist, so ids
  containing `qwen`, `llama`, `gemma` and similar never reach it. The real model
  name is what you see in the picker; see the README for the detail.
- Release builds are not notarised until Apple Developer credentials are
  configured, so macOS asks for confirmation on first launch.

[Unreleased]: https://github.com/first-it-consulting/claude-bridge/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/first-it-consulting/claude-bridge/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/first-it-consulting/claude-bridge/releases/tag/v0.1.0
