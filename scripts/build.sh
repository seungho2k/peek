#!/bin/bash
# Builds build/peek.app (ad-hoc signed). Usage: scripts/build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/peek.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Peek" "$APP/Contents/MacOS/peek"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp -R Support/Fonts "$APP/Contents/Resources/Fonts"
cp Support/peek.icns "$APP/Contents/Resources/peek.icns"
# Sign with the local "peek local" certificate when it exists (scripts/make-signing-cert.sh),
# so the Accessibility permission survives rebuilds; otherwise ad-hoc.
IDENTITY="-"
if security find-certificate -c "peek local" >/dev/null 2>&1; then IDENTITY="peek local"; fi
codesign --force --sign "$IDENTITY" "$APP" >/dev/null

echo "$APP"
