#!/usr/bin/env bash
# Packages Claude Bridge.app into a distributable .dmg.
#
# Signing is conditional. With no Developer ID available the app keeps its
# ad-hoc signature and the DMG still works, it just makes Gatekeeper complain on
# first launch. When the signing environment is present the app is signed with a
# Developer ID, hardened, notarised and stapled, which is what removes that
# prompt. Both paths produce the same artefact layout so the release workflow
# does not branch.
#
# Signing environment (all required together):
#   MACOS_CERTIFICATE       base64 of a Developer ID Application .p12
#   MACOS_CERTIFICATE_PWD   its password
#   APPLE_TEAM_ID           10-character team identifier
# Notarisation additionally needs:
#   APPLE_ID                Apple account e-mail
#   APPLE_APP_PASSWORD      app-specific password for that account
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Claude Bridge"
VERSION="$(cat "$ROOT/VERSION")"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/ClaudeBridge-$VERSION.dmg"

echo "==> Building $APP_NAME $VERSION"
"$ROOT/scripts/build-app.sh" release

can_sign() {
    [[ -n "${MACOS_CERTIFICATE:-}" && -n "${MACOS_CERTIFICATE_PWD:-}" && -n "${APPLE_TEAM_ID:-}" ]]
}
can_notarize() {
    can_sign && [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]
}

if can_sign; then
    echo "==> Importing Developer ID certificate"
    KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
    KEYCHAIN_PWD="$(uuidgen)"
    CERT="$RUNNER_TEMP/certificate.p12"

    echo -n "$MACOS_CERTIFICATE" | base64 --decode > "$CERT"
    security create-keychain -p "$KEYCHAIN_PWD" "$KEYCHAIN"
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PWD" "$KEYCHAIN"
    security import "$CERT" -P "$MACOS_CERTIFICATE_PWD" -A \
        -t cert -f pkcs12 -k "$KEYCHAIN"
    # Without this the codesign call blocks on a UI prompt no CI run can answer.
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$KEYCHAIN_PWD" "$KEYCHAIN" > /dev/null
    security list-keychain -d user -s "$KEYCHAIN" login.keychain-db
    rm -f "$CERT"

    IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
        | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')"
    echo "==> Signing as: $IDENTITY"

    # --options runtime is what notarisation requires; --timestamp makes the
    # signature outlive the certificate.
    codesign --force --deep --options runtime --timestamp \
        --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    echo "==> No signing environment; keeping the ad-hoc signature"
fi

echo "==> Staging disk image"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
# The conventional drag-to-install target.
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" > /dev/null

if can_sign; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

if can_notarize; then
    echo "==> Notarising (this usually takes a few minutes)"
    xcrun notarytool submit "$DMG" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait
    # Stapling lets Gatekeeper validate offline, so a first launch with no
    # network is not blocked.
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
else
    echo "==> Skipping notarisation (credentials not provided)"
fi

# Hash from inside dist/ so the file records a bare filename. Hashing the full
# path recorded the build machine's absolute path — on CI, /Users/runner/... —
# which made the documented `shasum -a 256 -c ClaudeBridge-<version>.dmg.sha256`
# fail for everyone who downloaded it.
( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256" )
echo "==> Done: $DMG"
