#!/usr/bin/env bash
# Teradata 16.20 extraction utility entrypoint (bash + POSIX awk). See config/utility_user_guide.txt.
set -uo pipefail

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
    { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    echo "ERROR: bash >= 4.2 is required (found ${BASH_VERSION:-unknown})" >&2
    exit 2
fi

TDX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TDX_LIB="$TDX_ROOT/lib"

# TDX_AWK may hold a command with arguments, e.g. "busybox awk".
if [ -n "${TDX_AWK:-}" ]; then
    read -r -a TDX_AWK_CMD <<<"$TDX_AWK"
elif [ "$(uname -s 2>/dev/null)" = SunOS ] && [ -x /usr/xpg4/bin/awk ]; then
    TDX_AWK_CMD=(/usr/xpg4/bin/awk)
else
    TDX_AWK_CMD=(awk)
fi
command -v "${TDX_AWK_CMD[0]}" >/dev/null 2>&1 || { echo "ERROR: awk not found: ${TDX_AWK_CMD[0]} (set TDX_AWK)" >&2; exit 2; }

for f in common config creds state runner types plan extract finalize main; do
    # shellcheck disable=SC1090
    . "$TDX_LIB/$f.sh"
done

CONFIG="$TDX_ROOT/config/main_config.ini"
NEEDS_TOOLS=1
prev=""
for arg in "$@"; do
    case "$arg" in
        --config=*) CONFIG="${arg#--config=}" ;;
        --status) NEEDS_TOOLS=0 ;;
        -h | --help) NEEDS_TOOLS=0 ;;
    esac
    [ "$prev" = "--config" ] && CONFIG="$arg"
    prev="$arg"
done
case " $* " in *" -h "* | *" --help "*) tdx_main "$@" ;; esac
[ -f "$CONFIG" ] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 2; }

ini_value() {
    # ini_value <file> <section> <key>: prints the value, empty if absent
    TDX_SEC=$2 TDX_KEY=$3 LC_ALL=C "${TDX_AWK_CMD[@]}" '
        BEGIN { sec = ENVIRON["TDX_SEC"]; key = ENVIRON["TDX_KEY"] }
        /^[ \t]*[#;]/ { next }
        /^[ \t]*\[/ { s = $0; sub(/^[ \t]*\[/, "", s); sub(/\][ \t]*$/, "", s); insec = (s == sec); next }
        insec { k = $0; sub("=.*", "", k); gsub(/^[ \t]+|[ \t]+$/, "", k)
                if (k == key) { v = substr($0, index($0, "=") + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit } }
    ' "$1"
}

for tool in od; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required command not found: $tool" >&2; exit 2; }
done
if [ "$NEEDS_TOOLS" -eq 1 ]; then
    FEXP="${TDX_FEXP:-$(ini_value "$CONFIG" teradata fexp_path)}"
    BTEQ="${TDX_BTEQ:-$(ini_value "$CONFIG" teradata bteq_path)}"
    for tool in "${FEXP:-fexp}" "${BTEQ:-bteq}"; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "ERROR: required Teradata utility not found: $tool (install TTU or fix fexp_path/bteq_path)" >&2
            exit 2
        }
    done
    for tool in gzip tar mkfifo; do
        command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required command not found: $tool" >&2; exit 2; }
    done
    tdx_detect_sha256 || {
        echo "ERROR: no SHA-256 tool found (need sha256sum, shasum, openssl or digest)" >&2
        exit 2
    }
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
tdx_main "$@"
