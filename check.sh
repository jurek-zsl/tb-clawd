#!/bin/bash
set -euo pipefail
TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$TASK_DIR"
POCK_APP="${POCK_APP:-/Applications/Pock.app}"
"$TASK_DIR/build.sh"
POCKKIT="$POCK_APP/Contents/Frameworks/PockKit.framework/PockKit"
"$ROOT_DIR/build/pock/ClawdTools" --check "$ROOT_DIR/dist/Clawd.pock" "$POCKKIT"
"$ROOT_DIR/build/pock/ClawdTools" --check-live "$ROOT_DIR/dist/ClawdLive.pock" "$POCKKIT" "$ROOT_DIR/dist/Clawd.pock"
for NAME in Clawd ClawdLive; do
    codesign --verify --deep --strict "$ROOT_DIR/dist/$NAME.pock"
    for ARCH in arm64 x86_64; do
        xcrun lipo "$ROOT_DIR/dist/$NAME.pock/Contents/MacOS/$NAME" -verify_arch "$ARCH"
    done
done
# The status line bridge: saves payloads with rate_limits, ignores others,
# and passes the payload through to a previous status line command.
BRIDGE_HOME="$(mktemp -d)"
trap 'rm -rf "$BRIDGE_HOME"' EXIT
printf '{"model":null}' | CLAUDE_CONFIG_DIR="$BRIDGE_HOME" "$TASK_DIR/Tools/clawd-statusline.sh"
[[ ! -e "$BRIDGE_HOME/clawd/limits.json" ]] || { echo "FAIL: bridge saved a payload without limits"; exit 1; }
printf 'cat >/dev/null; printf previous' > "$BRIDGE_HOME/clawd/next-statusline"
OUT="$(printf '{"rate_limits":{"five_hour":{"used_percentage":12}}}' | CLAUDE_CONFIG_DIR="$BRIDGE_HOME" "$TASK_DIR/Tools/clawd-statusline.sh")"
grep -q '"used_percentage":12' "$BRIDGE_HOME/clawd/limits.json" || { echo "FAIL: bridge did not save limits"; exit 1; }
[[ "$OUT" == "previous" ]] || { echo "FAIL: bridge did not chain the previous status line"; exit 1; }
echo "PASS: status line bridge saves limits and chains the previous status line."
