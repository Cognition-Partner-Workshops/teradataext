# shellcheck shell=bash
# Per-table work: prepare (metadata, CDC window, row estimate, chunk plan, prechecks) and
# chunk export. Both run as background jobs; a failure ends the job via tdx_fail.

# End the current job with a table-level error.
tdx_fail() {
    printf '%s\n' "$1" >"$TDX_JOB_ERR"
    exit 1
}

tdx_col_by_name() {
    local want=${1^^} i
    REPLY=0
    for ((i = 1; i <= NCOLS; i++)); do
        [[ ${C_name[i]^^} == "$want" ]] && REPLY=$i
    done
}

tdx_row_repr() {
    local r=$1 f out="" v
    for ((f = 0; f < ${QNF[$r]:-0}; f++)); do
        if [[ -n ${QNULL["$r,$f"]+x} ]]; then v=None; else v="'${QV["$r,$f"]}'"; fi
        out+="${out:+, }$v"
    done
    REPLY="[$out]"
}

# Field r,f of the last loaded query result ("" for NULL or missing); 1 when missing/NULL.
tdx_qv() {
    REPLY=${QV["$1,$2"]:-}
    [[ -n ${QV["$1,$2"]+x} && -z ${QNULL["$1,$2"]+x} ]]
}

tdx_int_or0() {
    local v
    v=$(tdx_strip "$1")
    [[ -z $v ]] && { REPLY=0; return 0; }
    tdx_is_int "$v" || return 1
    REPLY=$(tdx_int "$v")
}

