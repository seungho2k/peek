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
codesign --force --sign - "$APP" >/dev/null

echo "$APP"
