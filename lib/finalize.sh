# shellcheck shell=bash
# Table completion (archive, state, audit), status listing and the executive summary.

# tdx_audit KEY STATUS ROWS FILES CHUNKS METHOD ELAPSED_DS WATERMARK MSG
tdx_audit() {
    local msg
    msg=$(tdx_mask "$9")
    msg=${msg//$'\n'/ }
    mkdir -p "$(dirname "$S_audit_file")"
    printf '%s | %s | %s | %s | rows=%s | files=%s | chunks=%s | method=%s | elapsed=%ss | watermark=%s | %s\n' \
        "$(tdx_iso_now)" "$TDX_RUN_ID" "$1" "$2" "$3" "$4" "$5" "${6:--}" "$(tdx_fmt_ds "$7")" "${8:--}" "$msg" \
        >>"$S_audit_file"
}

tdx_audit_skipped() {
    local rows method
    tdx_state_get "$1" rows_exported 0
    tdx_int_or0 "$REPLY" || REPLY=0
    rows=$REPLY
    tdx_state_get "$1" method
    method=$REPLY
    tdx_audit "$1" skipped "$rows" 0 - "$method" 0 "" "already done in this cycle"
}

# Archive member names (sorted, without a leading ./)
tdx_archive_members() {
    gzip -dc "$1" 2>/dev/null | tar tf - 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort
}

# tdx_archive ARCHIVE FILE... (files are names inside S_output_dir) -> REPLY = sha256
tdx_archive() {
    local arch=$1 tmp="$1.tmp" expect got
    shift
    rm -f "$tmp"
    (cd "$S_output_dir" && tar cf - "$@") | gzip -c >"$tmp"
    local -a pst=("${PIPESTATUS[@]}")
    if ((pst[0] != 0 || pst[1] != 0)); then
        rm -f "$tmp"
        TDX_ERR="cannot create archive ${arch##*/}"
        return 1
    fi
    if ! gzip -t "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        TDX_ERR="archive integrity test failed for ${arch##*/} (gzip -t)"
        return 1
    fi
    expect=$(printf '%s\n' "$@" | LC_ALL=C sort)
    got=$(tdx_archive_members "$tmp")
    if [[ $got != "$expect" ]]; then
        rm -f "$tmp"
        TDX_ERR="archive member list mismatch for ${arch##*/}"
        return 1
    fi
    # Content check, one member at a time (bounded extra disk): each must equal its .dat file.
    local vdir="$TDX_RUNDIR/verify.${BASHPID:-$$}" f ok=1
    for f; do
        rm -rf "$vdir"
        mkdir -p "$vdir" || { ok=0; break; }
        if ! gzip -dc "$tmp" | (cd "$vdir" && tar xf - "$f") || ! cmp -s "$vdir/$f" "$S_output_dir/$f"; then
            ok=0
            break
        fi
    done
    rm -rf "$vdir"
    if ((ok == 0)); then
        rm -f "$tmp"
        TDX_ERR="archive content check failed for ${arch##*/} (member $f)"
        return 1
    fi
    mv -f "$tmp" "$arch" || { TDX_ERR="cannot rename $tmp"; return 1; }
    REPLY=$(tdx_sha256_file "$arch")
}

# True when a previous attempt already wrote and recorded this cycle's verified archive.
tdx_archive_still_valid() {
    local arch=$1 name=$2 sha=$3 f members
    shift 3
    [[ ${ST_SEC[zip_file]:-} == "$name" && -n $sha && -f $arch ]] || return 1
    [[ $(tdx_sha256_file "$arch") == "$sha" ]] || return 1
    gzip -t "$arch" 2>/dev/null || return 1
    members=$'\n'$(tdx_archive_members "$arch")$'\n'
    for f; do [[ $members == *$'\n'"$f"$'\n'* ]] || return 1; done
}

declare -gA RESULTS=() FAILURES=() TERR=() W_STARTED=()
declare -ga FAIL_ORDER=()
TDX_ROWS_TOTAL=0
TDX_DAT_FILES=0
TDX_ZIP_FILES=0

tdx_load_info() {
    local key=$1 file="$TDX_RUNDIR/$(tdx_table_base "$1").info" line
    WI_cdc_from=""
    WI_cdc_to=""
    WI_no_new_rows=0
    WI_pending=""
    [[ -f $file ]] || return 0
    while IFS= read -r line; do
        case ${line%%"$TDX_US"*} in
            cdc_from) WI_cdc_from=${line#*"$TDX_US"} ;;
            cdc_to) WI_cdc_to=${line#*"$TDX_US"} ;;
            no_new_rows) WI_no_new_rows=${line#*"$TDX_US"} ;;
            pending) WI_pending=${line#*"$TDX_US"} ;;
        esac
    done <"$file"
}

tdx_wm_text() {
    local key=$1 status=$2 to
    REPLY=""
    [[ -n ${T_CDC[$key]} ]] || return 0
    if [[ $status == "done" ]]; then to=$WI_cdc_to; else to=$WI_cdc_from; fi
    REPLY="${WI_cdc_from:--}->${to:--}"
}

# 0 when the table was recorded (done or failed); 1 + TDX_ERR when finishing it failed.
tdx_finalize() {
    local key=$1 base elapsed sec err i
    base=$(tdx_table_base "$key")
    elapsed=$(($(tdx_now_ds) - ${W_STARTED[$key]:-$(tdx_now_ds)}))
    tdx_load_info "$key"
    tdx_state_section "$key"
    local -A st=()
    for i in "${!ST_SEC[@]}"; do st[$i]=${ST_SEC[$i]}; done
    local -a secs=()
    while IFS= read -r sec; do [[ -n $sec ]] && secs+=("$sec"); done < <(tdx_state_chunk_sections "$key")
    if [[ -n ${TERR[$key]:-} ]]; then
        err=$(tdx_mask "${TERR[$key]}")
        err=${err:0:2000}
        tdx_state_update "$key" status=failed last_error="$err" finished_at="$(tdx_iso_now)" \
            elapsed_seconds="$(tdx_fmt_ds "$elapsed")"
        FAILURES[$key]=$err
        FAIL_ORDER+=("$key")
        local done_n=0
        for sec in "${secs[@]}"; do
            tdx_state_get "$sec" status
            [[ $REPLY == "done" ]] && done_n=$((done_n + 1))
        done
        tdx_wm_text "$key" failed
        tdx_audit "$key" failed 0 0 "$done_n/${#secs[@]}" "${st[method]:-}" "$elapsed" "$REPLY" "$err"
        RESULTS[$key]=failed
        tdx_error "$key FAILED: $err"
        return 0
    fi
    local -a files=()
    local rows=0 sums="" methods="" m method
    for sec in "${secs[@]}"; do
        tdx_state_section "$sec"
        files+=("${ST_SEC[file]}")
        tdx_int_or0 "${ST_SEC[rows]:-}" || REPLY=0
        rows=$((rows + REPLY))
        sums+="${sums:+$'\n'}${ST_SEC[sha256]:-}"
        m=${ST_SEC[method]:-}
        [[ " $methods " == *" $m "* ]] || methods+="${methods:+ }$m"
    done
    if [[ -z $methods ]] && ((${#secs[@]} == 0)); then
        method=none
    elif [[ $methods == *" "* ]]; then
        method=mixed
    else
        method=$methods
    fi
    local checksum=""
    ((${#secs[@]})) && checksum=$(printf '%s' "$sums" | tdx_sha256)
    local files_list
    files_list=$(IFS=,; printf '%s' "${files[*]}")
    local -a upd=(rows_exported=$rows files="$files_list" checksum_sha256="$checksum" method="$method")
    if ((${#files[@]})) && [[ $S_zip_on_complete == 1 ]]; then
        local cyc name arch zsha missing=""
        tdx_state_get _run cycle_id
        cyc=$REPLY
        name="${base}_$cyc.tar.gz"
        arch="$S_output_dir/$name"
        ST_SEC=()
        for i in "${!st[@]}"; do ST_SEC[$i]=${st[$i]}; done
        if tdx_archive_still_valid "$arch" "$name" "${st[zip_sha256]:-}" "${files[@]}"; then
            zsha=${st[zip_sha256]}
        else
            for i in "${files[@]}"; do [[ -e $S_output_dir/$i ]] || missing+="${missing:+, }$i"; done
            if [[ -n $missing ]]; then
                TDX_ERR="data files missing before archiving: $missing"
                return 1
            fi
            tdx_archive "$arch" "${files[@]}" || return 1
            zsha=$REPLY
            tdx_state_update "$key" zip_file="$name" zip_sha256="$zsha"
        fi
        upd+=(zip_file="$name" zip_sha256="$zsha")
        TDX_ZIP_FILES=$((TDX_ZIP_FILES + 1))
        if [[ $S_keep_raw_after_zip != 1 ]]; then
            for i in "${files[@]}"; do rm -f "$S_output_dir/$i"; done
        fi
    fi
    TDX_DAT_FILES=$((TDX_DAT_FILES + ${#files[@]}))
    if [[ -n ${T_CDC[$key]} ]]; then
        [[ -n $WI_cdc_to ]] && upd+=(watermark="$WI_cdc_to")
        upd+=(-pending_watermark)
    fi
    upd+=(status=done finished_at="$(tdx_iso_now)" elapsed_seconds="$(tdx_fmt_ds "$elapsed")" -last_error)
    tdx_state_update "$key" "${upd[@]}"
    TDX_ROWS_TOTAL=$((TDX_ROWS_TOTAL + rows))
    RESULTS[$key]="done"
    tdx_wm_text "$key" "done"
    local msg=ok
    [[ $WI_no_new_rows == 1 ]] && msg="no new CDC rows"
    tdx_audit "$key" "done" "$rows" "${#files[@]}" "${#secs[@]}/${#secs[@]}" "$method" "$elapsed" "$REPLY" "$msg"
    tdx_info "$key done: $rows rows, ${#files[@]} file(s)"
}

tdx_safe_finalize() {
    tdx_finalize "$1" && return 0
    TERR[$1]+="${TERR[$1]:+; }$(tdx_mask "$TDX_ERR")"
    tdx_finalize "$1"
}

tdx_print_status() {
    local key done_n chunks extra rows status
    printf 'State file : %s\n' "$TDX_STATE_REAL"
    tdx_state_get _run cycle_id
    printf 'Cycle id   : %s\n' "${REPLY:--}"
    tdx_state_get _run last_run_id
    printf 'Last run   : %s\n' "${REPLY:--}"
    printf '%-40s %-12s %-9s %14s  WATERMARK / ERROR\n' TABLE STATUS CHUNKS ROWS
    for key in "${T_KEYS[@]}"; do
        tdx_state_section "$key"
        done_n=0
        local IFS=,
        for chunks in ${ST_SEC[chunks_done]:-}; do [[ -n $chunks ]] && done_n=$((done_n + 1)); done
        unset IFS
        chunks="$done_n/${ST_SEC[chunk_count]:--}"
        status=${ST_SEC[status]:-pending}
        if [[ $status == failed ]]; then extra=${ST_SEC[last_error]:-}; else extra=${ST_SEC[watermark]:-}; fi
        tdx_int_or0 "${ST_SEC[rows_exported]:-}" || REPLY=0
        rows=$(tdx_commas "$REPLY")
        printf '%-40s %-12s %-9s %14s  %s\n' "$key" "$status" "$chunks" "$rows" "$extra"
    done
}

tdx_summary() {
    local queued=$1 skipped=$2 started=$3 done_n=0 failed=0 k
    for k in "${!RESULTS[@]}"; do
        [[ ${RESULTS[$k]} == "done" ]] && done_n=$((done_n + 1))
        [[ ${RESULTS[$k]} == failed ]] && failed=$((failed + 1))
    done
    printf '%s TERADATA EXTRACT SUMMARY %s\n' "====================" "===================="
    printf 'Run id        : %s\n' "$TDX_RUN_ID"
    printf 'Tables        : done=%s failed=%s pending=%s (queued=%s, skipped already done=%s)\n' \
        "$done_n" "$failed" $((queued - done_n - failed)) "$queued" "$skipped"
    printf 'Rows exported : %s\n' "$(tdx_commas "$TDX_ROWS_TOTAL")"
    printf 'Files written : %s (.dat) / %s (.tar.gz)\n' "$TDX_DAT_FILES" "$TDX_ZIP_FILES"
    printf 'Elapsed       : %s\n' "$(tdx_fmt_hms $(($(tdx_now_ds) - started)))"
    for k in "${FAIL_ORDER[@]}"; do printf 'FAILED        : %s - %s\n' "$k" "${FAILURES[$k]}"; done
    printf '%s\n' "=================================================================="
}
