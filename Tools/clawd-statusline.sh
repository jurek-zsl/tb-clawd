#!/bin/bash
# Claude Code status line bridge for the Clawd Live Touch Bar widget.
#
# Claude Code pipes a JSON payload to the status line command whenever the
# status line updates. When that payload carries `rate_limits` (Claude.ai
# plans: 5-hour and 7-day windows), this saves it where Clawd Live reads it,
# then hands the same payload to the status line you had before, if any.
set -u
umask 077
DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/clawd"
mkdir -p "$DIR"
INPUT="$(cat)"
case "$INPUT" in
    *'"rate_limits"'*)
        TMP="$DIR/.limits.$$"
        printf '%s\n' "$INPUT" > "$TMP" && mv -f "$TMP" "$DIR/limits.json"
        ;;
esac
NEXT="$DIR/next-statusline"
if [[ -s "$NEXT" ]]; then
    printf '%s' "$INPUT" | /bin/sh -c "$(cat "$NEXT")"
fi
