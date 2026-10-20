#!/usr/bin/env bash
# Teradata 16.20 extraction utility entrypoint. See config/utility_user_guide.txt.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_python() {
    local cand
    for cand in "${TDX_PYTHON:-}" python3.12 python3; do
        [ -n "$cand" ] || continue
        if command -v "$cand" >/dev/null 2>&1 &&
            "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
            command -v "$cand"
            return 0
        fi
    done
    return 1
}

PY="$(find_python)" || { echo "ERROR: Python >= 3.12 not found (set TDX_PYTHON)" >&2; exit 2; }

ini_value() {
    # ini_value <file> <section> <key>: prints the value, empty if absent
    awk -v sec="[$2]" -v key="$3" '
        /^[ \t]*[#;]/ { next }
        /^[ \t]*\[/ { insec = ($0 ~ "^[ \t]*\\[" substr(sec, 2, length(sec) - 2) "\\][ \t]*$"); next }
        insec { split($0, kv, "="); k = kv[1]; gsub(/^[ \t]+|[ \t]+$/, "", k)
                if (k == key) { v = substr($0, index($0, "=") + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit } }
    ' "$1"
}

CONFIG="$ROOT/config/main_config.ini"
NEEDS_TOOLS=1
prev=""
for arg in "$@"; do
    case "$arg" in
        --config=*) CONFIG="${arg#--config=}" ;;
        --status) NEEDS_TOOLS=0 ;;
    esac
    [ "$prev" = "--config" ] && CONFIG="$arg"
    prev="$arg"
done
[ -f "$CONFIG" ] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 2; }

if [ "$NEEDS_TOOLS" -eq 1 ]; then
    FEXP="${TDX_FEXP:-$(ini_value "$CONFIG" teradata fexp_path)}"
    BTEQ="${TDX_BTEQ:-$(ini_value "$CONFIG" teradata bteq_path)}"
    for tool in "${FEXP:-fexp}" "${BTEQ:-bteq}"; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "ERROR: required Teradata utility not found: $tool (install TTU or fix fexp_path/bteq_path)" >&2
            exit 2
        }
    done
fi

CFG_DIR="$(cd "$(dirname "$CONFIG")" && pwd)"
BASE="$(ini_value "$CONFIG" paths base_dir)"
BASE="${BASE:-$(dirname "$CFG_DIR")}"
case "$BASE" in /*) ;; *) BASE="$(dirname "$CFG_DIR")/$BASE" ;; esac
for key in output_dir:data metadata_dir:metadata log_dir:logs work_dir:work; do
    dir="$(ini_value "$CONFIG" paths "${key%%:*}")"
    dir="${dir:-${key##*:}}"
    case "$dir" in /*) ;; *) dir="$BASE/$dir" ;; esac
    mkdir -p "$dir"
done

umask 077
exec "$PY" "$ROOT/src/extract.py" "$@"
