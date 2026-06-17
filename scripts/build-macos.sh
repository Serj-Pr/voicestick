#!/bin/bash
# Compatibility wrapper for the current self-contained Apple Silicon macOS build.
#
# Produces:
#   build/VoiceStick.app
#   build/VoiceStick-<version>.zip
#   build/VoiceStick-<version>.signature  (when Sparkle sign_update is available)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

exec "$ROOT_DIR/desktop/macos/build-macos-arm-release.sh" "$@"
