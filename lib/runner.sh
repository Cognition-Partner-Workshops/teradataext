# shellcheck shell=bash
# fexp/bteq scripts and execution, raw export decoding, internal BTEQ queries.

tdx_logon_lines() {
    [[ -n $S_logmech ]] && printf '.LOGMECH %s;\n' "$S_logmech"
    printf '.LOGON %s/%s,%s;\n' "$S_host" "$TDX_USER" "$TDX_PASSWORD"
}

# tdx_bteq_script SQL1 OUT1 [SQL2 OUT2 ...] -> REPLY
tdx_bteq_script() {
    local s sql
    s=".SET SESSION CHARSET '$S_session_charset';"$'\n'"$(tdx_logon_lines)"$'\n'
    s+=".SET ERROROUT STDOUT;"$'\n'".SET ERRORLEVEL UNKNOWN SEVERITY 8;"$'\n'
    while (($# >= 2)); do
        sql=$(tdx_sql_stmt "$1")
        s+=".EXPORT DATA FILE = $2;"$'\n'"$sql;"$'\n'".IF ERRORCODE <> 0 THEN .QUIT 8;"$'\n'".EXPORT RESET;"$'\n'
        shift 2
    done
    s+=".LOGOFF;"$'\n'".QUIT 0;"$'\n'
    REPLY=$s
}

# SQL without trailing blanks/semicolons (Python: sql.rstrip().rstrip(";"))
tdx_sql_stmt() {
    local v=$1
    v=${v%"${v##*[![:space:]]}"}
    while [[ $v == *";" ]]; do v=${v%;}; done
    printf '%s' "$v"
}

# Best effort: drop the restart log table a failed FastExport leaves behind (every attempt has
# its own name, so it would never be reused). Keeps TDX_TOOL_ERR/TDX_TOOL_SL of the failure.
tdx_drop_logtable() {
    local lt=$1 name=$2 err=$TDX_TOOL_ERR sl=$TDX_TOOL_SL s
    s=".SET SESSION CHARSET '$S_session_charset';"$'\n'"$(tdx_logon_lines)"$'\n'
    s+="DROP TABLE $lt;"$'\n'".LOGOFF;"$'\n'".QUIT 0;"$'\n'
    tdx_run_tool bteq "$name.droplt" "$s" 1 || tdx_warn "$name: could not drop FastExport log table $lt; drop it by hand"
    TDX_TOOL_ERR=$err
    TDX_TOOL_SL=$sl
}

tdx_fexp_script() {
    local sql=$1 out=$2 sessions=$3 job_id=$4 lt h
    h=$(printf '%s' "$job_id" | tdx_sha256)
    lt="tdx_lt_${h:0:12}"
    [[ -n $S_logtable_database ]] && lt="$(tdx_sql_ident "$S_logtable_database").$lt"
    TDX_FEXP_LT=$lt
    REPLY=".LOGTABLE $lt;"$'\n'"$(tdx_logon_lines)"$'\n'
    REPLY+=".BEGIN EXPORT SESSIONS $sessions TENACITY 0;"$'\n'
    REPLY+=".EXPORT OUTFILE $out FORMAT TEXT MODE RECORD;"$'\n'
    REPLY+="$(tdx_sql_stmt "$sql");"$'\n'".END EXPORT;"$'\n'".LOGOFF;"$'\n'
}

# Session budget shared by all jobs of this run (Python SessionPool).
tdx_sessions_hold() {
    local n=$1 used
    ((n > S_max_sessions)) && n=$S_max_sessions
    ((n < 1)) && n=1
    while :; do
        tdx_lock "$TDX_RUNDIR/sessions.lock"
        used=$(cat "$TDX_RUNDIR/sessions" 2>/dev/null)
        used=${used:-0}
        if ((used + n <= S_max_sessions)); then
            printf '%s\n' $((used + n)) >"$TDX_RUNDIR/sessions"
            tdx_unlock "$TDX_RUNDIR/sessions.lock"
            TDX_HELD=$n
            return 0
        fi
        tdx_unlock "$TDX_RUNDIR/sessions.lock"
        tdx_short_sleep
    done
}

tdx_sessions_release() {
    local used
    tdx_lock "$TDX_RUNDIR/sessions.lock"
    used=$(cat "$TDX_RUNDIR/sessions" 2>/dev/null)
    used=$((${used:-0} - TDX_HELD))
    ((used < 0)) && used=0
    printf '%s\n' "$used" >"$TDX_RUNDIR/sessions"
    tdx_unlock "$TDX_RUNDIR/sessions.lock"
    TDX_HELD=0
}

# tdx_run_tool TOOL NAME SCRIPT [SESSIONS]
# 0: ok (TDX_ROWS_FEXP / TDX_ROWS_BTEQ set from the unmasked output, which is never written).
# 1: failed; TDX_TOOL_ERR = message, TDX_TOOL_SL = 1 when it was a session-limit failure.
tdx_run_tool() {
    local tool=$1 name=$2 script=$3 sessions=${4:-1} exe log body info fifo tofile
    local tpid apid wpid="" rc started line k v
    local -a cmd
    TDX_TOOL_ERR=""
    TDX_TOOL_SL=0
    TDX_ROWS_FEXP=""
    TDX_ROWS_BTEQ=""
    [[ $tool == fexp ]] && exe=$S_fexp_path || exe=$S_bteq_path
    cmd=("$exe")
    [[ $tool == fexp && $S_session_charset == UTF8 ]] && cmd+=(-c UTF8)
    printf '%s' "$script" | tdx_mask_stream | tdx_atomic_write "$S_work_dir/$name.$tool"
    log="$S_log_dir/$name.$tool.log"
    local tag="${BASHPID:-$$}.$RANDOM"
    body="$TDX_RUNDIR/$tag.body"
    info="$TDX_RUNDIR/$tag.info"
    fifo="$TDX_RUNDIR/$tag.fifo"
    tofile="$TDX_RUNDIR/$tag.timeout"
    started=$(tdx_now_ds)
    tdx_sessions_hold "$sessions"
    tdx_debug "running $tool for $name ($sessions session(s))"
    mkfifo "$fifo" || { tdx_sessions_release; TDX_TOOL_ERR="cannot create $fifo"; return 1; }
    TDX_MASK_PW=$TDX_PASSWORD TDX_SL_CODES=$S_session_limit_errors TDX_SL_PATTERNS=$S_session_limit_patterns \
        LC_ALL=C "${TDX_AWK_CMD[@]}" -v mode="$S_log_tool_output" -v body="$body" \
        -f "$TDX_LIB/maskfn.awk" -f "$TDX_LIB/toolout.awk" <"$fifo" >"$info" &
    apid=$!
    (cd "$S_work_dir" && exec "${cmd[@]}") < <(printf '%s' "$script") >"$fifo" 2>&1 &
    tpid=$!
    TDX_CHILD_PIDS="$tpid $apid"
    if ((S_job_timeout_seconds > 0)); then
        (
            i=0
            while kill -0 "$tpid" 2>/dev/null; do
                if ((i >= S_job_timeout_seconds)); then
                    : >"$tofile"
                    kill -9 "$tpid" 2>/dev/null
                    break
                fi
                sleep 1
                i=$((i + 1))
            done
        ) &
        wpid=$!
        TDX_CHILD_PIDS+=" $wpid"
    fi
    wait "$tpid"
    rc=$?
    wait "$apid"
    if [[ -n $wpid ]]; then
        kill "$wpid" 2>/dev/null
        wait "$wpid" 2>/dev/null
    fi
    TDX_CHILD_PIDS=""
    tdx_sessions_release
    rm -f "$fifo"
    local fexp_rows="" bteq_rows="" bteq_fail=0 sl=0 err_code="" err_line=""
    while IFS= read -r line; do
        k=${line%%=*}
        v=${line#*=}
        case $k in
            fexp_rows) fexp_rows=$v ;;
            bteq_rows) bteq_rows=$v ;;
            bteq_fail) bteq_fail=$v ;;
            session_limit) sl=$v ;;
            err_code) err_code=$v ;;
            err_line) err_line=$v ;;
        esac
    done <"$info"
    local rcs=$rc
    [[ -f $tofile ]] && rcs=None
    {
        printf '===== %s %s sessions=%s rc=%s elapsed=%ss\n' "$(tdx_iso_now)" "$tool" "$sessions" "$rcs" \
            "$(tdx_fmt_ds $(($(tdx_now_ds) - started)))"
        cat "$body" 2>/dev/null
        printf '\n'
    } >>"$log"
    rm -f "$body" "$info"
    if [[ -f $tofile ]]; then
        rm -f "$tofile"
        TDX_TOOL_ERR="$tool timed out after ${S_job_timeout_seconds}s (${log##*/})"
        return 1
    fi
    if ((rc != 0)) || [[ $tool == bteq && $bteq_fail == 1 ]]; then
        local first
        if [[ $S_log_tool_output == none ]]; then
            [[ -n $err_code ]] && first="Teradata error $err_code" || first="exit code $rc"
        else
            first=${err_line:-exit code $rc}
        fi
        TDX_TOOL_ERR="$tool failed (rc=$rc): $first (see ${log##*/})"
        TDX_TOOL_SL=$sl
        return 1
    fi
    TDX_ROWS_FEXP=$fexp_rows
    TDX_ROWS_BTEQ=$bteq_rows
    return 0
}

