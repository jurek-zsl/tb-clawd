#!/bin/bash
set -euo pipefail
TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$TASK_DIR"
POCK_APP="${POCK_APP:-/Applications/Pock.app}"
"$TASK_DIR/build.sh"
"$ROOT_DIR/build/pock/ClawdTools" --check "$ROOT_DIR/dist/Clawd.pock" "$POCK_APP/Contents/Frameworks/PockKit.framework/PockKit"
codesign --verify --deep --strict "$ROOT_DIR/dist/Clawd.pock"
for ARCH in arm64 x86_64; do
    xcrun lipo "$ROOT_DIR/dist/Clawd.pock/Contents/MacOS/Clawd" -verify_arch "$ARCH"
done
