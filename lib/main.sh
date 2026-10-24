# shellcheck shell=bash
# CLI, startup checks, the job scheduler and the run summary.

tdx_usage() {
    cat <<'USAGE'
usage: teradata_extract.sh [-h] [--config CONFIG] [--tables TABLES] [--parallel PARALLEL]
                           [--new-cycle] [--reset-table DB.TABLE] [--reset-watermark DB.TABLE]
                           [--dry-run] [--status] [-v]

Extract Teradata 16.20 tables to pipe-delimited files with FastExport/BTEQ.

options:
  -h, --help            show this help message and exit
  --config CONFIG
  --tables TABLES       comma-separated DB.TABLE list to restrict this run
  --parallel PARALLEL   override [extract] parallel (N or auto)
  --new-cycle           reset all tables to pending, keep watermarks
  --reset-table DB.TABLE
  --reset-watermark DB.TABLE
  --dry-run             validate and print the work queue only
  --status              print the state summary and exit
  -v, --verbose
USAGE
}

tdx_usage_error() {
    printf 'usage: teradata_extract.sh [-h] [--config CONFIG] [--tables TABLES] [--parallel PARALLEL] [--new-cycle] [--reset-table DB.TABLE] [--reset-watermark DB.TABLE] [--dry-run] [--status] [-v]\n' >&2
    printf 'teradata_extract.sh: error: %s\n' "$1" >&2
    exit 2
}

tdx_parse_args() {
    A_config="$TDX_ROOT/config/main_config.ini"
    A_tables=""
    A_parallel=""
    A_have_parallel=0
    A_new_cycle=0
    A_dry_run=0
    A_status=0
    A_reset_table=()
    A_reset_wm=()
    local opt val
    while (($#)); do
        opt=$1
        shift
        val=""
        case $opt in
            --*=*) val=${opt#*=}; opt=${opt%%=*}; set -- "$val" "$@" ;;
        esac
        case $opt in
            -h | --help) tdx_usage; exit 0 ;;
            -v | --verbose) TDX_VERBOSE=1 ;;
            --new-cycle) A_new_cycle=1 ;;
            --dry-run) A_dry_run=1 ;;
            --status) A_status=1 ;;
            --config | --tables | --parallel | --reset-table | --reset-watermark)
                (($#)) || tdx_usage_error "argument $opt: expected one argument"
                val=$1
                shift
                case $opt in
                    --config) A_config=$val ;;
                    --tables) A_tables=$val ;;
                    --parallel) A_parallel=$val; A_have_parallel=1 ;;
                    --reset-table) A_reset_table+=("$val") ;;
                    --reset-watermark) A_reset_wm+=("$val") ;;
                esac
                ;;
            *) tdx_usage_error "unrecognized arguments: $opt" ;;
        esac
    done
}