# Byte value of a single character.
tdx_byte() { LC_ALL=C printf '%d' "'$1"; }

# 1 when this host stores integers big-endian (AIX, Solaris SPARC); fexp/bteq write the record
# and VARCHAR lengths in the host's byte order. TDX_HOST_BE may be preset (tests).
tdx_host_be() {
    local v
    if [[ -z ${TDX_HOST_BE:-} ]]; then
        v=$(printf '\001\000' | od -An -tu2)
        v=${v//[[:space:]]/}
        if [[ $v == 256 ]]; then TDX_HOST_BE=1; else TDX_HOST_BE=0; fi
    fi
    REPLY=$TDX_HOST_BE
}

# tdx_decode_raw RAW OUT TOOL WANT LIMIT UTF8 DELIM ESC
# 0: decoded (TDX_DEC_N records, TDX_DEC_LAYOUT); 1: no layout fits; 2: record error (TDX_DEC_ERR).
tdx_decode_raw() {
    local raw=$1 out=$2 tool=$3 want=$4 limit=$5 utf8=$6 delim=$7 esc=$8 res lay rp eor be p
    TDX_DEC_N=0
    TDX_DEC_LAYOUT=""
    TDX_DEC_ERR=""
    if [[ ! -s $raw ]]; then
        : >"$out"
        TDX_DEC_LAYOUT=empty
        return 0
    fi
    local -a order
    if [[ $tool == bteq ]]; then order=(11 01 10 00); else order=(01 11 10 00); fi
    tdx_host_be
    order=("${order[@]/%/$REPLY}" "${order[@]/%/$((1 - REPLY))}")
    res="$TDX_RUNDIR/dec.${BASHPID:-$$}.$RANDOM"
    for lay in "${order[@]}"; do
        rp=${lay:0:1}
        eor=${lay:1:1}
        be=${lay:2:1}
        od -An -v -tu1 "$raw" | tdx_awk -v rec_prefix="$rp" -v eor="$eor" -v be="$be" -v want="$want" -v limit="$limit" \
            -v utf8="$utf8" -v delim="$delim" -v esc="$esc" -v out="$out" -f "$TDX_LIB/rawdecode.awk" >"$res" &
        p=$!
        TDX_CHILD_PIDS=$p
        wait "$p"
        TDX_CHILD_PIDS=""
        read -r a b <"$res"
        case $a in
            OK)
                rm -f "$res"
                TDX_DEC_N=$b
                TDX_DEC_LAYOUT=""
                [[ $rp == 1 ]] && TDX_DEC_LAYOUT="reclen+"
                TDX_DEC_LAYOUT+="varchar"
                [[ $eor == 1 ]] && TDX_DEC_LAYOUT+="+eor"
                [[ $be == 1 ]] && TDX_DEC_LAYOUT+="+big-endian"
                return 0
                ;;
            ERROR)
                rm -f "$res"
                TDX_DEC_ERR=$b
                return 2
                ;;
        esac
    done
    rm -f "$res" "$out"
    return 1
}

