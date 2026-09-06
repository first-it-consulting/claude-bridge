#!/usr/bin/env bash
# Assembles Claude Bridge.app around the SwiftPM binary.
#
# SwiftPM produces a bare executable; a menu bar app needs a bundle so macOS
# reads LSUIElement (no Dock icon) and so the keychain can scope items to a
# stable identity.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Claude Bridge"
BUNDLE_ID="com.claudebridge.app"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo "0.1.0")"

BUILD_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/dist/$APP_NAME.app"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/claude-bridge" "$APP/Contents/MacOS/Claude Bridge"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Local model servers are plain HTTP on loopback. This exception is
         limited to localhost so the app still cannot make cleartext requests
         to the network at large. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
# Ad-hoc is enough to run locally and keeps keychain access stable across
# rebuilds. Distribution needs a Developer ID identity and notarisation.
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
