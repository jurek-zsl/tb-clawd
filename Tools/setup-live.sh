#!/bin/bash
# Connects Clawd Live's limits readout to Claude Code.
#
#   setup-live.sh             install the status line bridge
#   setup-live.sh --uninstall restore your previous status line
#
# Clawd's working/waiting/idle/asleep states need no setup: the widget reads
# ~/.claude/sessions directly. Only the remaining-limits readout needs this,
# because Claude Code shares `rate_limits` with status line commands.
#
# Your existing status line keeps working: the bridge runs it after saving
# the limits. ~/.claude/settings.json is backed up before it is changed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAWD_DIR="$CLAUDE_DIR/clawd"
SETTINGS="$CLAUDE_DIR/settings.json"
BRIDGE="$CLAWD_DIR/statusline.sh"
NEXT="$CLAWD_DIR/next-statusline"
MODE="${1:-install}"

SCRIPT="$(mktemp -t clawd-setup)"
trap 'rm -f "$SCRIPT"' EXIT
cat > "$SCRIPT" <<'JS'
ObjC.import('Foundation');
function read(path) {
    const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
    return text.isNil() ? null : text.js;
}
function write(path, text) {
    $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}
function run(argv) {
    const [mode, settingsPath, bridge, nextPath] = argv;
    const text = read(settingsPath);
    const settings = text && text.trim() ? JSON.parse(text) : {};
    const current = settings.statusLine;
    const ours = current && typeof current.command === 'string' && current.command.indexOf(bridge) >= 0;
    if (mode === 'install') {
        if (ours) return 'Clawd Live is already connected.';
        if (current && current.type === 'command' && current.command) write(nextPath, current.command);
        settings.statusLine = Object.assign({}, current || {}, {type: 'command', command: '"' + bridge + '"'});
        write(settingsPath, JSON.stringify(settings, null, 2) + '\n');
        return current ? 'Connected. Your previous status line still runs after the bridge.' : 'Connected.';
    }
    if (!ours) return 'Clawd Live was not connected; nothing to undo.';
    const previous = read(nextPath);
    if (previous && previous.trim()) settings.statusLine = Object.assign({}, current, {command: previous.trim()});
    else delete settings.statusLine;
    write(settingsPath, JSON.stringify(settings, null, 2) + '\n');
    return 'Disconnected. Your previous status line is restored.';
}
JS

mkdir -p "$CLAWD_DIR"
if [[ -f "$SETTINGS" ]]; then
    cp "$SETTINGS" "$SETTINGS.clawd-backup-$(date +%Y%m%d-%H%M%S)"
fi
case "$MODE" in
    install|--install)
        install -m 755 "$HERE/clawd-statusline.sh" "$BRIDGE"
        osascript -l JavaScript "$SCRIPT" install "$SETTINGS" "$BRIDGE" "$NEXT"
        echo "Limits appear after Claude Code next refreshes its status line."
        ;;
    --uninstall|uninstall)
        osascript -l JavaScript "$SCRIPT" uninstall "$SETTINGS" "$BRIDGE" "$NEXT"
        rm -f "$BRIDGE" "$NEXT" "$CLAWD_DIR/limits.json"
        rmdir "$CLAWD_DIR" 2>/dev/null || true
        ;;
    *) echo "usage: $0 [--uninstall]" >&2; exit 2 ;;
esac
