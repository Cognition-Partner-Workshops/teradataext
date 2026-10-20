# shellcheck shell=bash
# Teradata column metadata -> output encoding, Redshift type and the SQL expression per column.
# Columns: C_name C_tc C_len C_tot C_frac C_null C_ct (1-based, NCOLS).
# Rules:   R_enc R_rs R_expr R_max R_lob R_emp R_notes.

declare -gA TDX_TYPE_NAMES=(
    [I1]=BYTEINT [I2]=SMALLINT [I]=INTEGER [I8]=BIGINT [D]=DECIMAL [N]=NUMBER [F]=FLOAT [DA]=DATE
    [AT]=TIME [TZ]="TIME WITH TIME ZONE" [TS]=TIMESTAMP [SZ]="TIMESTAMP WITH TIME ZONE" [CF]=CHAR
    [CV]=VARCHAR [CO]=CLOB [BF]=BYTE [BV]=VARBYTE [BO]=BLOB [JN]=JSON [XM]=XML [YR]="INTERVAL YEAR"
    [YM]="INTERVAL YEAR TO MONTH" [MO]="INTERVAL MONTH" [DY]="INTERVAL DAY" [DH]="INTERVAL DAY TO HOUR"
    [DM]="INTERVAL DAY TO MINUTE" [DS]="INTERVAL DAY TO SECOND" [HR]="INTERVAL HOUR"
    [HM]="INTERVAL HOUR TO MINUTE" [HS]="INTERVAL HOUR TO SECOND" [MI]="INTERVAL MINUTE"
    [MS]="INTERVAL MINUTE TO SECOND" [SC]="INTERVAL SECOND" [PD]="PERIOD(DATE)" [PT]="PERIOD(TIME)"
    [PZ]="PERIOD(TIME WITH TIME ZONE)" [PS]="PERIOD(TIMESTAMP)" [PM]="PERIOD(TIMESTAMP WITH TIME ZONE)"
)
declare -gA TDX_INT_TYPES=([I1]=SMALLINT [I2]=SMALLINT [I]=INTEGER [I8]=BIGINT)
declare -gA TDX_CHARSET_NAMES=([1]=LATIN [2]=UNICODE [3]=KANJISJIS [4]=GRAPHIC [5]=KANJI1)
TDX_INTERVAL_TYPES=" YR YM MO DY DH DM DS HR HM HS MI MS SC "
TDX_PERIOD_TYPES=" PD PT PZ PS PM "
TDX_CHUNKABLE_TYPES=" I1 I2 I I8 D N DA "
TDX_CDC_TYPES=" I1 I2 I I8 D N DA TS SZ "

tdx_in() { [[ $2 == *" $1 "* ]]; }

tdx_col_charset() {
    local i=$1
    REPLY=""
    if tdx_in "${C_tc[i]}" " CF CV CO "; then REPLY=${TDX_CHARSET_NAMES[${C_ct[i]}]:-}; fi
}

tdx_source_type() {
    local i=$1 c=${C_tc[$1]} p=${C_tot[$1]} s=${C_frac[$1]} name n cs base
    name=${TDX_TYPE_NAMES[$c]:-UNKNOWN($c)}
    if [[ $c == D || $c == N ]]; then
        if ((p > 0 && s >= 0)); then REPLY="$name($p,$s)"; else REPLY="$name(*)"; fi
    elif tdx_in "$c" " CF CV BF BV CO BO "; then
        n=${C_len[i]}
        if tdx_in "$c" " CF CV CO " && [[ ${C_ct[i]} == 2 ]]; then n=$((n / 2)); fi
        tdx_col_charset "$i"
        cs=""
        [[ -n $REPLY ]] && cs=" CHARACTER SET $REPLY"
        REPLY="$name($n)$cs"
    elif tdx_in "$c" " TS SZ AT TZ "; then
        base=${name%% *}
        REPLY="$base($((s > 0 ? s : 0)))${name#"$base"}"
    else
        REPLY=$name
    fi
}

tdx_esc_sql() {
    local x=$1 e d
    e=$(tdx_sql_str "$S_escape_char")
    d=$(tdx_sql_str "$S_delimiter")
    x="OREPLACE($x, $e, $(tdx_sql_str "$S_escape_char$S_escape_char"))"
    x="OREPLACE($x, $d, $(tdx_sql_str "$S_escape_char$S_delimiter"))"
    x="OREPLACE($x, '0D'XC, $e || '0D'XC)"
    REPLY="OREPLACE($x, '0A'XC, $e || '0A'XC)"
}

tdx_text_value() {
    local col=$1 text=$2 lenfn=$3 out
    out="CASE WHEN $col IS NULL THEN $(tdx_sql_str "$S_null_sentinel")"
    [[ -n $S_empty_sentinel ]] && out+=" WHEN $lenfn($text) = 0 THEN $(tdx_sql_str "$S_empty_sentinel")"
    tdx_esc_sql "$text"
    REPLY="$out ELSE $REPLY END"
}

