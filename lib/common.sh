# shellcheck shell=bash
# Shared helpers: exit codes, logging, quoting, time, checksums, atomic writes.

TDX_EXIT_OK=0
TDX_EXIT_FAILED=1
TDX_EXIT_CONFIG=2
TDX_EXIT_INTERRUPTED=130
TDX_MASK='********'
TDX_STATE_HEADER='# THIS FILE IS MANAGED BY teradata_extract - DO NOT EDIT.
# Use --reset-table / --reset-watermark / --new-cycle to change extraction state.'
TDX_US=$'\037'

shopt -u patsub_replacement 2>/dev/null || true

TDX_THREAD=${TDX_THREAD:-MainThread}
TDX_LOG_FILE=""
TDX_VERBOSE=0

tdx_awk() { LC_ALL=C "${TDX_AWK_CMD[@]}" "$@"; }

# ------------------------------------------------------------------ errors
# A configuration/environment error ends the run with exit code 2.
tdx_config_error() {
    printf 'ERROR: %s\n' "$1" >&2
    exit "$TDX_EXIT_CONFIG"
}

# ------------------------------------------------------------------ logging
tdx_log() {
    local level=$1 msg=$2 ts line
    printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
    printf -v line '%s,000 %-7s %s %s' "$ts" "$level" "$TDX_THREAD" "$msg"
    if [[ $level != DEBUG || $TDX_VERBOSE == 1 ]]; then
        printf '%s\n' "$line" >&2
    fi
    if [[ -n $TDX_LOG_FILE ]]; then
        printf '%s\n' "$line" >>"$TDX_LOG_FILE"
    fi
}
tdx_debug() { tdx_log DEBUG "$1"; }
tdx_info() { tdx_log INFO "$1"; }
tdx_warn() { tdx_log WARNING "$1"; }
tdx_error() { tdx_log ERROR "$1"; }

