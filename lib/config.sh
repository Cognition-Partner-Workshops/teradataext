# shellcheck shell=bash
# Configuration: INI reading, settings validation, source tables.

declare -gA INI_V=()
declare -ga INI_SECS=()
TDX_INI_ERR=""

# Read an INI file into INI_V["section<US>key"] and INI_SECS (in file order).
tdx_ini_read() {
    local file=$1 out line kind sec key val
    INI_V=()
    INI_SECS=()
    TDX_INI_ERR=""
    out=$(tdx_awk -f "$TDX_LIB/ini.awk" "$file" 2>&1)
    local rc=$?
    while IFS= read -r line; do
        kind=${line%%"$TDX_US"*}
        line=${line#*"$TDX_US"}
        case $kind in
            S) INI_SECS+=("$line") ;;
            K)
                sec=${line%%"$TDX_US"*}
                line=${line#*"$TDX_US"}
                key=${line%%"$TDX_US"*}
                val=${line#*"$TDX_US"}
                INI_V["$sec$TDX_US$key"]=${val//$'\036'/$'\n'}
                ;;
            E) TDX_INI_ERR=$line ;;
        esac
    done <<<"$out"
    [[ $rc -eq 0 && -z $TDX_INI_ERR ]] || { TDX_INI_ERR=${TDX_INI_ERR:-$out}; return 1; }
}

tdx_ini_has_section() {
    local s
    for s in "${INI_SECS[@]}"; do [[ $s == "$1" ]] && return 0; done
    return 1
}

tdx_ini_has() { [[ -n ${INI_V["$1$TDX_US$2"]+x} ]]; }

# REPLY = stripped value or default
tdx_get() {
    if tdx_ini_has "$1" "$2"; then REPLY=$(tdx_strip "${INI_V["$1$TDX_US$2"]}"); else REPLY=$3; fi
}

tdx_get_int() {
    tdx_get "$1" "$2" "$3"
    tdx_is_int "$REPLY" || tdx_config_error "[$1] $2 must be an integer, got $(tdx_repr "$REPLY")"
    REPLY=$(tdx_int "$REPLY")
}

tdx_get_bool() {
    local def=false
    [[ $3 == 1 || $3 == true ]] && def=true
    tdx_get "$1" "$2" "$def"
    case ${REPLY,,} in
        1 | true | yes | on) REPLY=1 ;;
        0 | false | no | off) REPLY=0 ;;
        *) tdx_config_error "[$1] $2 must be true/false, got $(tdx_repr "${REPLY,,}")" ;;
    esac
}

tdx_get_float() {
    tdx_get "$1" "$2" "$3"
    [[ -z $REPLY ]] && REPLY=0
    [[ $REPLY =~ ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$ ]] ||
        tdx_config_error "[$1] $2 must be a number, got $(tdx_repr "$REPLY")"
}

tdx_expanduser() {
    case $1 in
        "~") printf '%s' "$HOME" ;;
        "~/"*) printf '%s' "$HOME/${1#\~/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Absolute, symlink-free directory path (the path itself must exist).
tdx_realdir() { (cd "$1" 2>/dev/null && pwd -P); }

tdx_cpu_count() {
    local n
    n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || n=""
    [[ $n =~ ^[0-9]+$ && $n -gt 0 ]] || n=$(getconf NPROCESSORS_ONLN 2>/dev/null) || n=""
    [[ $n =~ ^[0-9]+$ && $n -gt 0 ]] || n=$(nproc 2>/dev/null) || n=""
    [[ $n =~ ^[0-9]+$ && $n -gt 0 ]] || n=1
    printf '%s' "$n"
}

tdx_resolve_parallel() {
    local raw value
    raw=$(tdx_strip "$1")
    raw=${raw,,}
    if [[ -z $raw || $raw == auto ]]; then
        value=0
    elif tdx_is_int "$raw"; then
        value=$(tdx_int "$raw")
    else
        tdx_config_error "parallel must be an integer or 'auto', got $(tdx_repr "$raw")"
    fi
    if ((value <= 0)); then
        value=$(tdx_cpu_count)
        ((value > $2)) && value=$2
    fi
    ((value < 1)) && value=1
    S_parallel=$value
}

