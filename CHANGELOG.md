# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-11-08

### Added

- **Update status in the status menu.** The menu shows the installed version
  and, when a newer release exists, an "Update to x.y.z…" item that opens the
  download, plus "Check for Updates". Settings lists the installed and latest
  versions with the same two buttons, and the app re-checks every six hours
  instead of only at launch.

### Fixed

- **The Update button downloads the release.** It pointed at GitHub's API
  `releases/assets/<file name>` endpoint, which takes a numeric id and answered
  404. It now uses the asset's own download link, and falls back to the release
  page when a release has no DMG.
- **Update checks survive a GitHub API outage, and say why they fail.** The
  check asks github.com's `releases/latest` redirect first, which kept
  answering while `api.github.com` returned 504, and falls back to the API.
  A failure now names the cause — timeout, HTTP status, rate limit — and is
  logged under `com.claudebridge.app`, instead of a bare "Could not check".
- **The profile editor uses the whole Settings window.** The model table's
  ID and "Shown as" fields drew their placeholder as a row label, squeezing
  the text into a narrow wrapped column, and the header no longer lined up
  with the rows. The grouped form also kept every section in a ~700pt column
  however wide the window was; the editor now lays out its own full-width
  sections.
- **The update check no longer waits for the keychain.** It ran last at
  launch, behind the credential read that can sit on an authorisation prompt,
  so after a rebuild it did not run until the prompt was answered.

## [0.4.0] - 2026-11-06

### Added

- **One-click update check in Settings.** The General settings panel now shows
  an Update section that checks GitHub releases when the window opens. If a
  newer version is available it shows the installed and remote versions side by
  side with an Update button that opens the DMG download. When up to date it
  shows the current version and a Check now button.
- **Larger, resizable Settings window.** The window now defaults to 1200×800
  with a minimum of 1100×700, and the model table columns stretch to fill the
  available width instead of being fixed-size.

## [0.3.2] - 2026-11-05

### Fixed

- **The macOS build no longer breaks on CI.** `swift package update` pulled in
  swift-collections 1.7.5, whose Package.swift declares Swift tools version 6.4
  while the GitHub Actions runner only ships 6.1, so `swift build` failed with
  "package 'swift-collections' @ 1.7.5 is using Swift tools version 6.4.0 but
  the installed version is 6.1.0". swift-collections is pinned to 1.2.1 (tools
  version 5.10, the highest release that builds on CI) and swift-nio is kept at
  its latest tools-6.1-compatible version, so the dependency line stays fresh
  without drifting out of CI's reach.

## [0.3.1] - 2026-09-17

### Fixed

- **An empty `gatewayToken` no longer turns authentication off.** The token is
  what stops other software on the machine using the bridge as an open relay to
  your paid provider, but an empty one waved every request through — so a
  hand-edited or truncated `settings.json` opened the relay silently, since
  loopback asks for no other credential. The bridge now refuses those requests
  and logs the refusal, and a settings file with an empty token has one
  generated when it is read, so the state is repaired rather than merely
  reported.
- The gateway token's files are written `0600` rather than left at the default
  `0644`, and the settings directory is created `0700`. `~/Library` is `0700` on
  a stock macOS, so this was not a live exposure — it is there for the machine
  whose owner has loosened those directories.

## [0.3.0] - 2026-09-09

### Added

- **Launch Claude Bridge at login**, in Settings. Claude Desktop cannot reach a
  bridge that is not running and reads its inference config only at launch, so
  opening it first after a reboot failed for the whole session. The existing
  "start the bridge when Claude Bridge launches" setting only helped once the
  app had been opened by hand; the two together make logging in enough. The
  toggle reads its state from macOS rather than storing a copy, so it cannot
  claim a registration the user has revoked in System Settings.

### Fixed

- The published `.sha256` recorded the build machine's absolute path instead of
  the file's name, so the documented
  `shasum -a 256 -c ClaudeBridge-<version>.dmg.sha256` failed for everyone who
  downloaded a release. The hashes were always correct; only the name beside
  them was unusable. The 0.1.1 and 0.2.0 assets have been corrected in place.

## [0.2.0] - 2026-09-09

### Added

- Switch back to **Anthropic's own models** from the menu bar. Claude Desktop
  has no configuration entry for first-party inference — it falls back to it
  when no valid configuration is applied — so this takes it off third-party
  inference without deleting anything, and switching back is one click. Useful
  when some tasks want the real Claude and others want a local model.
- Profiles are listed as destinations in their own right. Choosing one selects
  the backend, points Claude Desktop at the bridge and restarts it in a single
  click, instead of three separate trips through the menu. The restart prompt is
  suppressible.
- Configuration entries are labelled with where they actually send inference —
  `Default (localhost:4000)` — because Claude Desktop names its own first entry
  "Default" whatever it contains.

### Fixed

- "Restore previous configuration" reported success while doing nothing when the
  bridge had no remembered entry, which left Claude Desktop stuck on the bridge
  with no way back. Destinations are now chosen explicitly rather than
  remembered.
- The menu listed configuration entries as they were at launch, so entries
  deleted in Claude Desktop went on being offered — and picking one wrote a
  reference to a file that no longer existed. The config library is now watched
  for changes.

### Changed

- The Settings pane and the menu bar now share one switcher, so they cannot
  drift apart.
- `previousClaudeEntryID` is no longer stored; it existed only for the restore
  path that explicit destinations replace. Existing settings files are unaffected.

## [0.1.1] - 2026-09-06

### Fixed

- Release builds are now universal. 0.1.0 shipped an arm64-only binary, because
  `swift build` targets the host architecture and the release was cut on Apple
  Silicon, so it could not launch on an Intel Mac at all. CI now fails if either
  architecture is missing from the packaged app.

## 0.1.0 - 2026-09-06 — withdrawn

Withdrawn shortly after publication: the build was arm64 only and would not
launch on an Intel Mac. The release and its tag were deleted so nobody
downloads it. Everything below shipped in 0.1.1 instead.

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

[Unreleased]: https://github.com/first-it-consulting/claude-bridge/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/first-it-consulting/claude-bridge/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/first-it-consulting/claude-bridge/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/first-it-consulting/claude-bridge/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/first-it-consulting/claude-bridge/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/first-it-consulting/claude-bridge/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/first-it-consulting/claude-bridge/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/first-it-consulting/claude-bridge/releases/tag/v0.1.1
