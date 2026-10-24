# Test environment helpers (bash port of the former tests/helpers.py): isolated utility roots,
# config/source-table/credential writers, CLI runner, fixture editing, on-disk output readers.
# Requires TDX_TEST_TMP (fresh per test, set by tests/run_tests.sh).

TDX_TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TDX_REPO_ROOT=$(cd "$TDX_TESTS_DIR/.." && pwd)
TDX_FAKES_DIR=$TDX_TESTS_DIR/fakes
TDX_FIXTURES_DIR=$TDX_TESTS_DIR/fixtures
TDX_ENTRYPOINT=$TDX_REPO_ROOT/teradata_extract.sh
TDX_FAKE_AWK=$TDX_FAKES_DIR/_tdxfake.awk
TD_USER_TEST=tdx_test_user
TD_PASS_TEST='Zq9-Secr3t-Pw!x'

tt_awk() { LC_ALL=C "${TDX_AWK:-awk}" "$@"; }

# Percent-encoding used by fixtures, record lists and request lists: % TAB LF CR -> %25 %09 %0A %0D
tt_enc() {
    local v=$1
    v=${v//%/%25}; v=${v//$'\t'/%09}; v=${v//$'\n'/%0A}; v=${v//$'\r'/%0D}
    printf '%s' "$v"
}
tt_dec() {   # tt_dec VALUE -> decoded bytes on stdout
    local v=${1//\\/\\\\}
    printf "${v//%/\\x}"
}

TDX_DEFAULT_CONFIG='teradata	host	tdfake.example.com
teradata	port	1025
teradata	logmech	
teradata	credentials_file	
teradata	fexp_path	fexp
teradata	bteq_path	bteq
teradata	session_charset	ASCII
teradata	logtable_database	
teradata	connect_check	false
paths	base_dir	
paths	output_dir	data
paths	metadata_dir	metadata
paths	log_dir	logs
paths	work_dir	work
paths	source_tables_file	config/source_tables.ini
paths	process_state_file	config/process_state.ini
extract	file_format	pipe-delimited
extract	parallel	1
extract	max_sessions	4
extract	min_sessions	1
extract	chunk_threshold_rows	10
extract	chunk_rows	7
extract	max_chunks	64
extract	small_table_rows	5
extract	row_estimate	stats
extract	char_trim	right
extract	lob_max_length	1000
extract	max_row_length	64000
extract	zip_on_complete	true
extract	keep_raw_after_zip	false
extract	retry_attempts	2
extract	retry_delay_seconds	0
extract	session_limit_errors	2633,3130
extract	session_limit_patterns	Too many load/unload tasks,session limit,No more sessions
extract	bteq_fallback	true
extract	job_timeout_seconds	0
extract	log_tool_output	masked
format	delimiter	|
format	null_sentinel	\N
format	empty_sentinel	\E
format	escape_char	\
format	big_decimal_quote	"
format	big_decimal_threshold	18'

# tt_env_new [FIXTURE_NAME]   (default basic.fixture). Sets TDX_TMP TDX_ROOT TDX_FAKE TDX_FIXTURE
# TDX_FAKE_LOG_FILE TDX_CONFIG TDX_TABLES TDX_STATE; writes the default config and tables.
tt_env_new() {
    TDX_TMP=$(mktemp -d "${TDX_TEST_TMP:-${TMPDIR:-/tmp}}/tdx_test_XXXXXXXX")
    TDX_ROOT=$TDX_TMP/root
    TDX_FAKE=$TDX_TMP/fake
    mkdir -p "$TDX_ROOT/config" "$TDX_FAKE"
    TDX_CONFIG=$TDX_ROOT/config/main_config.ini
    TDX_TABLES=$TDX_ROOT/config/source_tables.ini
    TDX_STATE=$TDX_ROOT/config/process_state.ini
    TDX_FIXTURE=$TDX_FAKE/fixture.txt
    TDX_FAKE_LOG_FILE=$TDX_FAKE/calls.log
    TDX_CRED_MODE=env
    cp "$TDX_FIXTURES_DIR/${1:-basic.fixture}" "$TDX_FIXTURE"
    printf '%s\n' "$TDX_DEFAULT_CONFIG" >"$TDX_FAKE/config.tsv"
    tt_write_config
    tt_set_tables "mixed TDX_DB MIXED" "big TDX_DB BIG" "cdc TDX_DB CDC cdc_column=UPDATED_TS"
}

# INI writer in Python configparser layout ("key = value", blank line after each section).
tt_write_config() {
    tt_awk -F '\t' '
        $1 != sec { if (NR > 1) print ""; sec = $1; print "[" sec "]" }
        { v = $0; sub(/^[^\t]*\t[^\t]*\t/, "", v); print $2 " = " v }
        END { if (NR) print "" }' "$TDX_FAKE/config.tsv" >"$TDX_CONFIG"
}
# tt_config_set SECTION KEY VALUE  (adds the section/key if needed, rewrites main_config.ini)
tt_config_set() {
    TDXS=$1 TDXK=$2 TDXV=$3 tt_awk -F '\t' '
        BEGIN { s = ENVIRON["TDXS"]; k = ENVIRON["TDXK"]; v = ENVIRON["TDXV"] }
        $1 == s && $2 == k { print s "\t" k "\t" v; done = 1; next }
        $1 != s && last == s && !done { print s "\t" k "\t" v; done = 1 }
        { last = $1; print }
        END { if (!done) print s "\t" k "\t" v }' "$TDX_FAKE/config.tsv" >"$TDX_FAKE/config.tsv.new" \
        && mv -f "$TDX_FAKE/config.tsv.new" "$TDX_FAKE/config.tsv"
    tt_write_config
}
# tt_set_tables "label DB TABLE [key=value ...]" ...   (replaces source_tables.ini)
tt_set_tables() {
    local spec kv
    : >"$TDX_TABLES"
    for spec in "$@"; do
        set -- $spec
        printf '[%s]\ndatabase = %s\ntable = %s\n' "$1" "$2" "$3" >>"$TDX_TABLES"
        shift 3
        for kv in "$@"; do printf '%s = %s\n' "${kv%%=*}" "${kv#*=}" >>"$TDX_TABLES"; done
        printf '\n' >>"$TDX_TABLES"
    done
}
# tt_write_credentials_file [MODE] [USER] [PASSWORD] -> path; points credentials_file at it
tt_write_credentials_file() {
    local path=$TDX_FAKE/td_credentials.ini
    printf '[credentials]\nuser = %s\npassword = %s\n\n' "${2:-$TD_USER_TEST}" "${3:-$TD_PASS_TEST}" >"$path"
    chmod "${1:-600}" "$path"
    tt_config_set teradata credentials_file "$path"
    TDX_CRED_FILE=$path
}

# tt_run [--cred env|none] [--env NAME=VALUE]... [--] ARGS...
# Runs the CLI from $TDX_TMP; sets TDX_RC, TDX_OUT, TDX_ERR (also in $TDX_TMP/run.out|run.err).
tt_run() {
    local cred=$TDX_CRED_MODE extra=()
    while [ $# -gt 0 ]; do
        case $1 in
        --cred) cred=$2; shift 2 ;;
        --env) extra+=("$2"); shift 2 ;;
        --) shift; break ;;
        *) break ;;
        esac
    done
    local envs=(TDX_FEXP="$TDX_FAKES_DIR/fexp" TDX_BTEQ="$TDX_FAKES_DIR/bteq"
        TDX_FAKE_FIXTURE="$TDX_FIXTURE" TDX_FAKE_LOG="$TDX_FAKE_LOG_FILE")
    [ "$cred" = env ] && envs+=(TD_USER="$TD_USER_TEST" TD_PASS="$TD_PASS_TEST")
    (cd "$TDX_TMP" && env -u TD_USER -u TD_PASS "${envs[@]}" "${extra[@]}" \
        "$TDX_ENTRYPOINT" --config "$TDX_CONFIG" "$@" >"$TDX_TMP/run.out" 2>"$TDX_TMP/run.err" </dev/null)
    TDX_RC=$?
    TDX_OUT=$(cat "$TDX_TMP/run.out"; printf x); TDX_OUT=${TDX_OUT%x}
    TDX_ERR=$(cat "$TDX_TMP/run.err")
    return 0
}
tt_run_ok() {   # like tt_run, asserts exit code 0
    tt_run "$@"
    [ "$TDX_RC" = 0 ] || { printf 'stdout:\n%s\nstderr:\n%s\n' "$TDX_OUT" "$TDX_ERR" >&2; tt_fail "CLI exit code $TDX_RC (expected 0)"; }
}

