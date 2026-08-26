#!/usr/bin/env bash
# Optimize-Media - Linux/macOS wrapper, mirrors Optimize-Media.cmd behavior.
#
#   ./Optimize-Media.sh                          -> prompts for a path
#   ./Optimize-Media.sh "path1" "path2"          -> compress multiple paths
#   ./Optimize-Media.sh "D" max                  -> second preset name is used
#
# Multiple paths are joined with '|' (the .ps1 argument channel contract),
# so any wrapper change must stay in sync with Optimize-Media.cmd.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRESET="balanced"
ARGS=""
USEPRESET=0

case "${2:-}" in
    fast|balanced|max|archive) USEPRESET=1 ;;
esac

collect() {
    local a
    for a in "$@"; do
        [ -z "$a" ] && continue
        ARGS="${ARGS:+$ARGS|}$a"
    done
}

if [ "$USEPRESET" = "1" ]; then
    PRESET="$2"
    collect "${1:-}"
    shift 2 2>/dev/null || true
fi
collect "$@"

if [ -z "$ARGS" ]; then
    echo
    echo "  Usage:"
    echo "    1. ./Optimize-Media.sh <path> [preset]"
    echo "    2. Or run without arguments and paste one or more paths"
    echo
    echo "  Presets: fast | balanced (default) | max | archive"
    echo
    read -r -p "Enter path(s) (folder or file): " TARGET
    ARGS="${TARGET:-}"
fi

exec pwsh -NoProfile -File "$DIR/Optimize-Media.ps1" -Path "$ARGS" -Preset "$PRESET"
