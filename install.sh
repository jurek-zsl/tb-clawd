#!/bin/bash
set -euo pipefail
TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$TASK_DIR"
BUNDLE="$ROOT_DIR/dist/Clawd.pock"
DESTINATION="$HOME/Library/Application Support/Pock/Widgets/Clawd.pock"
if [[ ! -d "$BUNDLE" ]]; then "$TASK_DIR/build.sh"; fi
codesign --verify --deep --strict "$BUNDLE"
mkdir -p "$(dirname "$DESTINATION")"
if [[ -e "$DESTINATION" ]]; then
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$EXISTING_ID" != "com.jurekzsl.pock.Clawd" ]]; then
        printf 'Refusing to replace unrelated path: %s\n' "$DESTINATION" >&2
        exit 1
    fi
    BACKUP="$DESTINATION.backup-$(date +%Y%m%d-%H%M%S)-$$"
    mv "$DESTINATION" "$BACKUP"
    printf 'Previous widget saved to %s\n' "$BACKUP"
fi
ditto "$BUNDLE" "$DESTINATION"
printf 'Installed %s\nQuit and reopen Pock, choose Customize Pock…, then drag Clawd onto your Touch Bar.\n' "$DESTINATION"
