# Security Policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub's advisory form](https://github.com/first-it-consulting/claude-bridge/security/advisories/new)
rather than a public issue.

Include what an attacker can do, the steps to reproduce it, and the app version.
You can expect an acknowledgement within a few days.

## Supported versions

The latest release is the only supported version.

## What this app handles

Worth knowing when judging whether something is a vulnerability:

- **The bridge listens on `127.0.0.1` only** and requires a gateway token on
  every request except `/health`. Loopback is reachable by any process on the
  machine, so that token is what stops other local software using the bridge as
  an open relay to your paid providers. A change that binds a non-loopback
  address, or that makes the token optional, is a security issue.
- **Backend API keys live in the login keychain**, never in `settings.json`, so
  a profile file can be shared without leaking a credential. The keychain item's
  ACL is deliberately left at the macOS default, which scopes it to the signing
  binary; widening it would make every process running as you able to read those
  keys without a prompt.
- **Conversation content passes through the bridge** on its way to whichever
  backend you configured. It is not written to disk. Request and response bodies
  are kept only while "Capture bodies" is enabled in the request log, and only
  in memory.
- **Claude Desktop's configuration is written**, but only the one entry the app
  creates. Anything that makes the app modify or delete other entries, or write
  outside `~/Library/Application Support/Claude-3p/configLibrary/`, is a bug
  worth reporting.

Unsigned release builds are a known limitation rather than a vulnerability; see
the README.