tdx_new_cycle_id() {
    local base cand n=1 cur f
    base=$(date -u +%Y%m%dT%H%M%SZ)
    cand=$base
    tdx_state_get _run cycle_id
    cur=$REPLY
    while :; do
        local used=0
        [[ $cand == "$cur" ]] && used=1
        for f in "$S_output_dir"/*_"$cand".tar.gz "$S_output_dir"/*_"$cand".zip; do
            [[ -e $f ]] && used=1
        done
        ((used)) || break
        n=$((n + 1))
        cand="$base-$n"
    done
    REPLY=$cand
}

tdx_cleanup() {
    if [[ -n ${TDX_RUN_LOCKED:-} ]]; then tdx_unlock "$S_lock_dir"; fi
    [[ -n ${TDX_RUNDIR:-} && -d $TDX_RUNDIR ]] && rm -rf "$TDX_RUNDIR"
}

# ---------------------------------------------------------------- jobs
tdx_job_exit() {
    if [[ $TDX_JOB_KIND == prep ]]; then
        {
            printf 'cdc_from%s%s\n' "$TDX_US" "${W_cdc_from:-}"
            printf 'cdc_to%s%s\n' "$TDX_US" "${W_cdc_to:-}"
            printf 'no_new_rows%s%s\n' "$TDX_US" "${W_no_new_rows:-0}"
            printf 'pending%s%s\n' "$TDX_US" "${W_pending:-}"
        } >"$TDX_RUNDIR/$(tdx_table_base "$TDX_JOB_KEY").info"
    fi
    : >"$TDX_JOB_DONE"
}

tdx_dump_vars() {
    local v line
    for v; do
        line=$(declare -p "$v" 2>/dev/null) || continue
        case $line in
            "declare -- "*) line="declare -g ${line#declare -- }" ;;
            "declare -"*) line="declare -g${line#declare -}" ;;
        esac
        printf '%s\n' "$line"
    done
}

tdx_job() {
    TDX_JOB_KIND=$1
    TDX_JOB_KEY=$2
    local idx=$3 id=$4
    TDX_JOB_ERR="$TDX_RUNDIR/job$id.err"
    TDX_JOB_DONE="$TDX_RUNDIR/job$id.done"
    TDX_CHILD_PIDS=""
    TDX_HELD=0
    trap - INT
    trap '[[ -n $TDX_CHILD_PIDS ]] && kill -TERM $TDX_CHILD_PIDS 2>/dev/null; exit 143' TERM
    trap tdx_job_exit EXIT
    local env="$TDX_RUNDIR/$(tdx_table_base "$TDX_JOB_KEY").env"
    if [[ $TDX_JOB_KIND == prep ]]; then
        tdx_prepare "$TDX_JOB_KEY"
        tdx_dump_vars NCOLS C_name C_tc C_len C_tot C_frac C_null C_ct R_enc R_rs R_expr R_max R_lob R_emp \
            R_notes W_lob W_cdc_from W_cdc_to W_cdc_idx W_nchunks >"$env"
    else
        # shellcheck disable=SC1090
        source "$env"
        tdx_export_chunk "$TDX_JOB_KEY" "$idx"
    fi
    exit 0
}

declare -gA JOB_KIND=() JOB_KEY=() JOB_IDX=() JOB_ID=() OUTSTANDING=()
TDX_JOBSEQ=0

tdx_start_job() {
    local kind=$1 key=$2 idx=$3 id slot
    TDX_JOBSEQ=$((TDX_JOBSEQ + 1))
    id=$TDX_JOBSEQ
    slot=$(((id - 1) % S_parallel))
    (TDX_THREAD="tdx_$slot" tdx_job "$kind" "$key" "$idx" "$id") &
    local pid=$!
    JOB_KIND[$pid]=$kind
    JOB_KEY[$pid]=$key
    JOB_IDX[$pid]=$idx
    JOB_ID[$pid]=$id
}

# Collect finished jobs into FINISHED (pids); blocks until at least one finished.
tdx_wait_jobs() {
    local pid
    FINISHED=()
    while :; do
        for pid in "${!JOB_KIND[@]}"; do
            if [[ -f $TDX_RUNDIR/job${JOB_ID[$pid]}.done ]] || ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null
                FINISHED+=("$pid")
            fi
        done
        ((${#FINISHED[@]})) && return 0
        [[ $TDX_STOP == 1 ]] && return 0
        wait -n 2>/dev/null || tdx_short_sleep
    done
}

tdx_stop_jobs() {
    local pid
    for pid in "${!JOB_KIND[@]}"; do kill -TERM "$pid" 2>/dev/null; done
    for pid in "${!JOB_KIND[@]}"; do wait "$pid" 2>/dev/null; done
    JOB_KIND=()
}

tdx_job_error() {
    local pid=$1 f="$TDX_RUNDIR/job${JOB_ID[$1]}.err"
    if [[ -s $f ]]; then
        REPLY=$(cat "$f")
    elif [[ -f $TDX_RUNDIR/job${JOB_ID[$1]}.done ]]; then
        REPLY=""
    else
        REPLY="job process ended unexpectedly"
    fi
    rm -f "$f" "$TDX_RUNDIR/job${JOB_ID[$1]}.done"
}

tdx_run_queue() {
    local -a prep_q=("$@") chunk_q=()
    local pid kind key idx msg i
    while ((${#prep_q[@]} || ${#chunk_q[@]} || ${#JOB_KIND[@]})); do
        [[ $TDX_STOP == 1 ]] && break
        while ((${#JOB_KIND[@]} < S_parallel)) && ((${#prep_q[@]} || ${#chunk_q[@]})); do
            if ((${#chunk_q[@]})); then
                key=${chunk_q[0]%"$TDX_US"*}
                idx=${chunk_q[0]##*"$TDX_US"}
                chunk_q=("${chunk_q[@]:1}")
                tdx_start_job chunk "$key" "$idx"
            else
                key=${prep_q[0]}
                prep_q=("${prep_q[@]:1}")
                W_STARTED[$key]=$(tdx_now_ds)
                tdx_start_job prep "$key" 0
            fi
        done
        tdx_wait_jobs
        [[ $TDX_STOP == 1 ]] && break
        for pid in "${FINISHED[@]}"; do
            kind=${JOB_KIND[$pid]}
            key=${JOB_KEY[$pid]}
            idx=${JOB_IDX[$pid]}
            tdx_job_error "$pid"
            msg=$REPLY
            unset "JOB_KIND[$pid]" "JOB_KEY[$pid]" "JOB_IDX[$pid]" "JOB_ID[$pid]"
            if [[ $kind == prep ]]; then
                if [[ -n $msg ]]; then
                    TERR[$key]+="${TERR[$key]:+; }$(tdx_mask "$msg")"
                    tdx_safe_finalize "$key"
                    continue
                fi
                tdx_load_info "$key"
                if [[ -z $WI_pending ]]; then
                    tdx_safe_finalize "$key"
                    continue
                fi
                local -a todo=($WI_pending)
                OUTSTANDING[$key]=${#todo[@]}
                for i in "${todo[@]}"; do chunk_q+=("$key$TDX_US$i"); done
            else
                if [[ -n $msg ]]; then
                    msg=$(tdx_mask "$msg")
                    TERR[$key]+="${TERR[$key]:+; }$msg"
                    local sec
                    printf -v sec '%s/part%03d' "$key" "$idx"
                    tdx_state_update "$sec" status=failed last_error="${msg:0:1000}"
                fi
                OUTSTANDING[$key]=$((OUTSTANDING[$key] - 1))
                ((OUTSTANDING[$key] == 0)) && tdx_safe_finalize "$key"
            fi
        done
    done
    if [[ $TDX_STOP == 1 ]]; then
        tdx_stop_jobs
        tdx_state_save
        return 1
    fi
    return 0
}

tdx_check_connect() {
    local host=$1 port=$2 p i=0 err="$TDX_RUNDIR/connect.err" why=""
    (exec 3<>"/dev/tcp/$host/$port") 2>"$err" &
    p=$!
    while kill -0 "$p" 2>/dev/null && ((i < 100)); do
        tdx_short_sleep
        i=$((i + 1))
    done
    if kill -0 "$p" 2>/dev/null; then
        kill -9 "$p" 2>/dev/null
        wait "$p" 2>/dev/null
        tdx_config_error "cannot reach $host:$port: timed out"
    fi
    wait "$p" && return 0
    [[ -s $err ]] && IFS= read -r why <"$err"
    why=${why##*: }
    [[ $why == *"No such file"* ]] && why="$why: this bash has no /dev/tcp support, set connect_check = false"
    tdx_config_error "cannot reach $host:$port: connection failed${why:+ ($why)}"
}

# ---------------------------------------------------------------- main
tdx_main() {
    set +e +u
    set +o pipefail
    tdx_detect_sleep
    tdx_parse_args "$@"
    local started now_iso k key
    started=$(tdx_now_ds)
    now_iso=$(tdx_iso_now)
    TDX_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    TDX_STOP=0
    tdx_load_settings "$A_config" "$A_parallel" "$A_have_parallel"
    mkdir -p "$S_output_dir" "$S_metadata_dir" "$S_log_dir" "$S_work_dir" "$(dirname "$S_process_state_file")" ||
        tdx_config_error "cannot create the output directories"
    TDX_RUNDIR="$S_work_dir/.tdx-run-$$"
    rm -rf "$TDX_RUNDIR"
    mkdir -p "$TDX_RUNDIR" || tdx_config_error "cannot create $TDX_RUNDIR"
    trap tdx_cleanup EXIT
    if [[ $A_status != 1 && $A_dry_run != 1 ]]; then TDX_LOG_FILE="$S_log_dir/extract_$TDX_RUN_ID.log"; fi
    tdx_load_sources "$S_source_tables_file"
    local -a wanted=() unknown=()
    local IFS=,
    for k in $A_tables; do
        k=$(tdx_strip "$k")
        [[ -n $k ]] && wanted+=("${k^^}")
    done
    unset IFS
    for k in "${wanted[@]}" "${A_reset_table[@]}" "${A_reset_wm[@]}"; do
        k=${k^^}
        [[ -n ${T_DB[$k]+x} ]] || unknown+=("$k")
    done
    if ((${#unknown[@]})); then
        local list
        list=$(printf '%s, ' "${unknown[@]}")
        tdx_config_error "table(s) not defined in ${S_source_tables_file##*/}: ${list%, }"
    fi
    if [[ $A_status != 1 ]]; then
        tdx_lock_try "$S_lock_dir" || tdx_lock_try "$S_lock_dir" ||
            tdx_config_error "another teradata_extract run holds $S_lock_dir"
        TDX_RUN_LOCKED=1
    fi
    tdx_state_open "$S_process_state_file" "$A_dry_run"
    local changed=0
    if [[ $A_new_cycle == 1 ]]; then
        tdx_new_cycle_id
        tdx_state_ops 0 resetall "set${TDX_US}_run${TDX_US}cycle_id$TDX_US$REPLY"
        changed=1
    fi
    for k in "${A_reset_table[@]}"; do
        tdx_state_ops 0 "reset$TDX_US${k^^}${TDX_US}0"
        changed=1
    done
    for k in "${A_reset_wm[@]}"; do
        tdx_state_ops 0 "reset$TDX_US${k^^}${TDX_US}1"
        changed=1
    done
    tdx_state_get _run cycle_id
    if [[ -z $REPLY ]]; then
        tdx_new_cycle_id
        tdx_state_ops 0 "set${TDX_US}_run${TDX_US}cycle_id$TDX_US$REPLY"
        changed=1
    fi
    if ((changed)); then
        if [[ $A_status != 1 ]] || [[ $A_dry_run != 1 ]]; then tdx_state_save; fi
    fi
    if [[ $A_status == 1 ]]; then
        tdx_print_status
        exit 0
    fi

    tdx_load_credentials
    local fexp_which bteq_which
    fexp_which=$(command -v "$S_fexp_path") || tdx_config_error "fexp executable not found: $S_fexp_path"
    bteq_which=$(command -v "$S_bteq_path") || tdx_config_error "bteq executable not found: $S_bteq_path"
    local -a selected=() queue=() skipped=()
    if ((${#wanted[@]})); then selected=("${wanted[@]}"); else selected=("${T_KEYS[@]}"); fi
    for key in "${selected[@]}"; do
        tdx_state_get "$key" status
        if [[ $REPLY == done ]]; then skipped+=("$key"); else queue+=("$key"); fi
    done
    if [[ $A_dry_run == 1 ]]; then
        printf 'Credentials : %s (user %s)\n' "$TDX_CRED_SOURCE" "$TDX_USER"
        printf 'Tools       : fexp=%s bteq=%s\n' "$fexp_which" "$bteq_which"
        printf 'Parallel    : %s job(s), max_sessions=%s\n' "$S_parallel" "$S_max_sessions"
        tdx_state_get _run cycle_id
        printf 'Cycle id    : %s\n' "$REPLY"
        printf 'Work queue  : %s table(s), %s already done\n' "${#queue[@]}" "${#skipped[@]}"
        for key in "${queue[@]}"; do
            tdx_state_section "$key"
            local wm=${ST_SEC[watermark]:-}
            printf '  %-40s status=%-8s cdc=%s watermark=%s\n' "$key" "${ST_SEC[status]:-pending}" \
                "${T_CDC[$key]:--}" "${wm:--}"
        done
        exit 0
    fi
    [[ $S_connect_check == 1 ]] && tdx_check_connect "$S_host" "$S_port"

    tdx_info "run $TDX_RUN_ID: ${#queue[@]} table(s) queued, ${#skipped[@]} already done, parallel=$S_parallel, credentials from $TDX_CRED_SOURCE"
    tdx_state_update _run last_run_id="$TDX_RUN_ID" last_run_started="$now_iso" -last_run_finished
    for key in "${skipped[@]}"; do tdx_audit_skipped "$key"; done
    trap 'TDX_STOP=1' INT TERM
    local rc=$TDX_EXIT_OK
    if ! tdx_run_queue "${queue[@]}"; then
        tdx_error "interrupted; state saved, rerun to resume"
        rc=$TDX_EXIT_INTERRUPTED
    fi
    trap - INT TERM
    tdx_state_update _run last_run_finished="$(tdx_iso_now)"
    tdx_summary "${#queue[@]}" "${#skipped[@]}" "$started"
    if ((rc == TDX_EXIT_OK && ${#FAIL_ORDER[@]})); then rc=$TDX_EXIT_FAILED; fi
    exit "$rc"
}
