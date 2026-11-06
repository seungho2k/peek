#!/bin/bash
# Rebuilds and relaunches peek.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$(scripts/build.sh "${1:-debug}" | tail -1)"
pkill -x peek 2>/dev/null || true
sleep 0.3
open "$APP"
