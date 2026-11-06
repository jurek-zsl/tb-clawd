#!/bin/bash
# Installs the widgets into Pock.
#   ./install.sh          both widgets
#   ./install.sh clawd    Clawd only (does his own thing)
#   ./install.sh live     Clawd Live only (follows local Claude Code)
set -euo pipefail
TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$TASK_DIR"
WIDGETS="$HOME/Library/Application Support/Pock/Widgets"
case "${1:-both}" in
    clawd) NAMES=(Clawd) ;;
    live) NAMES=(ClawdLive) ;;
    both) NAMES=(Clawd ClawdLive) ;;
    *) echo "usage: $0 [clawd|live|both]" >&2; exit 2 ;;
esac
for NAME in "${NAMES[@]}"; do
    BUNDLE="$ROOT_DIR/dist/$NAME.pock"
    DESTINATION="$WIDGETS/$NAME.pock"
    if [[ "$NAME" == "Clawd" ]]; then ID="com.jurekzsl.pock.Clawd"; else ID="com.jurekzsl.pock.ClawdLive"; fi
    if [[ ! -d "$BUNDLE" ]]; then "$TASK_DIR/build.sh"; fi
    codesign --verify --deep --strict "$BUNDLE"
    mkdir -p "$WIDGETS"
    if [[ -e "$DESTINATION" ]]; then
        EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$EXISTING_ID" != "$ID" ]]; then
            printf 'Refusing to replace unrelated path: %s\n' "$DESTINATION" >&2
            exit 1
        fi
        # Keep the previous copy outside the Widgets folder so Pock does not
        # load it as a second widget.
        BACKUP_DIR="$HOME/Library/Application Support/Pock/Clawd backups"
        mkdir -p "$BACKUP_DIR"
        BACKUP="$BACKUP_DIR/$NAME.pock.backup-$(date +%Y%m%d-%H%M%S)-$$"
        mv "$DESTINATION" "$BACKUP"
        printf 'Previous %s saved to %s\n' "$NAME" "$BACKUP"
    fi
    ditto "$BUNDLE" "$DESTINATION"
    printf 'Installed %s\n' "$DESTINATION"
done
printf 'Quit and reopen Pock, choose Customize Pock…, then drag Clawd or Clawd Live onto your Touch Bar.\n'
if [[ " ${NAMES[*]} " == *" ClawdLive "* ]]; then
    printf 'The first tap on Clawd Live asks to read Claude Code-credentials from the Keychain; allow it for limits.\n'
fi
