# Shared implementation of the fake fexp/bteq (see README.md). Sourced by ./fexp and ./bteq
# with TDXFAKE_TOOL set. Bash + awk only; awk is ${TDX_AWK:-awk}.
export LC_ALL=C
TDXFAKE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TDXFAKE_AWK=${TDX_AWK:-awk}

tdxf_lock() {   # mkdir-based mutex: tdxf_lock DIR
    local n=0 pid
    while ! mkdir "$1" 2>/dev/null; do
        n=$((n + 1))
        if [ $((n % 200)) -eq 0 ] && IFS= read -r pid <"$1/pid" 2>/dev/null && [ -n "$pid" ] \
            && ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$1"
            continue
        fi
        sleep 0.01 2>/dev/null || sleep 1
    done
    echo "$$" >"$1/pid"
}
tdxf_unlock() { rm -rf "$1"; }

# Failure counters live next to the fixture in "<fixture>.state", one "<idx> <used>" per line.
tdxf_consume() {   # tdxf_consume IDX TIMES -> 0 if the failure fires (counter incremented)
    local st="$TDX_FAKE_FIXTURE.state" i u used=0 rc=0 out=""
    tdxf_lock "$st.lock"
    if [ -f "$st" ]; then
        while read -r i u; do
            if [ "$i" = "$1" ]; then used=$u; else out+="$i $u"$'\n'; fi
        done <"$st"
    fi
    if [ "$2" -ge 0 ] && [ "$used" -ge "$2" ]; then
        rc=1
    else
        printf '%s%s %s\n' "$out" "$1" "$((used + 1))" >"$st.tmp.$$" && mv -f "$st.tmp.$$" "$st"
    fi
    tdxf_unlock "$st.lock"
    return "$rc"
}

tdxf_log() {   # append one call record to $TDX_FAKE_LOG
    local entry="" a l n=0 nl=yes
    for a in "$@"; do entry+="@argv $a"$'\n'; done
    while IFS= read -r l || { [ -n "$l" ] && nl=no; }; do
        entry+=">$l"$'\n'; n=$((n + 1))
    done <"$TDXFAKE_SCRIPT"
    [ -s "$TDXFAKE_SCRIPT" ] || nl=no
    tdxf_lock "$TDX_FAKE_LOG.lock"
    printf '@call tool=%s pid=%s time=%s argc=%s lines=%s final_newline=%s\n%s@end\n' \
        "$TDXFAKE_TOOL" "$$" "$(date +%s)" "$#" "$n" "$nl" "$entry" >>"$TDX_FAKE_LOG"
    tdxf_unlock "$TDX_FAKE_LOG.lock"
}

tdxf_report() {
    if [ "$TDXFAKE_TOOL" = fexp ]; then
        printf '**** 12:00:00 UTY8722 %s total records written to output file.\n' "$1"
    elif [ "$1" -eq 1 ]; then
        printf '*** Query completed. One row found. One column returned.\n'
    elif [ "$1" -gt 0 ]; then
        printf '*** Query completed. %s rows found. 1 column returned.\n' "$1"
    else
        printf '*** Query completed. No rows found.\n'
    fi
}

tdxf_main() {
    local exit_fail=8 banner="BTEQ (fake)" line f rest idx times code msg key path open=0 kind
    local -A written=()
    if [ "$TDXFAKE_TOOL" = fexp ]; then exit_fail=12; banner="FastExport Utility (fake)"; fi
    TDXFAKE_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/tdxfake.XXXXXX") || return "$exit_fail"
    TDXFAKE_PLAN="$TDXFAKE_SCRIPT.plan"
    trap 'rm -f "$TDXFAKE_SCRIPT" "$TDXFAKE_PLAN"' EXIT
    cat >"$TDXFAKE_SCRIPT"
    [ -n "${TDX_FAKE_LOG:-}" ] && tdxf_log "$@"
    printf '     %s  Release 16.20.00.00\n' "$banner"
    if [ "$("$TDXFAKE_AWK" -v mode=logon -v script="$TDXFAKE_SCRIPT" -f "$TDXFAKE_DIR/_tdxfake.awk")" != 1 ]; then
        printf '*** Error: no .LOGON host/user,password command found in script.\n'
        return 12
    fi
    printf '*** Logon successfully completed.\n'
    if [ -z "${TDX_FAKE_FIXTURE:-}" ]; then
        printf '*** Error: TDX_FAKE_FIXTURE is not set.\n'
        return "$exit_fail"
    fi
    local be=0
    [ "${TDX_FAKE_ENDIAN:-}" = big ] && be=1
    "$TDXFAKE_AWK" -v mode=plan -v tool="$TDXFAKE_TOOL" -v be="$be" -v fixture="$TDX_FAKE_FIXTURE" \
        -v script="$TDXFAKE_SCRIPT" -f "$TDXFAKE_DIR/_tdxfake.awk" >"$TDXFAKE_PLAN" || return "$exit_fail"
    while IFS= read -r line; do
        f=${line%%$'\t'*}; rest=${line#*$'\t'}
        case $f in
        REQ) printf -v key -- "$rest" ;;
        FAIL)
            idx=${rest%%$'\t'*}; rest=${rest#*$'\t'}
            times=${rest%%$'\t'*}; rest=${rest#*$'\t'}
            printf -v code -- "${rest%%$'\t'*}"; printf -v msg -- "${rest#*$'\t'}"
            if tdxf_consume "$idx" "$times"; then
                printf '*** Failure %s %s.\n' "$code" "$msg"
                return "$exit_fail"
            fi ;;
        SQLERR)
            printf -v msg -- "$rest"
            printf '*** Failure %s %s.\n' "${msg%%$'\t'*}" "${msg#*$'\t'}"
            return "$exit_fail" ;;
        MISSING)
            printf "*** Failure 3807 Object '%s' does not exist.\n" "$key"
            return "$exit_fail" ;;
        UNKNOWN)
            [ "$line" = UNKNOWN ] && rest=""
            printf -v kind -- "$rest"
            printf "*** Failure 3706 Syntax error: unknown TDX query kind '%s'.\n" "$kind"
            return "$exit_fail" ;;
        OPEN)
            printf -v path -- "$rest"
            if [ -n "${written[$path]:-}" ]; then exec 3>>"$path"; else exec 3>"$path"; fi || return "$exit_fail"
            written[$path]=1; open=1 ;;
        REC)
            if [ "$open" = 1 ]; then printf -- "$rest" >&3; fi ;;
        END)
            if [ "$open" = 1 ]; then exec 3>&-; open=0; fi
            tdxf_report "$rest" ;;
        esac
    done <"$TDXFAKE_PLAN"
    printf '*** Logoff completed.\n'
    return 0
}

tdxf_main "$@"
exit $?
