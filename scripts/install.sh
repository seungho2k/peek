#!/bin/bash
# Builds a release peek.app, installs it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$(scripts/build.sh release | tail -1)"
pkill -x peek 2>/dev/null || true
sleep 0.3
rm -rf /Applications/peek.app
cp -R "$APP" /Applications/peek.app
# Register right away so Spotlight/the app library pick up the icon and category.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/peek.app
open /Applications/peek.app
echo "installed /Applications/peek.app"