# ------------------------------------------------------------------ strings
tdx_sql_str() { local v=${1//\'/\'\'}; printf "'%s'" "$v"; }
tdx_sql_ident() { local v=${1//\"/\"\"}; printf '"%s"' "$v"; }

tdx_strip() {
    local v=$1
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    printf '%s' "$v"
}

tdx_safe_name() {
    local v="$1_$2"
    v=${v//[^ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]/_}
    printf '%s' "${v,,}"
}

# Python repr()-style quoting used in error messages.
tdx_repr() { printf "'%s'" "$1"; }

# 1234567 -> 1,234,567
tdx_commas() {
    local n=$1 sign="" out=""
    [[ $n == -* ]] && { sign=-; n=${n#-}; }
    while ((${#n} > 3)); do
        out=",${n: -3}$out"
        n=${n:0:${#n}-3}
    done
    printf '%s' "$sign$n$out"
}

# Integer check in the spirit of Python int(): optional sign, digits, surrounding blanks.
tdx_is_int() { [[ $(tdx_strip "$1") =~ ^[+-]?[0-9]+$ ]]; }

# Normalized integer (no leading zeros) of a valid integer string.
tdx_int() {
    local v sign=""
    v=$(tdx_strip "$1")
    case $v in -*) sign=-; v=${v#-} ;; +*) v=${v#+} ;; esac
    v=${v#"${v%%[!0]*}"}
    [[ -z $v ]] && { printf '0'; return; }
    [[ $v == 0 ]] && sign=""
    printf '%s' "$sign$v"
}

# Python int(Decimal(v)): truncate a plain or exponent decimal number towards zero.
tdx_decint() {
    local v
    v=$(tdx_strip "$1")
    if [[ $v =~ ^[+-]?[0-9]+$ ]]; then
        tdx_int "$v"
    elif [[ $v =~ ^([+-]?)([0-9]*)\.[0-9]*$ && -n ${BASH_REMATCH[2]}${v#*.} ]]; then
        tdx_int "${BASH_REMATCH[1]}${BASH_REMATCH[2]:-0}"
    elif [[ $v =~ ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)[eE][+-]?[0-9]+$ ]]; then
        tdx_awk -v x="$v" 'BEGIN { y = x + 0; printf "%d", (y < 0 ? -int(-y) : int(y)) }'
    else
        return 1
    fi
}

# ------------------------------------------------------------------ time
tdx_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Deciseconds since the epoch (sub-second only where bash provides EPOCHREALTIME).
tdx_now_ds() {
    if [[ -n ${EPOCHREALTIME:-} ]]; then
        local t=${EPOCHREALTIME/[.,]/}
        printf '%s' $((10#$t / 100000))
    else
        printf '%s' $(($(date +%s) * 10))
    fi
}

# Deciseconds -> "12.3"
tdx_fmt_ds() { printf '%d.%d' $(($1 / 10)) $(($1 % 10)); }

# Deciseconds -> HH:MM:SS
tdx_fmt_hms() {
    local s=$((($1 + 5) / 10))
    printf '%02d:%02d:%02d' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
}

tdx_sleep() {
    local d=$1
    [[ $d == 0 || $d == 0.0 || -z $d ]] && return 0
    if [[ $TDX_FRACTIONAL_SLEEP == 1 ]]; then
        sleep "$d"
    else
        sleep "$(tdx_awk -v x="$d" 'BEGIN { i = int(x); if (i < x) i++; print i }')"
    fi
}

tdx_detect_sleep() {
    if sleep 0.01 2>/dev/null; then TDX_FRACTIONAL_SLEEP=1; else TDX_FRACTIONAL_SLEEP=0; fi
}

tdx_short_sleep() { if [[ $TDX_FRACTIONAL_SLEEP == 1 ]]; then sleep 0.05; else sleep 1; fi; }

# ------------------------------------------------------------------ checksums
tdx_detect_sha256() {
    TDX_SHA=""
    if command -v sha256sum >/dev/null 2>&1 && printf '' | sha256sum >/dev/null 2>&1; then
        TDX_SHA=sha256sum
    elif command -v shasum >/dev/null 2>&1 && printf '' | shasum -a 256 >/dev/null 2>&1; then
        TDX_SHA=shasum
    elif command -v openssl >/dev/null 2>&1 && printf '' | openssl dgst -sha256 >/dev/null 2>&1; then
        TDX_SHA=openssl
    elif command -v digest >/dev/null 2>&1 && printf '' | digest -a sha256 >/dev/null 2>&1; then
        TDX_SHA=digest
    fi
    [[ -n $TDX_SHA ]]
}

# SHA-256 (lower-case hex) of stdin.
tdx_sha256() {
    local out
    case $TDX_SHA in
        sha256sum) out=$(sha256sum) ;;
        shasum) out=$(shasum -a 256) ;;
        openssl) out=$(openssl dgst -sha256) ;;
        digest) out=$(digest -a sha256) ;;
        *) return 1 ;;
    esac || return 1
    case $TDX_SHA in
        openssl) out=${out##* } ;;
        *) out=${out%%[[:space:]]*} ;;
    esac
    printf '%s' "${out,,}"
}

tdx_sha256_file() { tdx_sha256 <"$1"; }

tdx_file_size() { local n; n=$(wc -c <"$1") || return 1; printf '%s' $((n + 0)); }

# ------------------------------------------------------------------ files
# Write stdin to $1 atomically (temp file in the same directory, then rename).
tdx_atomic_write() {
    local path=$1 dir tmp
    dir=$(dirname "$path")
    mkdir -p "$dir" || return 1
    tmp="$dir/.${path##*/}.$$.${RANDOM}.tmp"
    if cat >"$tmp" && mv -f "$tmp" "$path"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Directory lock with a pid file; a lock whose owner process is gone is removed.
tdx_lock_try() {
    local dir=$1 pid
    if mkdir "$dir" 2>/dev/null; then
        printf '%s\n' "${BASHPID:-$$}" >"$dir/pid"
        return 0
    fi
    if [[ -f $dir && ! -d $dir ]]; then
        rm -f "$dir"
        return 1
    fi
    pid=$(cat "$dir/pid" 2>/dev/null) || return 1
    if [[ -n $pid ]] && ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$dir/pid"
        rmdir "$dir" 2>/dev/null
    fi
    return 1
}

tdx_lock() { until tdx_lock_try "$1"; do tdx_short_sleep; done; }

tdx_unlock() { rm -f "$1/pid"; rmdir "$1" 2>/dev/null || true; }

# ------------------------------------------------------------------ masking
tdx_mask() {
    printf '%s\n' "$1" | TDX_MASK_PW=${TDX_PASSWORD:-} tdx_awk -f "$TDX_LIB/maskfn.awk" -f "$TDX_LIB/mask.awk"
}

tdx_mask_stream() {
    TDX_MASK_PW=${TDX_PASSWORD:-} tdx_awk -f "$TDX_LIB/maskfn.awk" -f "$TDX_LIB/mask.awk"
}