tdx_plain_value() { REPLY="CASE WHEN $1 IS NULL THEN $(tdx_sql_str "$S_null_sentinel") ELSE $2 END"; }

tdx_dt_format() {
    local f=""
    (($1 > 0)) && f=".S($1)"
    REPLY=""
    [[ $2 == 1 ]] && REPLY="YYYY-MM-DDB"
    REPLY+="HH:MI:SS$f"
}

tdx_rule() { # i enc rs max lob emp notes
    R_enc[$1]=$2
    R_rs[$1]=$3
    R_max[$1]=$4
    R_lob[$1]=$5
    R_emp[$1]=$6
    R_notes[$1]=$7
    R_expr[$1]=""
}

tdx_build_rule() {
    local i=$1 c=${C_tc[$1]} q p=${C_tot[$1]} sc=${C_frac[$1]} ct=${C_ct[$1]} text
    q=$(tdx_sql_ident "${C_name[i]}")
    if [[ -n ${TDX_INT_TYPES[$c]+x} ]]; then
        tdx_rule "$i" int_text "${TDX_INT_TYPES[$c]}" 20 0 0 ""
        tdx_plain_value "$q" "TRIM(CAST($q AS VARCHAR(25)))"
        R_expr[i]=$REPLY
    elif [[ $c == D || $c == N ]]; then
        local bounded=0 big=0 fmt rs width notes=""
        ((p > 0 && p <= 38 && sc >= 0 && sc <= p)) && bounded=1
        ((bounded == 0 || p > S_big_decimal_threshold)) && big=1
        if ((bounded)); then
            fmt="-($((p - sc > 1 ? p - sc : 1)))9"
            ((sc)) && fmt+=".9($sc)"
            text="TRIM(CAST(CAST($q AS FORMAT '$fmt') AS VARCHAR($((p + 3)))))"
            rs="DECIMAL($p,$sc)"
            width=$((p + 3))
        else
            text="TRIM(CAST($q AS VARCHAR(60)))"
            rs="VARCHAR(64)"
            width=60
            notes="unbounded NUMBER exported as text; verify formatting on the source"
        fi
        if ((big)) && [[ -n $S_big_decimal_quote ]]; then
            local qq
            qq=$(tdx_sql_str "$S_big_decimal_quote")
            text="$qq || $text || $qq"
            width=$((width + 2))
        fi
        if ((big)); then tdx_rule "$i" decimal_quoted "$rs" "$width" 0 0 "$notes"; else tdx_rule "$i" decimal_text "$rs" "$width" 0 0 "$notes"; fi
        tdx_plain_value "$q" "$text"
        R_expr[i]=$REPLY
    elif [[ $c == F ]]; then
        tdx_rule "$i" float_text FLOAT8 25 0 0 ""
        tdx_plain_value "$q" "TRIM(CAST(CAST($q AS FORMAT '-9.9(16)E-999') AS VARCHAR(30)))"
        R_expr[i]=$REPLY
    elif [[ $c == DA ]]; then
        tdx_rule "$i" iso_date DATE 10 0 0 ""
        tdx_plain_value "$q" "CAST(CAST($q AS FORMAT 'YYYY-MM-DD') AS CHAR(10))"
        R_expr[i]=$REPLY
    elif [[ $c == AT || $c == TZ ]]; then
        local fr=$((sc > 0 ? sc : 0)) src
        if [[ $c == AT ]]; then src=$q; else src="CAST(($q AT TIME ZONE INTERVAL '00:00' HOUR TO MINUTE) AS TIME($fr))"; fi
        tdx_dt_format "$fr" 0
        text="TRIM(CAST(CAST($src AS FORMAT '$REPLY') AS VARCHAR(16)))"
        if [[ $c == TZ ]]; then
            text+=" || 'Z'"
            tdx_rule "$i" utc_iso_time TIMETZ 17 0 0 ""
        else
            tdx_rule "$i" iso_time TIME 17 0 0 ""
        fi
        tdx_plain_value "$q" "$text"
        R_expr[i]=$REPLY
    elif [[ $c == TS || $c == SZ ]]; then
        local fr=$((sc > 0 ? sc : 0)) src
        if [[ $c == TS ]]; then src=$q; else src="CAST(($q AT TIME ZONE INTERVAL '00:00' HOUR TO MINUTE) AS TIMESTAMP($fr))"; fi
        tdx_dt_format "$fr" 1
        text="OREPLACE(TRIM(CAST(CAST($src AS FORMAT '$REPLY') AS VARCHAR(27))), ' ', 'T')"
        if [[ $c == SZ ]]; then
            text+=" || 'Z'"
            tdx_rule "$i" utc_iso_timestamp TIMESTAMPTZ 28 0 0 ""
        else
            tdx_rule "$i" iso_timestamp TIMESTAMP 28 0 0 ""
        fi
        tdx_plain_value "$q" "$text"
        R_expr[i]=$REPLY
    elif tdx_in "$c" "$TDX_INTERVAL_TYPES" || tdx_in "$c" "$TDX_PERIOD_TYPES"; then
        local width=80 enc=period_text
        if tdx_in "$c" "$TDX_INTERVAL_TYPES"; then width=40; enc=interval_text; fi
        tdx_rule "$i" "$enc" "VARCHAR($width)" "$width" 0 0 ""
        tdx_plain_value "$q" "TRIM(CAST($q AS VARCHAR($width)))"
        R_expr[i]=$REPLY
    elif tdx_in "$c" " CF CV CO JN XM "; then
        local unicode=0 chars rs mult n
        if [[ $ct == 2 ]] || { tdx_in "$c" " JN XM " && [[ $S_session_charset == UTF8 ]]; }; then unicode=1; fi
        if ! tdx_in "$ct" " 0 1 2 " && tdx_in "$c" " CF CV CO "; then
            tdx_col_charset "$i"
            tdx_rule "$i" unsupported "" 0 0 0 "character set ${REPLY:-$ct} not supported"
            return
        fi
        if [[ $ct == 2 && $S_session_charset == ASCII ]]; then
            tdx_rule "$i" unsupported "" 0 0 0 "UNICODE column cannot be exported losslessly with session_charset = ASCII; use UTF8"
            return
        fi
        if tdx_in "$c" " CO JN XM "; then
            n=$S_lob_max_length
            if [[ $c == XM ]]; then text="XMLSERIALIZE(CONTENT $q AS VARCHAR($n))"; else text="CAST($q AS VARCHAR($n))"; fi
            tdx_rule "$i" escaped_text "VARCHAR(65535)" $((2 * n)) 1 1 ""
            tdx_text_value "$q" "$text" CHARACTER_LENGTH
            R_expr[i]=$REPLY
            return
        fi
        chars=${C_len[i]}
        [[ $ct == 2 ]] && chars=$((chars / 2))
        mult=1
        ((unicode)) && mult=4
        if [[ $c == CF ]]; then
            case $S_char_trim in
                right) text="TRIM(TRAILING FROM $q)" ;;
                both) text="TRIM(BOTH FROM $q)" ;;
                none) text=$q ;;
            esac
            if [[ $S_char_trim == none ]] && ((chars <= 4096 && !unicode)); then
                rs="CHAR($chars)"
            else
                n=$((chars * mult))
                rs="VARCHAR($((n < 65535 ? n : 65535)))"
            fi
        else
            text=$q
            n=$(((chars > 1 ? chars : 1) * mult))
            rs="VARCHAR($((n < 65535 ? n : 65535)))"
        fi
        tdx_rule "$i" escaped_text "$rs" $((2 * chars)) 0 1 ""
        tdx_text_value "$q" "$text" CHARACTER_LENGTH
        R_expr[i]=$REPLY
        [[ $c == CF && $S_char_trim != none ]] && R_notes[i]="CHAR padding trimmed ($S_char_trim)"
    elif tdx_in "$c" " BF BV BO "; then
        local n src lob=0 vb
        if [[ $c == BO ]]; then n=$S_lob_max_length; src="CAST($q AS VARBYTE($n))"; lob=1; else n=${C_len[i]}; src=$q; fi
        vb=$((n > 1 ? n : 1))
        ((vb > 1024000)) && vb=1024000
        tdx_rule "$i" hex "VARBYTE($vb)" $((2 * n)) "$lob" 1 "hex (base16) encoded bytes"
        local out
        out="CASE WHEN $q IS NULL THEN $(tdx_sql_str "$S_null_sentinel")"
        [[ -n $S_empty_sentinel ]] && out+=" WHEN BYTES($src) = 0 THEN $(tdx_sql_str "$S_empty_sentinel")"
        R_expr[i]="$out ELSE FROM_BYTES($src, 'base16') END"
    else
        tdx_rule "$i" unsupported "" 0 0 0 "Teradata type code $(tdx_repr "$c") is not supported"
    fi
}

# Effective record limit: max_row_length capped so the record cast (+1 headroom) is a valid VARCHAR.
tdx_row_limit() {
    local i unicode=0 cap
    for ((i = 1; i <= NCOLS; i++)); do
        if [[ ${C_ct[i]} == 2 ]] || { tdx_in "${C_tc[i]}" " JN XM " && [[ $S_session_charset == UTF8 ]]; }; then unicode=1; fi
    done
    if ((unicode)); then cap=31999; else cap=63999; fi
    REPLY=$((S_max_row_length < cap ? S_max_row_length : cap))
}

tdx_record_sql() {
    local i joined="" d
    d=$(tdx_sql_str "$S_delimiter")
    for ((i = 1; i <= NCOLS; i++)); do
        ((i > 1)) && joined+=" || $d || "
        joined+="(${R_expr[i]})"
    done
    tdx_row_limit
    REPLY="CAST($joined AS VARCHAR($((REPLY + 1))))"
}
