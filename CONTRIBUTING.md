# Contributing

Thanks for taking a look. Issues and pull requests are welcome.

## Getting set up

You need macOS 14 or later and a Swift 6 toolchain (Xcode 16+).

```sh
git clone https://github.com/first-it-consulting/claude-bridge.git
cd claude-bridge
make test          # unit tests, no backend required
make run           # build dist/Claude Bridge.app and launch it
```

`CLAUDE.md` in the repository root is the orientation document: it covers the
architecture, how the Claude Desktop integration works, and a list of
constraints that each caused a real failure. Read it before changing the server,
the translation layer, or anything touching the keychain.

## Testing

```sh
make test
swift test --filter "SharedModelTests"      # a suite
swift test --filter "numberedWithinTier"    # a single test
```

Tests that need a real model server are skipped unless you point them at one:

```sh
CLAUDE_BRIDGE_LIVE_BACKEND=http://localhost:11434/v1 \
CLAUDE_BRIDGE_LIVE_MODEL=qwen3-coder-next:latest \
swift test
```

Run these before submitting anything that touches translation or streaming. The
unit tests cover shapes; only a live backend catches a stream that parses but
does not actually flow.

## Debugging against Claude Desktop

Two things are worth knowing before you spend an afternoon on a mystery:

- Claude Desktop reads its inference configuration and model list **only at
  launch**. Restart it after any change.
- `~/Library/Logs/Claude-3p/main.log` is the source of truth for whether your
  models arrived:

  ```
  Model discovery: 6 found in 161ms; picker = 6 (discovery)   # good
  Model discovery: 4 found in 146ms; picker = 0 (empty)       # ids rejected
  ```

For anything else, `claude-bridged --verbose` runs the same server without the
UI and prints each request, which is usually faster than reading the log window.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), checked
in CI on pull requests:

```
<type>(<scope>): <subject>
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`,
`ci`, `chore`, `revert`. Scopes in use: `core`, `app`, `daemon`, `models`,
`keychain`, `server`, `ui`. Subject in the imperative, no trailing full stop,
80 characters or fewer.

Check your branch before pushing:

```sh
./scripts/check-commits.sh origin/main HEAD
```

Keep unrelated changes in separate commits, even when they touch the same file,
and make sure each one builds and tests clean so `git bisect` stays useful. Say
*why* in the body — the what is in the diff.

## Pull requests

Keep them focused. Add tests for behaviour changes, especially in translation:
that code exists to satisfy two protocols that disagree, and a test is the only
place the disagreement is written down.

If you change what the bridge sends to Claude Desktop, say how you verified it
against a running Claude Desktop, not just against the test suite.

## Dependencies

Dependabot opens pull requests weekly for GitHub Actions and Swift packages.
Patch and minor updates merge themselves once the required checks pass; major
updates wait for a human, and get a comment saying so. `main` requires the
build, package and commit-message checks to pass, which is what makes
auto-merge wait for CI rather than merging immediately.

## Releasing

Maintainers only. Releases are cut from a tag; the workflow refuses to publish
if the tag, `VERSION` and `CHANGELOG.md` disagree.

1. Move the `## [Unreleased]` entries in `CHANGELOG.md` into a new
   `## [x.y.z] - YYYY-MM-DD` section, and update the link definitions at the
   bottom of the file.
2. Set the same version in `VERSION`.
3. Commit as `chore(release): x.y.z` and merge to `main`.
4. Tag and push:

   ```sh
   git tag -a vx.y.z -m "Claude Bridge x.y.z"
   git push origin main vx.y.z
   ```

The Release workflow then runs the tests, builds and packages the DMG, signs and
notarises it when the Apple credentials are configured, and publishes a GitHub
Release whose notes are the changelog section plus a checksum. To rehearse
without publishing, run the workflow manually from the Actions tab — that path
builds and uploads an artefact but creates no release.

### Signing secrets

Without these, releases are ad-hoc signed and macOS warns on first launch. With
all of them, the DMG is signed, notarised and stapled. Nothing else changes.

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE` | Developer ID Application `.p12`, base64 encoded |
| `MACOS_CERTIFICATE_PWD` | Password for that `.p12` |
| `APPLE_TEAM_ID` | 10-character Apple team identifier |
| `APPLE_ID` | Apple account e-mail used for notarisation |
| `APPLE_APP_PASSWORD` | App-specific password for that account |