tdx_prepare() {
    local key=$1 base fqn dbs tbs i r a
    W_key=$key
    W_cdc_from=""
    W_cdc_to=""
    W_no_new_rows=0
    W_est_rows=0
    W_pending=""
    W_nchunks=0
    W_lob=0
    NCOLS=0
    base=$(tdx_table_base "$key")
    fqn=$(tdx_table_fqn "$key")
    dbs=$(tdx_sql_str "${T_DB[$key]}")
    tbs=$(tdx_sql_str "${T_TABLE[$key]}")
    tdx_state_section "$key"
    declare -gA PREV=()
    for a in "${!ST_SEC[@]}"; do PREV[$a]=${ST_SEC[$a]}; done
    a=${PREV[attempts]:-0}
    tdx_is_int "$a" || a=0
    tdx_state_update "$key" status=in_progress attempts=$(($(tdx_int "$a") + 1)) started_at="$(tdx_iso_now)" -last_error

    local -a reqs=()
    tdx_marker columns "$key"
    local m=$REPLY
    local -a mf=()
    for a in ColumnId ColumnName ColumnType ColumnLength DecimalTotalDigits DecimalFractionalDigits \
        Nullable CharType; do
        case $a in ColumnName | ColumnType | Nullable) mf+=("$a") ;; *) tdx_meta_int "$a"; mf+=("$REPLY") ;; esac
    done
    tdx_wrap_fields "ColumnName" "${mf[@]}"
    reqs+=("$m SELECT $REPLY FROM DBC.ColumnsV WHERE DatabaseName = $dbs AND TableName = $tbs ORDER BY ColumnId")
    tdx_marker index "$key"
    m=$REPLY
    tdx_meta_int ColumnPosition
    tdx_wrap_fields "ColumnName" IndexType UniqueFlag "$REPLY" ColumnName
    reqs+=("$m SELECT $REPLY FROM DBC.IndicesV WHERE DatabaseName = $dbs AND TableName = $tbs ORDER BY IndexNumber, ColumnPosition")
    if [[ $S_row_estimate == stats ]]; then
        tdx_marker stats "$key"
        m=$REPLY
        tdx_meta_int "MAX(RowCount)"
        tdx_wrap_fields "" "$REPLY"
        reqs+=("$m SELECT $REPLY FROM DBC.StatsV WHERE DatabaseName = $dbs AND TableName = $tbs")
    fi
    tdx_query "$base.meta" "${reqs[@]}"
    local qdir=$TDX_QDIR

    # columns
    tdx_rows_load "$qdir/r1"
    ((QROWS > 0)) || tdx_fail "no column metadata for $key (table missing, a view, or no access)"
    declare -ga C_name=() C_tc=() C_len=() C_tot=() C_frac=() C_null=() C_ct=()
    declare -ga R_enc=() R_rs=() R_expr=() R_max=() R_lob=() R_emp=() R_notes=()
    for ((r = 1; r <= QROWS; r++)); do
        tdx_row_repr "$r"
        local rrepr=$REPLY
        ((${QNF[$r]} >= 8)) || tdx_fail "unexpected DBC.ColumnsV row $rrepr"
        i=$((NCOLS + 1))
        tdx_qv "$r" 1
        C_name[i]=$REPLY
        tdx_qv "$r" 2
        a=$(tdx_strip "$REPLY")
        C_tc[i]=${a^^}
        tdx_int_or0 "${QV["$r,3"]}" || tdx_fail "unexpected DBC.ColumnsV row $rrepr"
        C_len[i]=$REPLY
        tdx_int_or0 "${QV["$r,4"]}" || tdx_fail "unexpected DBC.ColumnsV row $rrepr"
        C_tot[i]=$REPLY
        tdx_int_or0 "${QV["$r,5"]}" || tdx_fail "unexpected DBC.ColumnsV row $rrepr"
        C_frac[i]=$REPLY
        tdx_int_or0 "${QV["$r,7"]}" || tdx_fail "unexpected DBC.ColumnsV row $rrepr"
        C_ct[i]=$REPLY
        a=${QV["$r,6"]}
        a=$(tdx_strip "${a:-Y}")
        if [[ ${a^^} == Y ]]; then C_null[i]=1; else C_null[i]=0; fi
        NCOLS=$i
    done
    for ((i = 1; i <= NCOLS; i++)); do
        tdx_build_rule "$i"
        [[ ${R_lob[i]} == 1 ]] && W_lob=1
    done

    # primary index / primary key
    tdx_rows_load "$qdir/r2"
    local -a pi=() pk=()
    for ((r = 1; r <= QROWS; r++)); do
        ((${QNF[$r]} > 3)) || continue
        tdx_qv "$r" 3 || continue
        [[ -n $REPLY ]] || continue
        case ${QV["$r,0"]} in
            P | Q) [[ -z ${QNULL["$r,0"]+x} ]] && pi+=("$REPLY") ;;
            K) [[ -z ${QNULL["$r,0"]+x} ]] && pk+=("$REPLY") ;;
        esac
    done
    local pi_list
    pi_list=$(IFS=,; printf '%s' "${pi[*]}")
    local stats_v="" have_stats=0
    if [[ $S_row_estimate == stats ]]; then
        tdx_rows_load "$qdir/r3"
        if ((QROWS > 0)); then
            have_stats=1
            tdx_qv 1 0 && stats_v=$REPLY
        fi
    fi
    rm -rf "$qdir"
    local meta_path="$S_metadata_dir/$base.meta.ini"

    local unsup=""
    for ((i = 1; i <= NCOLS; i++)); do
        if [[ ${R_enc[i]} == unsupported ]]; then
            tdx_source_type "$i"
            unsup+="${unsup:+; }${C_name[i]} $REPLY: ${R_notes[i]}"
        fi
    done
    if [[ -n $unsup ]]; then
        tdx_write_meta "$meta_path" "$key" none "" "n/a" "$pi_list" 0
        tdx_fail "unsupported column(s): $unsup"
    fi
    tdx_record_width
    local rwidth=$REPLY
    tdx_varchar_max
    if ((rwidth > REPLY)); then
        tdx_write_meta "$meta_path" "$key" none "" "n/a" "$pi_list" 0
        tdx_fail "table too wide to export: its columns add up to $rwidth characters per record, over Teradata's $REPLY-character VARCHAR maximum (text columns count twice their length for escaping, at most $TDX_OREPLACE_MAX)"
    fi

    # CDC window
    local cdc_pred="" lower="" cdc=${T_CDC[$key]}
    W_cdc_idx=0
    if [[ -n $cdc ]]; then
        tdx_col_by_name "$cdc"
        W_cdc_idx=$REPLY
        ((W_cdc_idx)) || tdx_fail "cdc_column $cdc not found in $key"
        local ctc=${C_tc[W_cdc_idx]} cname=${C_name[W_cdc_idx]}
        if ! tdx_in "$ctc" "$TDX_CDC_TYPES"; then
            tdx_source_type "$W_cdc_idx"
            tdx_fail "cdc_column $cdc type $REPLY not supported for CDC"
        fi
        W_cdc_from=${PREV[watermark]:-}
        W_cdc_to=${PREV[pending_watermark]:-}
        if [[ -n $W_cdc_from ]]; then
            tdx_cdc_expr "$ctc" "$cname"
            lower=$REPLY
            tdx_cdc_literal "$ctc" "$cname" "$W_cdc_from" || tdx_fail "$TDX_ERR"
            lower+=" > $REPLY"
        fi
        if [[ -z $W_cdc_to ]]; then
            tdx_marker cdcmax "$key" cdc_gt "$W_cdc_from"
            m=$REPLY
            tdx_cdc_max_sql "$ctc" "$cname" "${C_tot[W_cdc_idx]}" "${C_frac[W_cdc_idx]}"
            tdx_wrap_fields "" "$REPLY"
            local wf=$REPLY
            tdx_where_sql "$lower" "${T_WHERE[$key]}"
            tdx_query "$base.cdc" "$m SELECT $wf FROM $fqn$REPLY"
            tdx_rows_load "$TDX_QDIR/r1"
            rm -rf "$TDX_QDIR"
            W_cdc_to=""
            ((QROWS > 0)) && tdx_qv 1 0 && W_cdc_to=$REPLY
            if [[ -z $W_cdc_to && -z $W_cdc_from ]]; then
                tdx_warn "$key: $cdc has no non-NULL values; extracting the full table without a watermark"
            elif [[ -z $W_cdc_to ]]; then
                W_no_new_rows=1
                W_est_rows=0
                tdx_write_meta "$meta_path" "$key" none "" cdc "$pi_list" 0
                tdx_state_update "$key" method=none estimated_rows=0 row_estimate_source=cdc chunk_strategy=none \
                    chunk_count=0 chunks_done=
                return 0
            else
                tdx_state_update "$key" pending_watermark="$W_cdc_to"
            fi
        fi
        if [[ ${C_null[W_cdc_idx]} == 1 ]]; then
            tdx_info "$key: rows with NULL $cdc are taken only by the initial (no watermark) extract"
        fi
        tdx_cdc_window_pred "$ctc" "$cname" "$W_cdc_from" "$W_cdc_to" || tdx_fail "$TDX_ERR"
        cdc_pred=$REPLY
    fi
    W_cdc_pred=$cdc_pred
    local where=${T_WHERE[$key]}

    # Reuse an existing chunk plan when resuming
    local -a existing=()
    local sec
    while IFS= read -r sec; do [[ -n $sec ]] && existing+=("$sec"); done < <(tdx_state_chunk_sections "$key")
    if ((${#existing[@]})) && [[ -n ${PREV[chunk_count]:-} ]] && tdx_is_int "${PREV[chunk_count]}" &&
        (($(tdx_int "${PREV[chunk_count]}") == ${#existing[@]})); then
        local n=${#existing[@]} done_list=",${PREV[chunks_done]:-}," zipped=0 cyc
        W_nchunks=$n
        tdx_int_or0 "${PREV[estimated_rows]:-}" && W_est_rows=$REPLY
        tdx_state_get _run cycle_id
        cyc=$REPLY
        [[ ${PREV[zip_file]:-} == "${base}_$cyc.tar.gz" ]] && zipped=1
        for ((i = 1; i <= n; i++)); do
            tdx_state_section "${existing[i - 1]}"
            if [[ $done_list != *",$i,"* || ${ST_SEC[status]:-} != "done" ]]; then
                W_pending+="${W_pending:+ }$i"
            elif ((zipped == 0)) && [[ ! -e $S_output_dir/${ST_SEC[file]} ]]; then
                tdx_warn "$key: ${ST_SEC[file]} is missing, re-exporting chunk $i"
                W_pending+="${W_pending:+ }$i"
            fi
        done
        tdx_prechecks "$key" "$cdc_pred" "$where"
        tdx_write_meta "$meta_path" "$key" "${PREV[chunk_strategy]:-none}" "${PREV[chunk_column]:-}" \
            "${PREV[row_estimate_source]:-}" "$pi_list" "$n"
        return 0
    fi

    # Row estimate
    local est="" est_source=count
    if [[ $S_row_estimate == stats && -z $W_cdc_from && -z $where && $have_stats == 1 && -n $stats_v ]]; then
        est=$(tdx_decint "$stats_v") || tdx_fail "unexpected numeric value $(tdx_repr "$stats_v")"
        est_source=stats
    fi
    if [[ -z $est ]]; then
        tdx_marker count "$key" cdc_gt "$W_cdc_from" cdc_le "$W_cdc_to"
        m=$REPLY
        tdx_wrap_fields "" "CAST(COUNT(*) AS BIGINT)"
        local wf=$REPLY
        tdx_where_sql "$cdc_pred" "$where"
        tdx_query "$base.count" "$m SELECT $wf FROM $fqn$REPLY"
        tdx_rows_load "$TDX_QDIR/r1"
        rm -rf "$TDX_QDIR"
        est=0
        if ((QROWS > 0)) && ((${QNF[1]} > 0)); then
            tdx_int_or0 "${QV["1,0"]}" || tdx_fail "invalid literal for int() with base 10: $(tdx_repr "${QV["1,0"]}")"
            est=$REPLY
        fi
    fi
    W_est_rows=$est

    # Chunk plan
    local strategy=none chunk_col="" n
    local -a preds=("")
    if ((est > S_chunk_threshold_rows)); then
        n=$(((est + S_chunk_rows - 1) / S_chunk_rows))
        ((n > S_max_chunks)) && n=$S_max_chunks
        ((n < 2)) && n=2
        local cand=0 kname
        if [[ -n ${T_CHUNK[$key]} ]]; then
            tdx_col_by_name "${T_CHUNK[$key]}"
            cand=$REPLY
            ((cand)) || tdx_fail "chunk_column ${T_CHUNK[$key]} not found in $key"
        else
            if ((${#pk[@]} == 1)); then
                tdx_col_by_name "${pk[0]}"
                ((REPLY)) && tdx_in "${C_tc[REPLY]}" "$TDX_CHUNKABLE_TYPES" && cand=$REPLY
            fi
            if ((cand == 0 && ${#pi[@]} == 1)); then
                tdx_col_by_name "${pi[0]}"
                ((REPLY)) && tdx_in "${C_tc[REPLY]}" "$TDX_CHUNKABLE_TYPES" && cand=$REPLY
            fi
        fi
        if ((cand)) && tdx_in "${C_tc[cand]}" "$TDX_CHUNKABLE_TYPES"; then
            local q lo hi
            q=$(tdx_sql_ident "${C_name[cand]}")
            local -a lohi
            if [[ ${C_tc[cand]} == DA ]]; then
                lohi=("CAST(CAST(MIN($q) AS FORMAT 'YYYY-MM-DD') AS CHAR(10))" "CAST(CAST(MAX($q) AS FORMAT 'YYYY-MM-DD') AS CHAR(10))")
            else
                tdx_num_text "MIN($q)" "${C_tc[cand]}" "${C_tot[cand]}" "${C_frac[cand]}"
                lohi=("$REPLY")
                tdx_num_text "MAX($q)" "${C_tc[cand]}" "${C_tot[cand]}" "${C_frac[cand]}"
                lohi+=("$REPLY")
            fi
            tdx_marker minmax "$key" col "${C_name[cand]}" cdc_gt "$W_cdc_from" cdc_le "$W_cdc_to"
            m=$REPLY
            tdx_wrap_fields "" "${lohi[@]}"
            local wf=$REPLY
            tdx_where_sql "$cdc_pred" "$where"
            tdx_query "$base.minmax" "$m SELECT $wf FROM $fqn$REPLY"
            tdx_rows_load "$TDX_QDIR/r1"
            rm -rf "$TDX_QDIR"
            if ((QROWS > 0)) && ((${QNF[1]} > 1)) && [[ -z ${QNULL["1,0"]+x} && -z ${QNULL["1,1"]+x} ]]; then
                lo=$(tdx_strip "${QV["1,0"]}")
                hi=$(tdx_strip "${QV["1,1"]}")
                tdx_range_predicates "${C_tc[cand]}" "${C_frac[cand]}" "${C_name[cand]}" "$lo" "$hi" "$n" ||
                    tdx_fail "$TDX_ERR"
                preds=("${RP[@]}")
                if ((${#preds[@]} > 1)); then
                    strategy=range
                    chunk_col=${C_name[cand]}
                else
                    preds=("")
                fi
            fi
        else
            local -a hcols=()
            if ((cand)); then
                hcols=("${C_name[cand]}")
            elif ((${#pi[@]})); then
                hcols=("${pi[@]}")
            else
                hcols=("${C_name[1]}")
            fi
            local hc="" c
            for c in "${hcols[@]}"; do hc+="${hc:+,}$(tdx_sql_ident "$c")"; done
            preds=()
            for ((i = 0; i < n; i++)); do preds+=("HASHBUCKET(HASHROW($hc)) MOD $n = $i"); done
            strategy=hash
            chunk_col=$(IFS=,; printf '%s' "${hcols[*]}")
        fi
    fi
    n=${#preds[@]}
    W_nchunks=$n
    local per=0 fname
    ((n)) && per=$(((est + n - 1) / n))
    local -a ops=("rmchunks$TDX_US$key")
    for ((i = 1; i <= n; i++)); do
        if ((n > 1)); then printf -v fname '%s.part%03d.dat' "$base" "$i"; else fname="$base.dat"; fi
        printf -v sec '%s/part%03d' "$key" "$i"
        ops+=("set$TDX_US$sec${TDX_US}status${TDX_US}pending" "set$TDX_US$sec${TDX_US}file$TDX_US$fname"
            "set$TDX_US$sec${TDX_US}where$TDX_US${preds[i - 1]}" "set$TDX_US$sec${TDX_US}est_rows$TDX_US$per")
        W_pending+="${W_pending:+ }$i"
    done
    ops+=("set$TDX_US$key${TDX_US}estimated_rows$TDX_US$est" "set$TDX_US$key${TDX_US}row_estimate_source$TDX_US$est_source"
        "set$TDX_US$key${TDX_US}chunk_strategy$TDX_US$strategy" "set$TDX_US$key${TDX_US}chunk_column$TDX_US$chunk_col"
        "set$TDX_US$key${TDX_US}chunk_count$TDX_US$n" "set$TDX_US$key${TDX_US}chunks_done$TDX_US")
    tdx_state_ops 1 "${ops[@]}"
    tdx_prechecks "$key" "$cdc_pred" "$where"
    tdx_write_meta "$meta_path" "$key" "$strategy" "$chunk_col" "$est_source" "$pi_list" "$n"
}

tdx_prechecks() {
    local key=$1 cdc_pred=$2 where=$3 base fqn i q m wsql
    local -a reqs=() lobs=() exprs=()
    base=$(tdx_table_base "$key")
    fqn=$(tdx_table_fqn "$key")
    tdx_where_sql "$cdc_pred" "$where"
    wsql=$REPLY
    for ((i = 1; i <= NCOLS; i++)); do
        [[ ${R_lob[i]} == 1 ]] || continue
        lobs+=("$i")
        q=$(tdx_sql_ident "${C_name[i]}")
        case ${C_tc[i]} in
            BO) exprs+=("MAX(BYTES($q))") ;;
            XM) exprs+=("MAX(CHARACTER_LENGTH(XMLSERIALIZE(CONTENT $q AS CLOB)))") ;;
            JN) exprs+=("MAX(CHARACTER_LENGTH(CAST($q AS CLOB)))") ;;
            *) exprs+=("MAX(CHARACTER_LENGTH($q))") ;;
        esac
    done
    if ((${#lobs[@]})); then
        local names=""
        for i in "${lobs[@]}"; do names+="${names:+,}${C_name[i]}"; done
        tdx_marker lobcheck "$key" cols "$names" cdc_gt "$W_cdc_from" cdc_le "$W_cdc_to"
        m=$REPLY
        tdx_wrap_fields "" "${exprs[@]}"
        reqs+=("$m SELECT $REPLY FROM $fqn$wsql")
    fi
    tdx_row_limit
    local limit=$REPLY sentinel=${#S_null_sentinel} theoretical=0 total=""
    ((${#S_empty_sentinel} > sentinel)) && sentinel=${#S_empty_sentinel}
    for ((i = 1; i <= NCOLS; i++)); do
        theoretical=$((theoretical + (R_max[i] > sentinel ? R_max[i] : sentinel)))
        total+="${total:+ + }CHARACTER_LENGTH(${R_expr[i]})"
    done
    theoretical=$((theoretical + NCOLS - 1))
    if ((theoretical > limit)); then
        tdx_marker rowcheck "$key" cdc_gt "$W_cdc_from" cdc_le "$W_cdc_to"
        m=$REPLY
        tdx_wrap_fields "" "MAX($total) + $((NCOLS - 1))"
        reqs+=("$m SELECT $REPLY FROM $fqn$wsql")
    fi
    ((${#reqs[@]})) || return 0
    tdx_query "$base.check" "${reqs[@]}"
    local qdir=$TDX_QDIR pos=1 v k
    if ((${#lobs[@]})); then
        tdx_rows_load "$qdir/r1"
        if ((QROWS > 0)); then
            for ((k = 0; k < ${#lobs[@]} && k < ${QNF[1]}; k++)); do
                tdx_qv 1 "$k" || continue
                [[ -n $REPLY ]] || continue
                v=$(tdx_decint "$REPLY") || tdx_fail "unexpected numeric value $(tdx_repr "$REPLY")"
                if ((v > S_lob_max_length)); then
                    rm -rf "$qdir"
                    tdx_fail "LOB value length $v in ${C_name[${lobs[k]}]} exceeds lob_max_length $S_lob_max_length"
                fi
            done
        fi
        pos=2
    fi
    if ((theoretical > limit)); then
        tdx_rows_load "$qdir/r$pos"
        if ((QROWS > 0)) && tdx_qv 1 0 && [[ -n $REPLY ]]; then
            v=$(tdx_decint "$REPLY") || tdx_fail "unexpected numeric value $(tdx_repr "$REPLY")"
            if ((v > limit)); then
                rm -rf "$qdir"
                tdx_fail "record length $v exceeds the record limit $limit (max_row_length, capped at the Teradata VARCHAR maximum)"
            fi
        fi
    fi
    rm -rf "$qdir"
}

tdx_export_chunk() {
    local key=$1 idx=$2 sec base fqn dat raw tmp job chwhere est file
    printf -v sec '%s/part%03d' "$key" "$idx"
    base=$(tdx_table_base "$key")
    fqn=$(tdx_table_fqn "$key")
    tdx_state_section "$sec"
    file=${ST_SEC[file]}
    chwhere=${ST_SEC[where]:-}
    tdx_int_or0 "${ST_SEC[est_rows]:-}" || REPLY=0
    est=$REPLY
    dat="$S_output_dir/$file"
    raw="$dat.raw"
    tmp="$dat.tmp"
    job=${file%.*}
    local chunk_mark=""
    ((W_nchunks > 1)) && chunk_mark="$idx/$W_nchunks"
    local cdc_pred=""
    if [[ -n ${T_CDC[$key]} && -n $W_cdc_to ]]; then
        tdx_cdc_window_pred "${C_tc[W_cdc_idx]}" "${C_name[W_cdc_idx]}" "$W_cdc_from" "$W_cdc_to" || tdx_fail "$TDX_ERR"
        cdc_pred=$REPLY
    fi
    tdx_marker export "$key" cdc_gt "$W_cdc_from" cdc_le "$W_cdc_to" chunk "$chunk_mark"
    local m=$REPLY
    tdx_record_sql
    local rec=$REPLY
    tdx_where_sql "$cdc_pred" "${T_WHERE[$key]}" "$chwhere"
    local sql="$m SELECT $rec AS tdx_rec FROM $fqn$REPLY"
    local method=fexp sessions
    if [[ $W_lob == 1 ]] || ((est < S_small_table_rows)); then method=bteq; fi
    if [[ $method == bteq ]]; then
        sessions=1
    else
        local par=$((S_parallel > 1 ? S_parallel : 1))
        sessions=$((S_max_sessions / par))
        ((sessions < S_min_sessions)) && sessions=$S_min_sessions
    fi
    tdx_state_update "$sec" status=in_progress method=$method sessions=$sessions
    local attempt=0 fell_back=0 job_id
    while :; do
        rm -f "$raw" "$dat"
        job_id="$job|$TDX_RUN_ID|$attempt|$method"
        if [[ $method == fexp ]]; then
            tdx_fexp_script "$sql" "$raw" "$sessions" "$job_id"
            tdx_run_tool fexp "$job" "$REPLY" "$sessions" && break
            tdx_drop_logtable "$TDX_FEXP_LT" "$job"
        else
            tdx_bteq_script "$sql" "$raw"
            tdx_run_tool bteq "$job" "$REPLY" 1 && break
        fi
        [[ $TDX_TOOL_SL == 1 ]] || tdx_fail "$TDX_TOOL_ERR"
        if ((attempt < S_retry_attempts)); then
            attempt=$((attempt + 1))
            if [[ $method == fexp ]]; then
                sessions=$((sessions / 2))
                ((sessions < S_min_sessions)) && sessions=$S_min_sessions
            else
                sessions=1
            fi
            tdx_warn "$job: session limit hit, retry $attempt/$S_retry_attempts in ${S_retry_delay_seconds}s with $sessions session(s)"
            tdx_state_update "$sec" sessions=$sessions
            tdx_sleep "$S_retry_delay_seconds"
            continue
        fi
        if [[ $method == fexp && $S_bteq_fallback == 1 && $fell_back == 0 ]]; then
            tdx_warn "$job: FastExport retries exhausted, falling back to BTEQ EXPORT"
            method=bteq
            sessions=1
            fell_back=1
            tdx_state_update "$sec" method=$method sessions=1
            continue
        fi
        tdx_fail "$TDX_TOOL_ERR"
    done
    local reported
    if [[ $method == fexp ]]; then reported=$TDX_ROWS_FEXP; else reported=$TDX_ROWS_BTEQ; fi
    tdx_row_limit
    local limit=$REPLY utf8=0
    [[ $S_session_charset == UTF8 ]] && utf8=1
    tdx_decode_raw "$raw" "$tmp" "$method" "$NCOLS" "$limit" "$utf8" "$(tdx_byte "$S_delimiter")" "$(tdx_byte "$S_escape_char")"
    case $? in
        1)
            rm -f "$tmp"
            tdx_fail "raw export file does not match any known record layout"
            ;;
        2)
            rm -f "$tmp"
            local kind=${TDX_DEC_ERR%% *} rest=${TDX_DEC_ERR#* }
            case $kind in
                fields) tdx_fail "$job: record ${rest%% *} has ${rest#* } fields, expected $NCOLS" ;;
                limit) tdx_fail "$job: record $rest exceeds the record limit $limit (changed after the precheck?); raise max_row_length" ;;
                *) tdx_fail "$job: record $rest contains a NUL byte, which the bash engine cannot write; remove it in the source or a view" ;;
            esac
            ;;
    esac
    local n_rows=$TDX_DEC_N layout=$TDX_DEC_LAYOUT
    if [[ -n $reported && $reported != "$n_rows" ]]; then
        rm -f "$tmp"
        tdx_fail "$job: $method reported $reported rows but $n_rows were parsed"
    fi
    mv -f "$tmp" "$dat" || tdx_fail "cannot rename $tmp"
    rm -f "$raw"
    local bytes sha
    bytes=$(tdx_file_size "$dat")
    sha=$(tdx_sha256_file "$dat")
    tdx_state_ops 1 "set$TDX_US$sec${TDX_US}status${TDX_US}done" "set$TDX_US$sec${TDX_US}rows$TDX_US$n_rows" \
        "set$TDX_US$sec${TDX_US}bytes$TDX_US$bytes" "set$TDX_US$sec${TDX_US}sha256$TDX_US$sha" \
        "set$TDX_US$sec${TDX_US}method$TDX_US$method" "set$TDX_US$sec${TDX_US}layout$TDX_US$layout" \
        "set$TDX_US$sec${TDX_US}finished_at$TDX_US$(tdx_iso_now)" "addchunk$TDX_US$key$TDX_US$idx"
    tdx_info "$job: $n_rows rows via $method"
}

# Helpers kept for tests and log handling --------------------------------------------------------
tdx_field_count() {
    printf '%s' "$1" | TDX_D=$2 TDX_E=$3 tdx_awk 'BEGIN { RS = "\001"; d = ENVIRON["TDX_D"]; e = ENVIRON["TDX_E"] }
        { s = s $0 } END {
        n = 1; L = length(s)
        for (i = 1; i <= L; i++) { c = substr(s, i, 1); if (c == e) i++; else if (c == d) n++ }
        print n }'
}

tdx_tool_log_text() {
    local body="${TMPDIR:-/tmp}/tdx_log.$$.$RANDOM"
    TDX_MASK_PW="" tdx_awk -v mode="$1" -v body="$body" -f "$TDX_LIB/maskfn.awk" -f "$TDX_LIB/toolout.awk" >/dev/null
    cat "$body"
    rm -f "$body"
}

tdx_tool_error_summary() {
    local mode=$1 rc=$2 body="${TMPDIR:-/tmp}/tdx_log.$$.$RANDOM" line code="" first=""
    while IFS= read -r line; do
        case $line in
            err_code=*) code=${line#err_code=} ;;
            err_line=*) first=${line#err_line=} ;;
        esac
    done < <(TDX_MASK_PW="" tdx_awk -v mode="$mode" -v body="$body" -f "$TDX_LIB/maskfn.awk" -f "$TDX_LIB/toolout.awk")
    rm -f "$body"
    if [[ $mode == none ]]; then
        if [[ -n $code ]]; then printf 'Teradata error %s\n' "$code"; else printf 'exit code %s\n' "$rc"; fi
    else
        printf '%s\n' "${first:-exit code $rc}"
    fi
}
