# Black-box integration tests of teradata_extract.sh driven by the fake fexp/bteq.
# Only the CLI and the on-disk outputs defined in docs/DESIGN.md are used. Port of test_integration.py.

MIXED=TDX_DB.MIXED BIG=TDX_DB.BIG CDC=TDX_DB.CDC LOB=TDX_DB.LOB_BIG
WM1="2024-03-01 00:00:00.000000"
WM2="2024-04-15 00:00:00.000000"

it_chunk_list() { printf '%s' "$1" | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort -n | tr '\n' ' ' | sed 's/ $//'; }
it_records() { tt_archive_records "$1" | cut -f2-; }   # all records of all .dat members
it_export_reqs() { tt_requests export "$1"; }
it_chunk_of() { tt_req_get "$1" chunk | cut -d/ -f1; }

test_full_run_success() {
    tt_env_new
    tt_run_ok
    assert_contains "$TDX_OUT" "TERADATA EXTRACT SUMMARY"
    assert_match "$TDX_OUT" 'Tables[[:space:]]*:[[:space:]]*done=3 failed=0 pending=0'
    local cycle key rows sec stem a names f
    cycle=$(tt_state _run cycle_id)
    assert_not_empty "$cycle" "cycle_id"
    for key in "$MIXED:4" "$BIG:25" "$CDC:3"; do
        rows=${key#*:}; key=${key%:*}
        assert_eq done "$(tt_state "$key" status)" "$key status"
        assert_eq "$rows" "$(tt_state "$key" rows_exported)" "$key rows_exported"
        assert_match "$(tt_state "$key" checksum_sha256)" '^[0-9a-f]{64}$' "$key checksum"
        stem=$(tt_lower "${key/./_}")
        assert_eq "${stem}_$cycle.tar.gz" "$(tt_state "$key" zip_file)" "$key archive name"
        a=$(tt_archive_path "$key")
        assert_file "$a"
        assert_eq "$(tt_state "$key" zip_sha256)" "$(sha256sum "$a" | cut -d' ' -f1)" "$key archive sha"
        gzip -t "$a" || tt_fail "gzip -t $a"
        names=$(tt_archive_members "$a") || tt_fail "tar tf $a"
        for f in $(tt_state "$key" files | tr ',' ' '); do
            printf '%s\n' "$names" | grep -qxF -- "$f" || tt_fail "$f not in $a"
        done
        assert_count "$rows" "$(it_records "$key")" "$key archived records"
    done
    assert_empty "$(cd "$TDX_ROOT/data" && ls | grep '\.dat$')" "no .dat left"
    assert_empty "$(cd "$TDX_ROOT/data" && ls | grep '\.raw$')" "no .raw left"
    # MIXED is unchunked: one member with exactly the fixture lines
    a=$(tt_archive_path "$MIXED")
    assert_eq tdx_db_mixed.dat "$(tt_archive_members "$a")"
    assert_eq "$(tt_fixture_lines "$MIXED")" "$(it_records "$MIXED")"
    tt_archive_extract "$a" "$TDX_TMP/x"
    (tt_fixture_lines "$MIXED" | while IFS= read -r l; do tt_dec "$l"; printf '\n'; done) >"$TDX_TMP/expected.dat"
    assert_files_equal "$TDX_TMP/expected.dat" "$TDX_TMP/x/tdx_db_mixed.dat" "raw member bytes"
    assert_eq none "$(tt_state "$MIXED" chunk_strategy)"
    assert_eq bteq "$(tt_state "$MIXED" method)"
}

test_meta_files() {
    tt_env_new
    tt_run_ok
    local key m cols s name exp enc rs
    for key in "$MIXED" "$BIG" "$CDC"; do
        tt_ini_sections "$(tt_meta_file "${key%.*}" "${key#*.}")" | grep -qx table || tt_fail "$key meta has no [table]"
    done
    m=$(tt_meta_file TDX_DB MIXED)
    assert_eq 8 "$(tt_ini_get "$m" table column_count)"
    assert_eq UTC "$(tt_ini_get "$m" table timezone_policy)"
    cols=$(tt_ini_sections "$m" | grep '^column\.')
    assert_eq "$(for i in 1 2 3 4 5 6 7 8; do printf 'column.%03d\n' "$i"; done)" "$cols"
    for exp in "ID int_text INTEGER" "AMT decimal_text DECIMAL(10,2)" "BIG_AMT decimal_quoted DECIMAL(38,4)" \
        "NAME escaped_text VARCHAR(50)" "BIZ_DATE iso_date DATE" "CREATED_TS iso_timestamp TIMESTAMP" \
        "EVENT_TSZ utc_iso_timestamp TIMESTAMPTZ" "PAYLOAD hex_dash VARCHAR(200)"; do
        set -- $exp
        s=""
        for c in $cols; do [ "$(tt_ini_get "$m" "$c" name)" = "$1" ] && s=$c; done
        assert_not_empty "$s" "column $1"
        assert_eq "$2" "$(tt_ini_get "$m" "$s" output_encoding)" "$1 output_encoding"
        assert_eq "$3" "$(tt_ini_get "$m" "$s" redshift_type)" "$1 redshift_type"
        [ "$1" = ID ] && assert_eq 1 "$(tt_ini_get "$m" "$s" position)" "ID position"
        [ "$1" = EVENT_TSZ ] && { tt_ini_get "$m" "$s" source_timezone >/dev/null || tt_fail "EVENT_TSZ source_timezone"; }
    done
    return 0
}

test_audit_and_state_header() {
    tt_env_new
    tt_run_ok
    assert_eq "# THIS FILE IS MANAGED BY teradata_extract - DO NOT EDIT." "$(head -1 "$TDX_STATE" | cut -c1-58)"
    local lines run_id key rows line
    lines=$(tt_audit_lines)
    assert_count 3 "$lines" "audit lines"
    run_id=$(tt_state _run last_run_id)
    for key in "$MIXED:4" "$BIG:25" "$CDC:3"; do
        rows=${key#*:}; key=${key%:*}
        line=$(printf '%s\n' "$lines" | grep -F " | $key | " | head -1)
        assert_not_empty "$line" "audit line for $key"
        assert_eq "$run_id" "$(printf '%s' "$line" | tt_awk -F ' [|] ' '{ v = $2; gsub(/^[ \t]+|[ \t]+$/, "", v); print v }')"
        assert_eq done "$(printf '%s' "$line" | tt_awk -F ' [|] ' '{ v = $4; gsub(/^[ \t]+|[ \t]+$/, "", v); print v }')"
        assert_eq "rows=$rows" "$(printf '%s' "$line" | tt_awk -F ' [|] ' '{ v = $5; gsub(/^[ \t]+|[ \t]+$/, "", v); print v }')"
    done
}

test_done_tables_skipped_on_rerun() {
    tt_env_new
    tt_run_ok
    tt_reset_fake_log
    tt_run_ok
    assert_empty "$(tt_requests export)" "no export requests on rerun"
    assert_match "$TDX_OUT" 'skipped already done=3'
}

test_password_never_written() {
    tt_env_new
    tt_run_ok
    assert_empty "$(tt_files_containing "$TD_PASS_TEST")" "files containing the password"
    local n
    n=$(find "$TDX_ROOT/work" -type f -name '*.*' | wc -l)
    [ "$n" -gt 0 ] || tt_fail "no saved scripts in work/"
    grep -rqF '********' "$TDX_ROOT/work" || tt_fail "saved scripts must contain the masked logon"
    n=$(tt_fake_scripts "$TDX_TMP/scripts")
    grep -lF -- "$TD_PASS_TEST" "$TDX_TMP/scripts"/* >/dev/null 2>&1 || tt_fail "password must reach the tools via stdin"
}

test_dry_run_and_status_make_no_calls() {
    tt_env_new
    tt_run --dry-run
    assert_rc 0 "$TDX_RC" "--dry-run: $TDX_OUT$TDX_ERR"
    tt_run --status
    assert_rc 0 "$TDX_RC" "--status: $TDX_OUT$TDX_ERR"
    assert_eq 0 "$(tt_fake_calls)" "fake calls"
}

test_tables_filter() {
    tt_env_new
    tt_run_ok --tables tdx_db.mixed
    assert_eq done "$(tt_state "$MIXED" status)"
    assert_empty "$(it_export_reqs "$BIG")"
}

test_keep_raw_after_zip() {
    tt_env_new
    tt_config_set extract keep_raw_after_zip true
    tt_run_ok
    local dats
    dats=$(cd "$TDX_ROOT/data" && ls | grep '\.dat$' | sort)
    printf '%s\n' "$dats" | grep -qx tdx_db_mixed.dat || tt_fail "tdx_db_mixed.dat kept"
    printf '%s\n' "$dats" | grep -q '^tdx_db_big\.part' || tt_fail "tdx_db_big.part*.dat kept"
    assert_not_empty "$(cd "$TDX_ROOT/data" && ls | grep '\.tar\.gz$')" "archives exist"
}

it_chunk_env() { tt_env_new; tt_set_tables "big TDX_DB BIG"; }

test_chunked_union_equals_fixture() {
    it_chunk_env
    tt_run_ok
    local n i members sum=0 r
    n=$(tt_state "$BIG" chunk_count)
    [ "$n" -gt 1 ] || tt_fail "chunk_count $n"
    assert_ne none "$(tt_state "$BIG" chunk_strategy)"
    assert_eq "$(seq 1 "$n" | tr '\n' ' ' | sed 's/ $//')" "$(it_chunk_list "$(tt_state "$BIG" chunks_done)")"
    members=$(tt_archive_members "$(tt_archive_path "$BIG")")
    assert_eq "$(for i in $(seq 1 "$n"); do printf 'tdx_db_big.part%03d.dat\n' "$i"; done)" "$members"
    assert_eq "$(tt_fixture_lines "$BIG" | sort)" "$(it_records "$BIG" | sort)"
    for i in $(seq 1 "$n"); do
        assert_eq done "$(tt_state "$(printf '%s/part%03d' "$BIG" "$i")" status)"
        assert_match "$(tt_state "$(printf '%s/part%03d' "$BIG" "$i")" sha256)" '^[0-9a-f]{64}$'
        r=$(tt_state "$(printf '%s/part%03d' "$BIG" "$i")" rows); sum=$((sum + r))
    done
    assert_eq 25 "$sum"
}

test_resume_reruns_only_failed_chunk() {
    it_chunk_env
    tt_fixture_add_failure "table=$BIG" query=export chunk=2 times=1 code=3707 "message=Syntax error, expected something"
    tt_run
    assert_rc 1 "$TDX_RC" "first run: $TDX_OUT$TDX_ERR"
    local n reqs
    n=$(tt_state "$BIG" chunk_count)
    assert_eq failed "$(tt_state "$BIG" status)"
    assert_not_empty "$(tt_state "$BIG" last_error)"
    assert_eq "$(seq 1 "$n" | grep -vx 2 | tr '\n' ' ' | sed 's/ $//')" "$(it_chunk_list "$(tt_state "$BIG" chunks_done)")"
    assert_contains "$TDX_OUT" FAILED
    tt_reset_fake_log
    tt_run_ok
    reqs=$(it_export_reqs "$BIG")
    assert_count 1 "$reqs" "export requests on resume"
    assert_eq 2 "$(it_chunk_of "$reqs")"
    assert_eq done "$(tt_state "$BIG" status)"
    assert_eq "$(seq 1 "$n" | tr '\n' ' ' | sed 's/ $//')" "$(it_chunk_list "$(tt_state "$BIG" chunks_done)")"
    assert_eq 25 "$(tt_state "$BIG" rows_exported)"
    assert_eq "$(tt_fixture_lines "$BIG" | sort)" "$(it_records "$BIG" | sort)"
}

test_session_limit_retry() {
    it_chunk_env
    tt_fixture_add_failure "table=$BIG" query=export chunk=1 times=1 code=2633 "message=Too many load/unload tasks running now"
    tt_run_ok
    local n=0 r
    while IFS= read -r r; do [ "$(it_chunk_of "$r")" = 1 ] && n=$((n + 1)); done <<<"$(it_export_reqs "$BIG")"
    assert_eq 2 "$n" "chunk 1 export requests"
    assert_eq done "$(tt_state "$BIG" status)"
}

test_bteq_fallback_after_retries() {
    it_chunk_env
    tt_fixture_add_failure "table=$BIG" tool=fexp query=export chunk=1 times=-1 code=2633 "message=Too many load/unload tasks running now"
    tt_run_ok
    assert_eq done "$(tt_state "$BIG" status)"
    assert_eq bteq "$(tt_state "$BIG/part001" method)"
    local tools="" r
    while IFS= read -r r; do [ "$(it_chunk_of "$r")" = 1 ] && tools+="${r%%$'\t'*} "; done <<<"$(it_export_reqs "$BIG")"
    assert_eq "fexp fexp fexp bteq " "$tools" "1 + retry_attempts(2), then fallback"
    assert_eq 25 "$(tt_state "$BIG" rows_exported)"
}

it_cdc_env() { tt_env_new; tt_set_tables "cdc TDX_DB CDC cdc_column=UPDATED_TS"; }

test_incremental_cycles() {
    it_cdc_env
    local lines reqs r
    lines=$(tt_fixture_lines "$CDC")
    tt_run_ok
    assert_eq "$WM1" "$(tt_state "$CDC" watermark)"
    assert_eq 3 "$(tt_state "$CDC" rows_exported)"
    assert_eq "$(printf '%s\n' "$lines" | sed -n 1,3p | sort)" "$(it_records "$CDC" | sort)"
    tt_fixture_set "$CDC" cdc_max "$WM2"
    tt_reset_fake_log
    tt_run_ok --new-cycle
    assert_eq done "$(tt_state "$CDC" status)"
    assert_eq "$WM2" "$(tt_state "$CDC" watermark)"
    assert_eq 2 "$(tt_state "$CDC" rows_exported)"
    assert_eq "$(printf '%s\n' "$lines" | sed -n '4,$p' | sort)" "$(it_records "$CDC" | sort)"
    reqs=$(it_export_reqs "$CDC")
    assert_not_empty "$reqs" "cycle 2 export requests"
    while IFS= read -r r; do
        assert_eq "$WM1" "$(tt_req_get "$r" cdc_gt)" "cdc_gt"
        assert_eq "$WM2" "$(tt_req_get "$r" cdc_le)" "cdc_le"
    done <<<"$reqs"
}

test_no_new_rows_keeps_watermark() {
    it_cdc_env
    tt_run_ok
    assert_eq "$WM1" "$(tt_state "$CDC" watermark)"
    tt_fixture_set "$CDC" cdc_max '\N'
    tt_run_ok --new-cycle
    assert_eq done "$(tt_state "$CDC" status)"
    assert_eq 0 "$(tt_state "$CDC" rows_exported)"
    assert_eq "$WM1" "$(tt_state "$CDC" watermark)"
}

test_failed_fexp_drops_its_logtable() {
    tt_env_new
    tt_set_tables "big TDX_DB BIG"
    tt_config_set teradata logtable_database WORKDB
    tt_fixture_add_failure table=TDX_DB.BIG tool=fexp query=export chunk=2 times=1 code=3798 "message=A column or character expression is larger than the max size"
    tt_run
    assert_rc 1 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    local d=$TDX_TMP/scripts lt drop
    tt_fake_scripts "$d" >/dev/null
    lt=$(grep -h '^.LOGTABLE' "$d"/*.fexp | sed -n 's/^.LOGTABLE \(.*\);$/\1/p' | sort -u)
    drop=$(grep -h "^DROP TABLE" "$d"/*.bteq | sed "s/;$//")
    assert_count 1 "$drop" "one failed FastExport -> one DROP TABLE"
    case $lt in *"${drop#DROP TABLE }"*) ;; *) tt_fail "DROP TABLE does not name a FastExport log table: $drop / $lt" ;; esac
    assert_contains "$drop" '"WORKDB".tdx_lt_'
    assert_not_contains "$(cat "$TDX_ROOT"/work/*droplt*)" "$TD_PASS_TEST"
}

test_big_endian_tool_output() {
    tt_env_new
    tt_set_tables "mixed TDX_DB MIXED" "big TDX_DB BIG"
    tt_run --env TDX_FAKE_ENDIAN=big
    assert_rc 0 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    assert_eq 4 "$(tt_state "$MIXED" rows_exported)"
    assert_eq 25 "$(tt_state "$BIG" rows_exported)"
    tt_env_new
    tt_set_tables "mixed TDX_DB MIXED"
    tt_run --env TDX_FAKE_ENDIAN=big --env TDX_HOST_BE=1
    assert_rc 0 "$TDX_RC" "big-endian host: $TDX_OUT$TDX_ERR"
    tt_env_new
    tt_set_tables "mixed TDX_DB MIXED"
    tt_run --env TDX_HOST_BE=1
    assert_rc 0 "$TDX_RC" "big-endian host, little-endian files: $TDX_OUT$TDX_ERR"
    assert_eq 4 "$(tt_state "$MIXED" rows_exported)"
}

test_lob_over_limit_fails_table() {
    tt_env_new
    tt_set_tables "mixed TDX_DB MIXED" "lob TDX_DB LOB_BIG" "big TDX_DB BIG"
    tt_run
    assert_rc 1 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    assert_eq failed "$(tt_state "$LOB" status)"
    assert_contains "$(tt_state "$LOB" last_error)" lob_max_length
    assert_eq done "$(tt_state "$MIXED" status)"
    assert_eq done "$(tt_state "$BIG" status)"
    assert_match "$TDX_OUT" 'done=2 failed=1'
    assert_contains "$TDX_OUT" FAILED
    assert_contains "$TDX_OUT" "$LOB"
    assert_empty "$(it_export_reqs "$LOB")"
    tt_audit_lines | grep -qF " | $LOB | failed | " || tt_fail "audit line for failed $LOB"
}

it_cred_env() { tt_env_new; tt_set_tables "mixed TDX_DB MIXED"; }

test_no_credentials() {
    it_cred_env
    tt_run --cred none
    assert_rc 2 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    assert_eq 0 "$(tt_fake_calls)"
}

test_only_user_set() {
    it_cred_env
    tt_run --cred none --env TD_USER=someone
    assert_rc 2 "$TDX_RC" "$TDX_OUT$TDX_ERR"
}

test_credentials_file_too_open() {
    it_cred_env
    tt_write_credentials_file 644
    tt_run --cred none
    assert_rc 2 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    assert_eq 0 "$(tt_fake_calls)"
}

test_credentials_file_0600() {
    it_cred_env
    tt_write_credentials_file 600
    tt_run --cred none
    assert_rc 0 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    assert_eq done "$(tt_state "$MIXED" status)"
    assert_empty "$(tt_files_containing "$TD_PASS_TEST")"
    local n f
    n=$(tt_fake_scripts "$TDX_TMP/scripts")
    [ "$n" -gt 0 ] || tt_fail "no fake calls"
    for f in "$TDX_TMP/scripts"/*; do grep -qF -- "$TD_PASS_TEST" "$f" || tt_fail "password missing from $f"; done
}

# ----- source_tables.ini table-list sections -----------------------------------------------------
it_tables_raw() { printf '%s\n' "$@" >"$TDX_TABLES"; }

test_table_list_section() {
    tt_env_new
    it_tables_raw '[tdx]' 'database = TDX_DB' 'table = {MIXED,' '    BIG , CDC}'
    tt_run_ok
    assert_match "$TDX_OUT" 'Tables[[:space:]]*:[[:space:]]*done=3 failed=0 pending=0'
    assert_eq 4 "$(tt_state "$MIXED" rows_exported)"
    assert_eq 25 "$(tt_state "$BIG" rows_exported)"
    assert_eq 5 "$(tt_state "$CDC" rows_exported)" "full extract: all fixture rows"
    assert_empty "$(tt_state "$CDC" watermark)" "listed table without a one-table section: no CDC"
}

test_table_list_without_braces() {
    tt_env_new
    it_tables_raw '[tdx]' 'database = TDX_DB' 'table = MIXED, BIG'
    tt_run_ok
    assert_match "$TDX_OUT" 'Tables[[:space:]]*:[[:space:]]*done=2 failed=0 pending=0'
}

test_table_list_merges_one_table_section() {
    tt_env_new
    it_tables_raw '[old_cdc]' 'database = tdx_db' 'table = cdc' 'cdc_column = UPDATED_TS' \
        "where = NAME <> 'X'" '' '[tdx]' 'database = TDX_DB' 'table = {MIXED, CDC}'
    tt_run_ok
    assert_match "$TDX_OUT" 'Tables[[:space:]]*:[[:space:]]*done=2 failed=0 pending=0'
    assert_eq "$WM1" "$(tt_state "$CDC" watermark)" "cdc_column from the one-table section"
    assert_contains "$TDX_ERR" "TDX_DB.CDC is listed in [tdx] and also defined in [old_cdc]"
    grep -qF "listed in [tdx] and also defined in [old_cdc]" "$TDX_ROOT"/logs/*.log ||
        tt_fail "warning must be in the job log"
    [ -f "$TDX_ROOT/metadata/tdx_db_cdc.meta.ini" ] || tt_fail "file names use the list's database/table"
}

test_table_list_one_table_section_disables() {
    tt_env_new
    it_tables_raw '[tdx]' 'database = TDX_DB' 'table = {MIXED, BIG}' '' \
        '[big]' 'database = TDX_DB' 'table = BIG' 'enabled = false'
    tt_run_ok
    assert_match "$TDX_OUT" 'Tables[[:space:]]*:[[:space:]]*done=1 failed=0 pending=0'
    assert_empty "$(it_export_reqs "$BIG")"
}

it_sql_of() {   # all fake-tool scripts that read table $1 (TDX_DB.<name>), concatenated
    local d=$TDX_TMP/.sql.$$ f
    rm -rf "$d"; tt_fake_scripts "$d" >/dev/null
    for f in "$d"/*; do grep -qF "\"TDX_DB\".\"$1\"" "$f" && cat "$f"; done
    return 0
}
it_meta_where() { grep '^where = ' "$TDX_ROOT/metadata/tdx_db_$1.meta.ini"; }

test_table_list_where_applies_to_all() {
    tt_env_new
    it_tables_raw '[cust]' 'database = TDX_DB' 'table = {MIXED, BIG}' \
        "where = BIZ_DATE >= DATE '2024-01-01'" "    AND ID < 100" 'enable_for_all = true'
    tt_run_ok
    assert_match "$TDX_OUT" 'Tables[[:space:]]*:[[:space:]]*done=2 failed=0 pending=0'
    local t w="(BIZ_DATE >= DATE '2024-01-01' AND ID < 100)"
    for t in MIXED BIG; do
        assert_contains "$(it_sql_of "$t")" "$w" "$t export uses the list's where"
    done
    assert_eq "where = BIZ_DATE >= DATE '2024-01-01' AND ID < 100" "$(it_meta_where mixed)"
}

test_table_list_where_default_enabled() {
    tt_env_new
    it_tables_raw '[cust]' 'database = TDX_DB' 'table = MIXED, BIG' "where = ID < 100"
    tt_run_ok
    assert_contains "$(it_sql_of BIG)" "(ID < 100)" "enable_for_all defaults to true"
}

test_table_list_where_one_table_replaces() {
    tt_env_new
    it_tables_raw '[cust]' 'database = TDX_DB' 'table = {MIXED, BIG, CDC}' "where = ID < 100" '' \
        '[big]' 'database = TDX_DB' 'table = BIG' "where = VAL <> 'X'" '' \
        '[cdc]' 'database = TDX_DB' 'table = CDC' 'cdc_column = UPDATED_TS'
    tt_run_ok
    assert_match "$TDX_OUT" 'Tables[[:space:]]*:[[:space:]]*done=3 failed=0 pending=0'
    assert_contains "$(it_sql_of MIXED)" "(ID < 100)"
    assert_contains "$(it_sql_of BIG)" "(VAL <> 'X')" "one-table where is used"
    assert_not_contains "$(it_sql_of BIG)" "ID < 100" "one-table where replaces the list's"
    assert_contains "$(it_sql_of CDC)" "(ID < 100)" "one-table section without where keeps the list's"
    assert_eq "$WM1" "$(tt_state "$CDC" watermark)" "cdc_column still from the one-table section"
    assert_eq "where = VAL <> 'X'" "$(it_meta_where big)"
}

test_table_list_where_empty_override() {
    tt_env_new
    it_tables_raw '[cust]' 'database = TDX_DB' 'table = {MIXED, BIG}' "where = ID < 100" '' \
        '[big]' 'database = TDX_DB' 'table = BIG' 'where ='
    tt_run_ok
    assert_contains "$(it_sql_of MIXED)" "(ID < 100)"
    assert_not_contains "$(it_sql_of BIG)" "ID < 100" "empty one-table where clears the list's"
    assert_eq "where = " "$(it_meta_where big)"
}

test_table_list_where_disabled() {
    tt_env_new
    it_tables_raw '[cust]' 'database = TDX_DB' 'table = {MIXED, BIG}' "where = ID < 100" \
        'enable_for_all = false' '' '[big]' 'database = TDX_DB' 'table = BIG' "where = VAL <> 'X'"
    tt_run_ok
    assert_match "$TDX_OUT" 'Tables[[:space:]]*:[[:space:]]*done=2 failed=0 pending=0'
    assert_not_contains "$(it_sql_of MIXED)" "ID < 100" "enable_for_all = false ignores the list's where"
    assert_contains "$(it_sql_of BIG)" "(VAL <> 'X')" "one-table where still applies"
    assert_eq "where = " "$(it_meta_where mixed)"
}

test_table_list_config_errors() {
    tt_env_new
    local -a bad
    local case_
    for case_ in extra_key list_enabled bad_where bad_enable_for_all dup_list unbalanced empty_item trailing_brace trailing_plain dup_single dup_disabled; do
        case $case_ in
            list_enabled) it_tables_raw '[t]' 'database = TDX_DB' 'table = {MIXED, BIG}' 'enabled = false' ;;
            bad_where) it_tables_raw '[t]' 'database = TDX_DB' 'table = {MIXED, BIG}' 'where = ID > 1; DELETE FROM X' ;;
            bad_enable_for_all) it_tables_raw '[t]' 'database = TDX_DB' 'table = {MIXED, BIG}' 'where = ID > 1' 'enable_for_all = maybe' ;;
            extra_key) it_tables_raw '[t]' 'database = TDX_DB' 'table = {MIXED, BIG}' 'cdc_column = UPDATED_TS' ;;
            dup_list) it_tables_raw '[a]' 'database = TDX_DB' 'table = {MIXED, BIG}' '[b]' 'database = TDX_DB' 'table = {BIG}' ;;
            unbalanced) it_tables_raw '[t]' 'database = TDX_DB' 'table = {MIXED, BIG' ;;
            empty_item) it_tables_raw '[t]' 'database = TDX_DB' 'table = {MIXED,,BIG}' ;;
            trailing_brace) it_tables_raw '[t]' 'database = TDX_DB' 'table = {MIXED,}' ;;
            trailing_plain) it_tables_raw '[t]' 'database = TDX_DB' 'table = MIXED, BIG,,' ;;
            dup_disabled) it_tables_raw '[a]' 'database = TDX_DB' 'table = MIXED' 'enabled = false' \
                '[b]' 'database = TDX_DB' 'table = MIXED' ;;
            dup_single) it_tables_raw '[t]' 'database = TDX_DB' 'table = {MIXED, BIG}' \
                '[b1]' 'database = TDX_DB' 'table = BIG' '[b2]' 'database = TDX_DB' 'table = BIG' ;;
        esac
        tt_run
        assert_rc 2 "$TDX_RC" "$case_: $TDX_OUT$TDX_ERR"
    done
    assert_eq 0 "$(tt_fake_calls)"
}

test_table_list_names_are_literal() {
    tt_env_new
    : >"$TDX_TMP/MIXED_FILE"; : >"$TDX_TMP/MIXED_OTHER"
    it_tables_raw '[tdx]' 'database = TDX_DB' 'table = {MIXED*, BIG}'
    tt_run --dry-run
    assert_rc 0 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    assert_not_contains "$TDX_OUT$TDX_ERR" "MIXED_FILE"
    tt_run --status
    assert_contains "$TDX_OUT" "TDX_DB.MIXED*"
}

test_connect_check_reports_reason() {
    it_cred_env
    tt_config_set teradata connect_check true
    tt_config_set teradata host 127.0.0.1
    tt_config_set teradata port 1
    tt_run
    assert_rc 2 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    assert_contains "$TDX_ERR" "cannot reach 127.0.0.1:1: connection failed (Connection refused)"
    assert_eq 0 "$(tt_fake_calls)"
}