# Settings become S_<key> globals.
tdx_load_settings() {
    local config=$1 override=$2 have_override=$3 cfgdir base root
    [[ -f $config ]] || tdx_config_error "config file not found: $config"
    tdx_ini_read "$config" || tdx_config_error "cannot parse $config: $TDX_INI_ERR"
    local sec
    for sec in teradata extract; do
        tdx_ini_has_section "$sec" || tdx_config_error "$config: missing [$sec] section"
    done
    cfgdir=$(tdx_realdir "$(dirname "$config")")
    S_config_path="$cfgdir/${config##*/}"
    tdx_get paths base_dir ""
    base=$REPLY
    if [[ -n $base ]]; then
        root=$(tdx_expanduser "$base")
        if [[ $root != /* ]]; then
            root="$(dirname "$cfgdir")/$root"
            [[ -d $root ]] && root=$(tdx_realdir "$root")
        fi
    else
        root=$(dirname "$cfgdir")
    fi
    S_root=$root

    tdx_get teradata host ""
    S_host=$REPLY
    [[ -n $S_host ]] || tdx_config_error "[teradata] host is required"
    tdx_get extract file_format pipe-delimited
    [[ ${REPLY,,} == pipe-delimited ]] ||
        tdx_config_error "[extract] file_format $(tdx_repr "${REPLY,,}") not supported (pipe-delimited only)"
    tdx_get teradata session_charset ASCII
    S_session_charset=${REPLY^^}
    S_session_charset=${S_session_charset//-/}
    [[ $S_session_charset == ASCII || $S_session_charset == UTF8 ]] ||
        tdx_config_error "[teradata] session_charset must be ASCII or UTF8"
    tdx_get_int extract max_sessions 4
    S_max_sessions=$REPLY
    tdx_get_int extract min_sessions 1
    S_min_sessions=$REPLY
    if ((S_max_sessions < 1 || S_min_sessions < 1 || S_min_sessions > S_max_sessions)); then
        tdx_config_error "[extract] need 1 <= min_sessions <= max_sessions"
    fi
    tdx_get extract char_trim right
    S_char_trim=${REPLY,,}
    [[ $S_char_trim == right || $S_char_trim == both || $S_char_trim == none ]] ||
        tdx_config_error "[extract] char_trim must be right, both or none"
    tdx_get extract row_estimate stats
    S_row_estimate=${REPLY,,}
    [[ $S_row_estimate == stats || $S_row_estimate == count ]] ||
        tdx_config_error "[extract] row_estimate must be stats or count"
    tdx_get format delimiter "|"
    S_delimiter=$REPLY
    tdx_get format escape_char "\\"
    S_escape_char=$REPLY
    if ((${#S_delimiter} != 1 || ${#S_escape_char} != 1)) || [[ $S_delimiter == "$S_escape_char" ]]; then
        tdx_config_error "[format] delimiter and escape_char must be distinct single characters"
    fi
    tdx_get format null_sentinel '\N'
    S_null_sentinel=$REPLY
    tdx_get format empty_sentinel '\E'
    S_empty_sentinel=$REPLY
    if [[ -z $S_null_sentinel || $S_null_sentinel == "$S_empty_sentinel" ]]; then
        tdx_config_error "[format] null_sentinel must be non-empty and differ from empty_sentinel"
    fi
    tdx_get extract session_limit_errors 2633,3130
    local x codes=""
    for x in ${REPLY//,/ }; do
        tdx_is_int "$x" || tdx_config_error "[extract] session_limit_errors: invalid code $(tdx_repr "$x")"
        codes+="${codes:+,}$(tdx_int "$x")"
    done
    S_session_limit_errors=$codes
    tdx_get extract session_limit_patterns ""
    local pats="" p
    local IFS=,
    for p in $REPLY; do
        p=$(tdx_strip "$p")
        [[ -n $p ]] && pats+="${pats:+$TDX_US}${p,,}"
    done
    unset IFS
    S_session_limit_patterns=$pats

    tdx_get_int teradata port 1025
    S_port=$REPLY
    tdx_get teradata logmech ""
    S_logmech=$REPLY
    tdx_get teradata credentials_file ""
    S_credentials_file=$REPLY
    tdx_get teradata fexp_path fexp
    S_fexp_path=${TDX_FEXP:-$REPLY}
    tdx_get teradata bteq_path bteq
    S_bteq_path=${TDX_BTEQ:-$REPLY}
    tdx_get teradata logtable_database ""
    S_logtable_database=$REPLY
    tdx_get_bool teradata connect_check 1
    S_connect_check=$REPLY
    tdx_path_setting output_dir data
    S_output_dir=$REPLY
    tdx_path_setting metadata_dir metadata
    S_metadata_dir=$REPLY
    tdx_path_setting log_dir logs
    S_log_dir=$REPLY
    tdx_path_setting work_dir work
    S_work_dir=$REPLY
    tdx_path_setting source_tables_file config/source_tables.ini
    S_source_tables_file=$REPLY
    tdx_path_setting process_state_file config/process_state.ini
    S_process_state_file=$REPLY
    if [[ $have_override == 1 ]]; then
        tdx_resolve_parallel "$override" "$S_max_sessions"
    else
        tdx_get extract parallel 1
        tdx_resolve_parallel "$REPLY" "$S_max_sessions"
    fi
    tdx_get_int extract chunk_threshold_rows 10000000
    S_chunk_threshold_rows=$REPLY
    tdx_get_int extract chunk_rows 5000000
    S_chunk_rows=$((REPLY < 1 ? 1 : REPLY))
    tdx_get_int extract max_chunks 64
    S_max_chunks=$((REPLY < 2 ? 2 : REPLY))
    tdx_get_int extract small_table_rows 100000
    S_small_table_rows=$REPLY
    tdx_get_int extract lob_max_length 32000
    S_lob_max_length=$REPLY
    tdx_get_int extract max_row_length 63999
    S_max_row_length=$REPLY
    tdx_get_bool extract zip_on_complete 1
    S_zip_on_complete=$REPLY
    tdx_get_bool extract keep_raw_after_zip 0
    S_keep_raw_after_zip=$REPLY
    tdx_get_int extract retry_attempts 3
    S_retry_attempts=$((REPLY < 0 ? 0 : REPLY))
    tdx_get_float extract retry_delay_seconds 60
    S_retry_delay_seconds=$REPLY
    tdx_get_bool extract bteq_fallback 1
    S_bteq_fallback=$REPLY
    tdx_get_float extract job_timeout_seconds 0
    S_job_timeout_seconds=$(tdx_awk -v x="$REPLY" 'BEGIN { if (x <= 0) print 0; else { i = int(x); if (i < x) i++; print i } }')
    tdx_get extract log_tool_output masked
    S_log_tool_output=${REPLY,,}
    tdx_get format big_decimal_quote '"'
    S_big_decimal_quote=$REPLY
    tdx_get_int format big_decimal_threshold 18
    S_big_decimal_threshold=$REPLY
    case $S_log_tool_output in
        masked | errors | none) ;;
        *) tdx_config_error "[extract] log_tool_output must be one of: masked, errors, none" ;;
    esac
    if ((S_lob_max_length < 1 || S_max_row_length < 1)); then
        tdx_config_error "[extract] lob_max_length and max_row_length must be positive"
    fi
    S_lock_dir="$S_work_dir/.process_state.lock"
    S_audit_file="$S_metadata_dir/audit.log"
}

tdx_path_setting() {
    local p
    tdx_get paths "$1" "$2"
    p=${REPLY:-$2}
    p=$(tdx_expanduser "$p")
    [[ $p == /* ]] || p="$S_root/$p"
    REPLY=$p
}

# Reject statement separators and comments outside string literals in a where filter.
# Prints the reason and returns 1 when the filter is not allowed.
tdx_check_where() {
    local why
    why=$(printf '%s\n' "$1" | tdx_awk -f "$TDX_LIB/where.awk" 2>/dev/null)
    [[ $why == OK ]] && return 0
    printf '%s\n' "${why:-cannot be validated (awk failed)}"
    return 1
}

declare -ga T_KEYS=()
declare -gA T_DB=() T_TABLE=() T_CDC=() T_CHUNK=() T_WHERE=() T_LABEL=()

# table = {A, B, C} (braces optional; commas or newlines) -> TL (array). Returns 1 for a
# single plain name (one-table section), 2 for a malformed list (TDX_ERR).
tdx_table_list() {
    local v=$1 item
    TL=()
    if [[ $v != *","* && $v != *$'\n'* && $v != "{"* && $v != *"}" ]]; then return 1; fi
    if [[ $v == "{"* || $v == *"}" ]]; then
        [[ $v == "{"*"}" ]] || { TDX_ERR="unbalanced braces in table list"; return 2; }
        v=${v:1:${#v}-2}
    fi
    v=${v//$',\n'/,}
    v=${v//$'\n,'/,}
    v=${v//$'\n'/,}
    v+=,
    while [[ $v == *,* ]]; do
        item=${v%%,*}
        v=${v#*,}
        item=$(tdx_strip "$item")
        [[ -n $item ]] || { TDX_ERR="empty table name in table list"; return 2; }
        [[ $item == *[{}]* ]] && { TDX_ERR="unexpected brace in table list"; return 2; }
        TL+=("$item")
    done
    ((${#TL[@]})) || { TDX_ERR="empty table list"; return 2; }
}

# REPLY = validated where filter of a section ("" if none); continuation lines are joined
# with a single space.
tdx_section_where() {
    local path=$1 label=$2 why
    tdx_get "$label" where ""
    REPLY=${REPLY//$'\n'/ }
    if [[ -n $REPLY ]] && ! why=$(tdx_check_where "$REPLY"); then
        tdx_config_error "$path [$label]: where: $why (one boolean condition only)"
    fi
}

# Copy the optional per-table settings of a one-table section into the T_* arrays.
# A one-table where replaces the list's where ($4), an empty "where =" clears it; without
# a where key the list's where is kept.
tdx_source_opts() {
    local path=$1 label=$2 key=$3 list_where=${4:-}
    tdx_section_where "$path" "$label"
    tdx_ini_has "$label" where || REPLY=$list_where
    T_WHERE[$key]=$REPLY
    tdx_get "$label" cdc_column ""
    T_CDC[$key]=$REPLY
    tdx_get "$label" chunk_column ""
    T_CHUNK[$key]=$REPLY
}

# Two section forms:
#   list section:       database + table = {A, B, ...} [+ where, enable_for_all]
#   one-table section:  database + table = NAME [+ cdc_column, chunk_column, where, enabled]
# A list's where applies to every listed table when enable_for_all is true (default).
# A table in a list may also have a one-table section: database/table come from the list,
# the other settings from the one-table section, whose where replaces the list's (a
# warning is logged).
tdx_load_sources() {
    local path=$1 label db tb key k t rc lwhere
    [[ -f $path ]] || tdx_config_error "source tables file not found: $path"
    tdx_ini_read "$path" || tdx_config_error "cannot parse $path: $TDX_INI_ERR"
    T_KEYS=()
    T_DB=() T_TABLE=() T_CDC=() T_CHUNK=() T_WHERE=() T_LABEL=()
    local -A list_of=() list_db=() list_tb=() single_of=()
    local -A is_list=()
    # pass 1: validate sections, index list members and one-table sections
    for label in "${INI_SECS[@]}"; do
        [[ $label == DEFAULT ]] && continue
        tdx_get "$label" database ""
        db=$REPLY
        tdx_ini_has "$label" table && tb=${INI_V["$label${TDX_US}table"]} || tb=""
        tb=$(tdx_strip "$tb")
        [[ -n $db && -n $tb ]] || tdx_config_error "$path [$label]: database and table are required"
        tdx_table_list "$tb"
        rc=$?
        if ((rc == 2)); then
            tdx_config_error "$path [$label]: table: $TDX_ERR"
        elif ((rc == 0)); then
            is_list[$label]=1
            for k in "${!INI_V[@]}"; do
                [[ ${k%%"$TDX_US"*} == "$label" ]] || continue
                case ${k#*"$TDX_US"} in
                    database | table | where | enable_for_all) ;;
                    *) tdx_config_error "$path [$label]: a table list section takes only database, table, where and enable_for_all, not ${k#*"$TDX_US"} (put it in a one-table section)" ;;
                esac
            done
            tdx_section_where "$path" "$label"
            tdx_get_bool "$label" enable_for_all 1
            for t in "${TL[@]}"; do
                key="$db.$t"
                key=${key^^}
                [[ -n ${list_of[$key]+x} ]] &&
                    tdx_config_error "$path: table $key listed twice ([${list_of[$key]}] and [$label])"
                list_of[$key]=$label
                list_db[$key]=$db
                list_tb[$key]=$t
            done
        fi
    done
    for label in "${INI_SECS[@]}"; do
        [[ $label == DEFAULT || -n ${is_list[$label]+x} ]] && continue
        tdx_get "$label" database ""
        key="$REPLY.$(tdx_strip "${INI_V["$label${TDX_US}table"]}")"
        key=${key^^}
        [[ -n ${single_of[$key]+x} ]] &&
            tdx_config_error "$path: table $key defined twice ([${single_of[$key]}] and [$label])"
        single_of[$key]=$label
    done
    # pass 2: build the work list in file order
    for label in "${INI_SECS[@]}"; do
        [[ $label == DEFAULT ]] && continue
        if [[ -n ${is_list[$label]+x} ]]; then
            tdx_table_list "$(tdx_strip "${INI_V["$label${TDX_US}table"]}")"
            tdx_get "$label" database ""
            db=$REPLY
            lwhere=""
            tdx_get_bool "$label" enable_for_all 1
            if [[ $REPLY == 1 ]]; then
                tdx_section_where "$path" "$label"
                lwhere=$REPLY
            fi
            for t in "${TL[@]}"; do
                key="$db.$t"
                key=${key^^}
                if [[ -n ${single_of[$key]+x} ]]; then
                    local s=${single_of[$key]}
                    tdx_warn "$path: $key is listed in [$label] and also defined in [$s]; database/table from [$label], other settings from [$s]"
                    tdx_get_bool "$s" enabled 1
                    [[ $REPLY == 1 ]] || continue
                    tdx_source_opts "$path" "$s" "$key" "$lwhere"
                else
                    T_WHERE[$key]=$lwhere T_CDC[$key]="" T_CHUNK[$key]=""
                fi
                T_DB[$key]=${list_db[$key]}
                T_TABLE[$key]=${list_tb[$key]}
                T_LABEL[$key]=$label
                T_KEYS+=("$key")
            done
            continue
        fi
        tdx_get "$label" database ""
        db=$REPLY
        tdx_get "$label" table ""
        tb=$REPLY
        key="$db.$tb"
        key=${key^^}
        [[ -n ${list_of[$key]+x} ]] && continue
        tdx_get_bool "$label" enabled 1
        [[ $REPLY == 1 ]] || continue
        tdx_source_opts "$path" "$label" "$key"
        T_DB[$key]=$db
        T_TABLE[$key]=$tb
        T_LABEL[$key]=$label
        T_KEYS+=("$key")
    done
}

tdx_table_base() { tdx_safe_name "${T_DB[$1]}" "${T_TABLE[$1]}"; }
tdx_table_fqn() { printf '%s.%s' "$(tdx_sql_ident "${T_DB[$1]}")" "$(tdx_sql_ident "${T_TABLE[$1]}")"; }