# ----- INI readers -----------------------------------------------------------------------------
tt_ini_get() {   # tt_ini_get FILE SECTION KEY -> value (rc 1 when absent)
    [ -f "$1" ] || return 1
    TDXS=$2 TDXK=$3 tt_awk '
        BEGIN { s = ENVIRON["TDXS"]; k = ENVIRON["TDXK"] }
        /^[ \t]*[#;]/ { next }
        /^\[/ { line = $0; sub(/^\[/, "", line); sub(/\][ \t\r]*$/, "", line); in_s = (line == s); next }
        in_s { p = index($0, "="); if (!p) next
               key = substr($0, 1, p - 1); gsub(/^[ \t]+|[ \t]+$/, "", key)
               if (key == k) { v = substr($0, p + 1); gsub(/^[ \t]+|[ \t\r]+$/, "", v); print v; found = 1; exit } }
        END { exit found ? 0 : 1 }' "$1"
}
tt_ini_sections() { tt_awk '/^\[/ { s = $0; sub(/^\[/, "", s); sub(/\][ \t\r]*$/, "", s); print s }' "$1"; }
tt_state() { tt_ini_get "$TDX_STATE" "$1" "$2"; }
tt_meta_file() { printf '%s/metadata/%s_%s.meta.ini' "$TDX_ROOT" "$(tt_lower "$1")" "$(tt_lower "$2")"; }
tt_meta() { tt_ini_get "$(tt_meta_file "$1" "$2")" "$3" "$4"; }
tt_lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
tt_upper() { printf '%s' "$1" | tr 'a-z' 'A-Z'; }
tt_audit_lines() { [ -f "$TDX_ROOT/metadata/audit.log" ] && grep -v '^[[:space:]]*$' "$TDX_ROOT/metadata/audit.log"; return 0; }

# ----- .dat records ------------------------------------------------------------------------------
# tt_split_records FILE: one record per output line, %-encoded (see tt_enc). LF ends a record
# unless escaped by a preceding backslash (a backslash always escapes the next byte).
tt_split_records() {
    tt_awk '
        function enc(s) { gsub(/%/, "%25", s); gsub(/\t/, "%09", s); gsub(/\r/, "%0D", s); return s }
        function odd(s,   n) { n = 0; while (n < length(s) && substr(s, length(s) - n, 1) == "\\") n++; return n % 2 }
        { cur = pend ? cur "%0A" enc($0) : enc($0); pend = 0 }
        odd($0) { pend = 1; next }
        { print cur; cur = "" }
        END { if (pend) print cur "%0A" }' "$1"
}
# tt_fixture_lines KEY: the fixture rows of table KEY, %-encoded like tt_split_records
tt_fixture_lines() {
    TDXK=$(tt_upper "$1") tt_awk -F '\t' '
        BEGIN { k = ENVIRON["TDXK"] }
        function dec(v,   o, i, h, x) { o = ""
            while ((i = index(v, "%")) > 0) { h = toupper(substr(v, i + 1, 2)); x = index("0123456789ABCDEF", substr(h, 1, 1)) * 16 + index("0123456789ABCDEF", substr(h, 2, 1)) - 17
                if (h == "25") { o = o substr(v, 1, i - 1) "%25"; v = substr(v, i + 3) }
                else if (h == "09" || h == "0A" || h == "0D") { o = o substr(v, 1, i - 1) "%" h; v = substr(v, i + 3) }
                else if (x > 0 && length(h) == 2) { o = o substr(v, 1, i - 1) sprintf("%c", x); v = substr(v, i + 3) }
                else { o = o substr(v, 1, i) "25"; v = substr(v, i + 1) } }
            return o v }
        toupper($1) == k && $2 == "row" { print dec($3) }' "$TDX_FIXTURE"
}

# ----- fixture editing (format: tests/fakes/README.md) --------------------------------------------
# tt_fixture_set KEY FIELD VALUE...   replace all "KEY FIELD ..." lines by one line ("\N" = NULL)
tt_fixture_set() {
    local key=$1 field=$2 line v
    shift 2
    line="$key"$'\t'"$field"
    for v in "$@"; do [ "$v" = '\N' ] && line+=$'\t\\N' || line+=$'\t'"$(tt_enc "$v")"; done
    TDXK=$(tt_upper "$key") TDXF=$field TDXL=$line tt_awk -F '\t' '
        BEGIN { k = ENVIRON["TDXK"]; f = ENVIRON["TDXF"]; l = ENVIRON["TDXL"] }
        { buf[NR] = $0; if (toupper($1) == k) { last = NR; if ($2 == f) { hit[NR] = 1; if (!first) first = NR } } }
        END { at = first ? first : last
              for (i = 1; i <= NR; i++) { if (!(i in hit)) print buf[i]; if (i == at) print l }
              if (!at) print l }' "$TDX_FIXTURE" >"$TDX_FIXTURE.new" && mv -f "$TDX_FIXTURE.new" "$TDX_FIXTURE"
}
# tt_fixture_add_failure key=value...   (keys: table tool query chunk times code message)
tt_fixture_add_failure() {
    local line=failure kv
    for kv in "$@"; do line+=$'\t'"${kv%%=*}=$(tt_enc "${kv#*=}")"; done
    printf '%s\n' "$line" >>"$TDX_FIXTURE"
}
tt_fixture_clear_failures() {
    grep -v '^failure	' "$TDX_FIXTURE" >"$TDX_FIXTURE.new"; mv -f "$TDX_FIXTURE.new" "$TDX_FIXTURE"
}

# ----- fake call log ----------------------------------------------------------------------------
tt_fake_calls() { [ -f "$TDX_FAKE_LOG_FILE" ] && grep -c '^@call ' "$TDX_FAKE_LOG_FILE" || echo 0; }
tt_reset_fake_log() { rm -f "$TDX_FAKE_LOG_FILE"; }
# tt_fake_scripts DIR: write each logged script to DIR/<nnn>.<tool> (exact bytes); prints count
tt_fake_scripts() {
    mkdir -p "$1"
    [ -f "$TDX_FAKE_LOG_FILE" ] || { echo 0; return 0; }
    tt_awk -v d="$1" '
        /^@call / { n++; f = sprintf("%s/%03d.%s", d, n, substr($2, 6)); nl = ($0 ~ /final_newline=yes/); printf "" > f; first = 1; next }
        /^@end$/ { close(f); next }
        /^>/ { if (!first) printf "\n" > f; printf "%s", substr($0, 2) > f; first = 0; if (nl) last[f] = 1; next }
        { }
        END { for (f in last) printf "\n" >> f; print n + 0 }' "$TDX_FAKE_LOG_FILE"
}
# tt_requests [QUERY] [DB.TABLE]: marked requests received by the fakes, one per line:
# "<tool> TAB path=<p> TAB key=value ..." (values %-encoded)
tt_requests() {
    local d=$TDX_TMP/.calls.$$ f tool
    rm -rf "$d"; tt_fake_scripts "$d" >/dev/null
    for f in "$d"/*; do
        [ -f "$f" ] || continue
        tool=${f##*.}
        tt_awk -v mode=events -v script="$f" -f "$TDX_FAKE_AWK" | while IFS= read -r line; do
            printf '%s\t%s\n' "$tool" "$line"
        done
    done | TDXQ=${1:-} TDXT=$(tt_upper "${2:-}") tt_awk -F '\t' '
        BEGIN { q = ENVIRON["TDXQ"]; t = ENVIRON["TDXT"] }
        { split("", m); for (i = 3; i <= NF; i++) { p = index($i, "="); m[substr($i, 1, p - 1)] = substr($i, p + 1) } }
        q != "" && m["query"] != q { next }
        t != "" && toupper(m["db"] "." m["table"]) != t { next }
        { print }'
    rm -rf "$d"
}
tt_req_get() {   # tt_req_get REQUEST_LINE KEY -> decoded value (rc 1 when absent)
    printf '%s\n' "$1" | TDXK=$2 tt_awk -F '\t' '
        BEGIN { k = ENVIRON["TDXK"] }
        { for (i = 2; i <= NF; i++) { p = index($i, "="); if (substr($i, 1, p - 1) == k) { print substr($i, p + 1); f = 1 } } }
        END { exit f ? 0 : 1 }'
}

# ----- archives ---------------------------------------------------------------------------------
tt_archive_path() {   # tt_archive_path KEY -> data/<zip_file> from the state (rc 1 when unset)
    local z
    z=$(tt_state "$1" zip_file) && [ -n "$z" ] || return 1
    printf '%s/data/%s' "$TDX_ROOT" "$z"
}
tt_archive_members() { gzip -dc "$1" | tar tf - | sort; }
tt_archive_extract() {   # tt_archive_extract ARCHIVE DIR
    mkdir -p "$2" && gzip -dc "$1" | (cd "$2" && tar xf -)
}
# tt_archive_records KEY: "<member> TAB <record>" for every record of every .dat member
tt_archive_records() {
    local a d m
    a=$(tt_archive_path "$1") || return 1
    d=$TDX_TMP/.x.$$; rm -rf "$d"; tt_archive_extract "$a" "$d" || return 1
    for m in $(tt_archive_members "$a"); do
        case $m in *.dat) tt_split_records "$d/$m" | while IFS= read -r r; do printf '%s\t%s\n' "$m" "$r"; done ;; esac
    done
    rm -rf "$d"
}
# tt_files_containing NEEDLE [DIR]: files under DIR (default the utility root) containing NEEDLE,
# also looking inside .tar.gz archives (and .zip when unzip exists)
tt_files_containing() {
    local dir=${2:-$TDX_ROOT} f x=$TDX_TMP/.fc.$$
    find "$dir" -type f | sort | while IFS= read -r f; do
        if grep -qF -- "$1" "$f" 2>/dev/null; then printf '%s\n' "$f"; continue; fi
        case $f in
        *.tar.gz)
            rm -rf "$x"; tt_archive_extract "$f" "$x" 2>/dev/null
            grep -rqF -- "$1" "$x" 2>/dev/null && printf '%s\n' "$f"; rm -rf "$x" ;;
        *.zip)
            command -v unzip >/dev/null 2>&1 && unzip -p "$f" 2>/dev/null | grep -qF -- "$1" && printf '%s\n' "$f" ;;
        esac
    done
}
