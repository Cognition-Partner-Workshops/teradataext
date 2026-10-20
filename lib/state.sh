# shellcheck shell=bash
# process_state.ini: a working copy (TDX_STATE_CUR) is changed under a directory lock and then
# copied atomically over the real file (temp file + mv). --dry-run never writes the real file.

tdx_state_open() {
    TDX_STATE_REAL=$1
    TDX_STATE_DRY=$2
    TDX_STATE_CUR="$TDX_RUNDIR/state.ini"
    TDX_STATE_LOCK="$TDX_RUNDIR/state.lock"
    if [[ -f $TDX_STATE_REAL ]]; then
        cp "$TDX_STATE_REAL" "$TDX_STATE_CUR" || tdx_config_error "cannot read state file $TDX_STATE_REAL"
    else
        : >"$TDX_STATE_CUR"
    fi
    tdx_state_ops 0 "pending_all" "ensure${TDX_US}_run"
}

tdx_state_save() {
    [[ $TDX_STATE_DRY == 1 ]] && return 0
    tdx_atomic_write "$TDX_STATE_REAL" <"$TDX_STATE_CUR"
}

# tdx_state_ops SAVE OP... (each OP: fields joined by \037)
tdx_state_ops() {
    local save=$1 ops="$TDX_RUNDIR/ops.${BASHPID:-$$}" new="$TDX_RUNDIR/state.${BASHPID:-$$}.new" rc=0
    shift
    tdx_lock "$TDX_STATE_LOCK"
    printf '%s\n' "$@" >"$ops"
    if tdx_awk -v mode=apply -f "$TDX_LIB/state.awk" "$ops" "$TDX_STATE_CUR" >"$new" && mv -f "$new" "$TDX_STATE_CUR"; then
        if [[ $save == 1 ]]; then tdx_state_save || rc=1; fi
    else
        rc=1
    fi
    rm -f "$ops" "$new"
    tdx_unlock "$TDX_STATE_LOCK"
    return $rc
}

# tdx_state_update SECTION [--nosave] key=value ... -key (removes key)
tdx_state_update() {
    local sec=$1 save=1 a k v
    shift
    local -a ops=()
    for a; do
        case $a in
            --nosave) save=0 ;;
            -*) ops+=("del$TDX_US$sec$TDX_US${a#-}") ;;
            *)
                k=${a%%=*}
                v=${a#*=}
                v=${v//$'\n'/ }
                ops+=("set$TDX_US$sec$TDX_US$k$TDX_US$v")
                ;;
        esac
    done
    ((${#ops[@]})) || ops=("ensure$TDX_US$sec")
    tdx_state_ops "$save" "${ops[@]}"
}

tdx_state_get() {
    REPLY=$(TDX_SEC=$1 TDX_KEY=$2 tdx_awk -v mode=get -f "$TDX_LIB/state.awk" "$TDX_STATE_CUR")
    [[ -z $REPLY ]] && REPLY=${3:-}
}

declare -gA ST_SEC=()
tdx_state_section() {
    local line
    ST_SEC=()
    while IFS= read -r line; do
        [[ -n $line ]] && ST_SEC["${line%%"$TDX_US"*}"]=${line#*"$TDX_US"}
    done < <(TDX_SEC=$1 tdx_awk -v mode=section -f "$TDX_LIB/state.awk" "$TDX_STATE_CUR")
}

tdx_state_sections() { tdx_awk -v mode=sections -f "$TDX_LIB/state.awk" "$TDX_STATE_CUR"; }

# Sorted chunk section names of a table, one per line.
tdx_state_chunk_sections() {
    tdx_state_sections | TDX_PRE="$1/part" tdx_awk 'index($0, ENVIRON["TDX_PRE"]) == 1' | LC_ALL=C sort
}

tdx_state_table_keys() { tdx_state_sections | tdx_awk '$0 != "_run" && index($0, "/part") == 0'; }
