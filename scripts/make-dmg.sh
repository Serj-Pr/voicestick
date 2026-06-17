#!/bin/bash
# Package VoiceStick.app into a signed and optionally notarized DMG.
#
# Usage:
#   scripts/make-dmg.sh
#   scripts/make-dmg.sh build/VoiceStick.app
#   scripts/make-dmg.sh build/VoiceStick.app build/VoiceStick-<version>.dmg
#
# Optional environment:
#   ALLOW_ADHOC_RELEASE=1      allow a local ad-hoc signed DMG
#   ALLOW_UNNOTARIZED_DMG=1    allow a local DMG without Apple notarization

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BUILD_DIR="$ROOT_DIR/build"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
APP_PATH="${1:-$BUILD_DIR/VoiceStick.app}"
OUTPUT="${2:-$BUILD_DIR/VoiceStick-${VERSION}.dmg}"
STAGING_DIR="$BUILD_DIR/.dmg-staging"
VOLUME_NAME="VoiceStick"
ENTITLEMENTS="$ROOT_DIR/desktop/macos/Resources/VoiceStick.entitlements"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: Application bundle not found: $APP_PATH"
    exit 1
fi

CODESIGN_IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')"
fi

if [ "$CODESIGN_IDENTITY" = "-" ] && [ "${ALLOW_ADHOC_RELEASE:-0}" != "1" ]; then
    echo "Error: Developer ID Application signing identity was not found."
    echo "       A public DMG must be Developer ID signed so users can open it without workarounds."
    echo "       For local testing only, rerun with ALLOW_ADHOC_RELEASE=1."
    exit 1
fi

echo "Signing app before DMG packaging..."
xattr -cr "$APP_PATH" 2>/dev/null || true
if [ "$CODESIGN_IDENTITY" != "-" ]; then
    echo "Using: $CODESIGN_IDENTITY"
    codesign --deep --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$CODESIGN_IDENTITY" "$APP_PATH"
else
    echo "Using ad-hoc signature."
    codesign --deep --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP_PATH"
fi

echo "Verifying app signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

rm -rf "$STAGING_DIR" "$OUTPUT"
mkdir -p "$STAGING_DIR"
ditto --norsrc --noextattr "$APP_PATH" "$STAGING_DIR/VoiceStick.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Creating DMG..."
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$OUTPUT"
rm -rf "$STAGING_DIR"

if xcrun notarytool history --keychain-profile "AC_PASSWORD" >/dev/null 2>&1; then
    echo "Submitting DMG for notarization..."
    xcrun notarytool submit "$OUTPUT" --keychain-profile "AC_PASSWORD" --wait
    xcrun stapler staple "$OUTPUT"
else
    if [ "${ALLOW_UNNOTARIZED_DMG:-0}" = "1" ]; then
        echo "Skipping notarization: keychain profile AC_PASSWORD was not found."
    else
        echo "Error: notarization keychain profile AC_PASSWORD was not found."
        echo "       A public DMG must be notarized so Gatekeeper accepts it normally."
        echo "       For local testing only, rerun with ALLOW_UNNOTARIZED_DMG=1."
        exit 1
    fi
fi

echo "DMG complete: $OUTPUT"
