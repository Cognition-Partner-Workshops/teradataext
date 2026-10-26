# shellcheck shell=bash
# Internal-query SQL, CDC predicates, range/hash chunk predicates, meta files.

# tdx_wrap_fields "untrimmed1 untrimmed2" EXPR... -> REPLY (single VARCHAR row, NULL -> \N, | escaped).
# Each field is cast to VARCHAR(512): OREPLACE returns VARCHAR(8000) UNICODE, and eight such fields
# joined by || exceed Teradata's 32000-character limit (Failure 3798).
tdx_wrap_fields() {
    local untrimmed=" $1 " e inner out=""
    shift
    for e; do
        if [[ $untrimmed == *" $e "* ]]; then inner="CAST($e AS VARCHAR(256))"; else inner="TRIM(CAST($e AS VARCHAR(256)))"; fi
        [[ -n $out ]] && out+=" || '|' || "
        out+="COALESCE(CAST(OREPLACE(OREPLACE($inner, '\\', '\\\\'), '|', '\\|') AS VARCHAR(512)), '\\N')"
    done
    REPLY=$out
}

# tdx_meta_int EXPR -> REPLY: an integer metadata value without digit grouping (DBC formats
# ColumnId as 1,025).
tdx_meta_int() { REPLY="CAST(CAST($1 AS BIGINT) AS FORMAT '-(19)9')"; }

# tdx_marker KIND KEY [name value]... -> REPLY
tdx_marker() {
    local kind=$1 key=$2 out k v
    shift 2
    out="/* TDX query=$kind db=${T_DB[$key]} table=${T_TABLE[$key]}"
    while (($# >= 2)); do
        k=$1
        v=$2
        shift 2
        [[ -z $v ]] && continue
        v=${v//"*/"/}
        if [[ $v == *" "* || $v == *","* ]]; then out+=" $k=\"$v\""; else out+=" $k=$v"; fi
    done
    REPLY="$out */"
}

tdx_where_sql() {
    local p out=""
    for p; do
        [[ -z $p ]] && continue
        if [[ -z $out ]]; then out=" WHERE ($p)"; else out+=" AND ($p)"; fi
    done
    REPLY=$out
}

# ---------------------------------------------------------------- CDC (by type code + column name)
tdx_cdc_expr() {
    local q
    q=$(tdx_sql_ident "$2")
    if [[ $1 == SZ ]]; then REPLY="CAST(($q AT TIME ZONE INTERVAL '00:00' HOUR TO MINUTE) AS TIMESTAMP(6))"; else REPLY=$q; fi
}

# 1 + TDX_ERR when the watermark is not valid for a numeric column.
tdx_cdc_literal() {
    local tc=$1 name=$2 v=$3
    case $tc in
        DA) REPLY="DATE $(tdx_sql_str "$v")" ;;
        TS | SZ) REPLY="TIMESTAMP $(tdx_sql_str "$v")" ;;
        *)
            if [[ ! $v =~ ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$ ]]; then
                TDX_ERR="invalid numeric watermark $(tdx_repr "$v") for $name"
                return 1
            fi
            REPLY=$v
            ;;
    esac
}

# CDC predicate; the initial (no watermark) extract also takes rows whose CDC value is NULL.
tdx_cdc_window_pred() {
    local tc=$1 name=$2 lo=$3 hi=$4 e upper
    REPLY=""
    [[ -z $hi ]] && return 0
    tdx_cdc_expr "$tc" "$name"
    e=$REPLY
    tdx_cdc_literal "$tc" "$name" "$hi" || return 1
    upper="$e <= $REPLY"
    if [[ -z $lo ]]; then
        REPLY="$upper OR $(tdx_sql_ident "$name") IS NULL"
        return 0
    fi
    tdx_cdc_literal "$tc" "$name" "$lo" || return 1
    REPLY="$e > $REPLY AND $upper"
}

tdx_cdc_max_sql() {
    tdx_cdc_expr "$1" "$2"
    case $1 in
        DA) REPLY="CAST(CAST(MAX($REPLY) AS FORMAT 'YYYY-MM-DD') AS CHAR(10))" ;;
        TS | SZ) REPLY="CAST(CAST(CAST(MAX($REPLY) AS TIMESTAMP(6)) AS FORMAT 'YYYY-MM-DDBHH:MI:SS.S(6)') AS CHAR(26))" ;;
        *) tdx_num_text "MAX($REPLY)" "$1" "$3" "$4" ;;
    esac
}