# tdx_query NAME SQL... : marked SELECTs (one VARCHAR each) through one BTEQ logon.
# Results: TDX_QDIR/r<i> row files (see fields.awk). Exits the job on failure.
tdx_query() {
    local name=$1 i n attempt=0 raw
    shift
    n=$#
    local -a args=()
    for ((i = 1; i <= n; i++)); do
        raw="$S_work_dir/$name.q$i.raw"
        rm -f "$raw"
        args+=("${!i}" "$raw")
    done
    tdx_bteq_script "${args[@]}"
    local script=$REPLY
    while :; do
        if tdx_run_tool bteq "$name" "$script" 1; then
            break
        fi
        if [[ $TDX_TOOL_SL == 1 ]] && ((attempt < S_retry_attempts)); then
            attempt=$((attempt + 1))
            tdx_warn "$name: session limit, retry $attempt in ${S_retry_delay_seconds}s"
            tdx_sleep "$S_retry_delay_seconds"
            continue
        fi
        tdx_fail "$TDX_TOOL_ERR"
    done
    TDX_QDIR="$TDX_RUNDIR/q.${BASHPID:-$$}"
    rm -rf "$TDX_QDIR"
    mkdir -p "$TDX_QDIR"
    for ((i = 1; i <= n; i++)); do
        raw="$S_work_dir/$name.q$i.raw"
        tdx_decode_raw "$raw" "$TDX_QDIR/d$i" bteq 0 0 0 124 92
        case $? in
            1) tdx_fail "raw export file does not match any known record layout" ;;
            2) tdx_fail "$name: query $i: record ${TDX_DEC_ERR#* } contains a NUL byte" ;;
        esac
        tdx_awk -f "$TDX_LIB/fields.awk" "$TDX_QDIR/d$i" >"$TDX_QDIR/r$i"
        rm -f "$raw" "$TDX_QDIR/d$i"
    done
}

# Load a query row file into QV["row,field"] (QNULL marks NULLs), QNF[row], QROWS.
declare -gA QV=() QNULL=() QNF=()
tdx_rows_load() {
    local line r=0 f=0
    QV=()
    QNULL=()
    QNF=()
    while IFS= read -r line; do
        case $line in
            R*) r=$((r + 1)); f=0; QNF[$r]=${line#R} ;;
            N) QNULL["$r,$f"]=1; QV["$r,$f"]=""; f=$((f + 1)) ;;
            V*) QV["$r,$f"]=${line#V}; f=$((f + 1)) ;;
        esac
    done <"$1"
    QROWS=$r
}