# ---------------------------------------------------------------- range chunks
tdx_days_from_civil() {
    local y=$((10#$1)) m=$((10#$2)) d=$((10#$3)) era yoe doy doe mm
    ((m <= 2)) && y=$((y - 1))
    if ((y >= 0)); then era=$((y / 400)); else era=$(((y - 399) / 400)); fi
    yoe=$((y - era * 400))
    if ((m > 2)); then mm=$((m - 3)); else mm=$((m + 9)); fi
    doy=$(((153 * mm + 2) / 5 + d - 1))
    doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
    REPLY=$((era * 146097 + doe - 719468))
}

tdx_civil_from_days() {
    local z=$(($1 + 719468)) era doe yoe y doy mp d m
    if ((z >= 0)); then era=$((z / 146097)); else era=$(((z - 146096) / 146097)); fi
    doe=$((z - era * 146097))
    yoe=$(((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365))
    y=$((yoe + era * 400))
    doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100)))
    mp=$(((5 * doy + 2) / 153))
    d=$((doy - (153 * mp + 2) / 5 + 1))
    if ((mp < 10)); then m=$((mp + 3)); else m=$((mp - 9)); fi
    ((m <= 2)) && y=$((y + 1))
    printf -v REPLY '%04d-%02d-%02d' "$y" "$m" "$d"
}

# bc with continuation lines joined and ".5"/"-.5" written as "0.5"/"-0.5".
tdx_bc() {
    command -v bc >/dev/null 2>&1 || { TDX_ERR="bc is required for range chunks on this key"; return 1; }
    bc | tdx_awk '{ s = s $0 } /\\$/ { sub(/\\$/, "", s); next } { if (s ~ /^-?\./) sub(/\./, "0.", s); print s; s = "" }'
}

# ceil(k * span / n) for 0 < k < n without 64-bit overflow when span fits
tdx_ceil_frac() {
    local k=$1 span=$2 n=$3 q r t
    q=$((span / n))
    r=$((span % n))
    t=$((k * r))
    REPLY=$((k * q + t / n + (t % n ? 1 : 0)))
}

# tdx_range_predicates TC FRAC NAME LO HI N -> RP (array of predicates)
tdx_range_predicates() {
    local tc=$1 frac=$2 name=$3 lo=$4 hi=$5 n=$6 q a b k x prev="" out
    local -a lits=()
    q=$(tdx_sql_ident "$name")
    RP=()
    if [[ $tc == DA ]]; then
        [[ $lo =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || { TDX_ERR="Invalid isoformat string: $(tdx_repr "$lo")"; return 1; }
        tdx_days_from_civil "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        a=$REPLY
        [[ $hi =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || { TDX_ERR="Invalid isoformat string: $(tdx_repr "$hi")"; return 1; }
        tdx_days_from_civil "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        b=$REPLY
        ((n > b - a + 1)) && n=$((b - a + 1))
        ((n < 1)) && n=1
        for ((k = 1; k < n; k++)); do
            tdx_ceil_frac "$k" $((b - a + 1)) "$n"
            tdx_civil_from_days $((a + REPLY))
            x="DATE '$REPLY'"
            [[ $x != "$prev" ]] && lits+=("$x")
            prev=$x
        done
    elif [[ -n ${TDX_INT_TYPES[$tc]+x} ]] || { [[ $tc == D || $tc == N ]] && ((frac == 0)); }; then
        a=$(tdx_decint "$lo") && b=$(tdx_decint "$hi") || { TDX_ERR="unexpected numeric value $(tdx_repr "$lo")"; return 1; }
        if ((${#a} <= 19 && ${#b} <= 19)) && (((a < 0 ? -a : a) < 4000000000000000000 && (b < 0 ? -b : b) < 4000000000000000000)); then
            ((n > b - a + 1)) && n=$((b - a + 1))
            ((n < 1)) && n=1
            for ((k = 1; k < n; k++)); do
                tdx_ceil_frac "$k" $((b - a + 1)) "$n"
                x=$((a + REPLY))
                [[ $x != "$prev" ]] && lits+=("$x")
                prev=$x
            done
        else
            local span
            span=$(printf '%s\n' "$b - $a + 1" | tdx_bc) || return 1
            out=$(printf '%s\n' "span = $span; n = $n; if (n > span) n = span; if (n < 1) n = 1" \
                "for (k = 1; k < n; k++) { t = k * span; c = t / n; if (c * n < t) c = c + 1; $a + c }" | tdx_bc) || return 1
            while IFS= read -r x; do
                [[ -z $x ]] && continue
                [[ $x != "$prev" ]] && lits+=("$x")
                prev=$x
            done <<<"$out"
        fi
    else
        local sc=$(((frac > 0 ? frac : 0) + 10))
        [[ $lo =~ ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$ && $hi =~ ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$ ]] ||
            { TDX_ERR="unexpected numeric value $(tdx_repr "$lo")"; return 1; }
        out=$(printf '%s\n' "scale = $sc; a = ${lo#+}; b = ${hi#+}; n = $n; if (a == b) n = 1" \
            "s = (b - a) / n; for (k = 1; k < n; k++) { a + s * k }" | tdx_bc) || return 1
        while IFS= read -r x; do
            [[ -z $x ]] && continue
            [[ $x != "$prev" ]] && lits+=("$x")
            prev=$x
        done <<<"$out"
    fi
    if ((${#lits[@]} == 0)); then
        RP=("")
        return 0
    fi
    RP=("$q < ${lits[0]} OR $q IS NULL")
    for ((k = 1; k < ${#lits[@]}; k++)); do
        RP+=("$q >= ${lits[k - 1]} AND $q < ${lits[k]}")
    done
    RP+=("$q >= ${lits[${#lits[@]} - 1]}")
}

# ---------------------------------------------------------------- meta file
# tdx_write_meta PATH KEY STRATEGY CHUNK_COL EST_SOURCE PRIMARY_INDEX(comma list) NCHUNKS
tdx_write_meta() {
    local path=$1 key=$2 strategy=$3 chunk_col=$4 est_source=$5 pi=$6 nchunks=$7 i method
    if [[ $W_lob == 1 ]]; then method=bteq; else method="fexp/bteq by size"; fi
    {
        printf '# Generated by teradata_extract for %s\n' "$key"
        printf '[table]\n'
        printf 'database = %s\n' "${T_DB[$key]}"
        printf 'table = %s\n' "${T_TABLE[$key]}"
        printf 'extracted_at = %s\n' "$(tdx_iso_now)"
        printf 'column_count = %s\n' "$NCOLS"
        printf 'row_estimate = %s\n' "$W_est_rows"
        printf 'row_estimate_source = %s\n' "$est_source"
        printf 'primary_index = %s\n' "$pi"
        printf 'chunk_strategy = %s\n' "$strategy"
        printf 'chunk_column = %s\n' "$chunk_col"
        printf 'chunk_count = %s\n' "$nchunks"
        printf 'cdc_column = %s\n' "${T_CDC[$key]}"
        printf 'where = %s\n' "${T_WHERE[$key]}"
        printf 'session_charset = %s\n' "$S_session_charset"
        printf 'file_format = pipe-delimited\n'
        printf 'delimiter = %s\n' "$S_delimiter"
        printf 'null_sentinel = %s\n' "$S_null_sentinel"
        printf 'empty_sentinel = %s\n' "$S_empty_sentinel"
        printf 'escape_char = %s\n' "$S_escape_char"
        printf 'escaped_characters = %s %s CR LF\n' "$S_escape_char" "$S_delimiter"
        printf 'record_terminator = LF\n'
        printf 'timezone_policy = UTC\n'
        printf 'export_method = %s\n' "$method"
        printf '\n'
        for ((i = 1; i <= NCOLS; i++)); do
            printf '[column.%03d]\n' "$i"
            printf 'name = %s\n' "${C_name[i]}"
            printf 'position = %s\n' "$i"
            tdx_source_type "$i"
            printf 'source_type = %s\n' "$REPLY"
            printf 'td_type_code = %s\n' "${C_tc[i]}"
            if [[ ${C_null[i]} == 1 ]]; then printf 'nullable = yes\n'; else printf 'nullable = no\n'; fi
            tdx_col_charset "$i"
            printf 'char_set = %s\n' "${REPLY:-n/a}"
            printf 'output_encoding = %s\n' "${R_enc[i]}"
            printf 'redshift_type = %s\n' "${R_rs[i]:-n/a}"
            printf 'null_sentinel = %s\n' "$S_null_sentinel"
            if [[ ${R_emp[i]} == 1 ]]; then
                printf 'empty_sentinel = %s\n' "${S_empty_sentinel:-(empty)}"
                printf 'empty_string_possible = yes\n'
            else
                printf 'empty_sentinel = n/a\n'
                printf 'empty_string_possible = no\n'
            fi
            [[ ${C_tc[i]} == SZ || ${C_tc[i]} == TZ ]] && printf 'source_timezone = per-value offset, converted to UTC\n'
            [[ -n ${R_notes[i]} ]] && printf 'notes = %s\n' "${R_notes[i]}"
            printf '\n'
        done
    } | tdx_atomic_write "$path"
}
