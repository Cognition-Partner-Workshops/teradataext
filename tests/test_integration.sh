# Black-box integration tests of teradata_extract.sh driven by the fake fexp/bteq.
# Only the CLI and the on-disk outputs defined in docs/DESIGN.md are used. Port of test_integration.py.

MIXED=TDX_DB.MIXED BIG=TDX_DB.BIG CDC=TDX_DB.CDC LOB=TDX_DB.LOB_BIG
WM1="2024-03-01 00:00:00.000000"
WM2="2024-04-15 00:00:00.000000"

it_chunk_list() { printf '%s' "$1" | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort -n | tr '\n' ' ' | sed 's/ $//'; }
it_records() { tdx_archive_records "$1" | cut -f2-; }   # all records of all .dat members
it_export_reqs() { tdx_requests export "$1"; }
it_chunk_of() { tdx_req_get "$1" chunk | cut -d/ -f1; }

test_full_run_success() {
    tdx_env_new
    tdx_run_ok
    assert_contains "$TDX_OUT" "TERADATA EXTRACT SUMMARY"
    assert_match "$TDX_OUT" 'Tables[[:space:]]*:[[:space:]]*done=3 failed=0 pending=0'
    local cycle key rows sec stem a names f
    cycle=$(tdx_state _run cycle_id)
    assert_not_empty "$cycle" "cycle_id"
    for key in "$MIXED:4" "$BIG:25" "$CDC:3"; do
        rows=${key#*:}; key=${key%:*}
        assert_eq done "$(tdx_state "$key" status)" "$key status"
        assert_eq "$rows" "$(tdx_state "$key" rows_exported)" "$key rows_exported"
        assert_match "$(tdx_state "$key" checksum_sha256)" '^[0-9a-f]{64}$' "$key checksum"
        stem=$(tdx_lower "${key/./_}")
        assert_eq "${stem}_$cycle.tar.gz" "$(tdx_state "$key" zip_file)" "$key archive name"
        a=$(tdx_archive_path "$key")
        assert_file "$a"
        assert_eq "$(tdx_state "$key" zip_sha256)" "$(sha256sum "$a" | cut -d' ' -f1)" "$key archive sha"
        gzip -t "$a" || tdx_fail "gzip -t $a"
        names=$(tdx_archive_members "$a") || tdx_fail "tar tf $a"
        for f in $(tdx_state "$key" files | tr ',' ' '); do
            printf '%s\n' "$names" | grep -qxF -- "$f" || tdx_fail "$f not in $a"
        done
        assert_count "$rows" "$(it_records "$key")" "$key archived records"
    done
    assert_empty "$(cd "$TDX_ROOT/data" && ls | grep '\.dat$')" "no .dat left"
    assert_empty "$(cd "$TDX_ROOT/data" && ls | grep '\.raw$')" "no .raw left"
    # MIXED is unchunked: one member with exactly the fixture lines
    a=$(tdx_archive_path "$MIXED")
    assert_eq tdx_db_mixed.dat "$(tdx_archive_members "$a")"
    assert_eq "$(tdx_fixture_lines "$MIXED")" "$(it_records "$MIXED")"
    tdx_archive_extract "$a" "$TDX_TMP/x"
    (tdx_fixture_lines "$MIXED" | while IFS= read -r l; do tdx_dec "$l"; printf '\n'; done) >"$TDX_TMP/expected.dat"
    assert_files_equal "$TDX_TMP/expected.dat" "$TDX_TMP/x/tdx_db_mixed.dat" "raw member bytes"
    assert_eq none "$(tdx_state "$MIXED" chunk_strategy)"
    assert_eq bteq "$(tdx_state "$MIXED" method)"
}

test_meta_files() {
    tdx_env_new
    tdx_run_ok
    local key m cols s name exp enc rs
    for key in "$MIXED" "$BIG" "$CDC"; do
        tdx_ini_sections "$(tdx_meta_file "${key%.*}" "${key#*.}")" | grep -qx table || tdx_fail "$key meta has no [table]"
    done
    m=$(tdx_meta_file TDX_DB MIXED)
    assert_eq 8 "$(tdx_ini_get "$m" table column_count)"
    assert_eq UTC "$(tdx_ini_get "$m" table timezone_policy)"
    cols=$(tdx_ini_sections "$m" | grep '^column\.')
    assert_eq "$(for i in 1 2 3 4 5 6 7 8; do printf 'column.%03d\n' "$i"; done)" "$cols"
    for exp in "ID int_text INTEGER" "AMT decimal_text DECIMAL(10,2)" "BIG_AMT decimal_quoted DECIMAL(38,4)" \
        "NAME escaped_text VARCHAR(50)" "BIZ_DATE iso_date DATE" "CREATED_TS iso_timestamp TIMESTAMP" \
        "EVENT_TSZ utc_iso_timestamp TIMESTAMPTZ" "PAYLOAD hex VARBYTE(16)"; do
        set -- $exp
        s=""
        for c in $cols; do [ "$(tdx_ini_get "$m" "$c" name)" = "$1" ] && s=$c; done
        assert_not_empty "$s" "column $1"
        assert_eq "$2" "$(tdx_ini_get "$m" "$s" output_encoding)" "$1 output_encoding"
        assert_eq "$3" "$(tdx_ini_get "$m" "$s" redshift_type)" "$1 redshift_type"
        [ "$1" = ID ] && assert_eq 1 "$(tdx_ini_get "$m" "$s" position)" "ID position"
        [ "$1" = EVENT_TSZ ] && { tdx_ini_get "$m" "$s" source_timezone >/dev/null || tdx_fail "EVENT_TSZ source_timezone"; }
    done
    return 0
}

test_audit_and_state_header() {
    tdx_env_new
    tdx_run_ok
    assert_eq "# THIS FILE IS MANAGED BY teradata_extract - DO NOT EDIT." "$(head -1 "$TDX_STATE" | cut -c1-58)"
    local lines run_id key rows line
    lines=$(tdx_audit_lines)
    assert_count 3 "$lines" "audit lines"
    run_id=$(tdx_state _run last_run_id)
    for key in "$MIXED:4" "$BIG:25" "$CDC:3"; do
        rows=${key#*:}; key=${key%:*}
        line=$(printf '%s\n' "$lines" | grep -F " | $key | " | head -1)
        assert_not_empty "$line" "audit line for $key"
        assert_eq "$run_id" "$(printf '%s' "$line" | tdx_awk -F ' [|] ' '{ v = $2; gsub(/^[ \t]+|[ \t]+$/, "", v); print v }')"
        assert_eq done "$(printf '%s' "$line" | tdx_awk -F ' [|] ' '{ v = $4; gsub(/^[ \t]+|[ \t]+$/, "", v); print v }')"
        assert_eq "rows=$rows" "$(printf '%s' "$line" | tdx_awk -F ' [|] ' '{ v = $5; gsub(/^[ \t]+|[ \t]+$/, "", v); print v }')"
    done
}

test_done_tables_skipped_on_rerun() {
    tdx_env_new
    tdx_run_ok
    tdx_reset_fake_log
    tdx_run_ok
    assert_empty "$(tdx_requests export)" "no export requests on rerun"
    assert_match "$TDX_OUT" 'skipped already done=3'
}

test_password_never_written() {
    tdx_env_new
    tdx_run_ok
    assert_empty "$(tdx_files_containing "$TD_PASS_TEST")" "files containing the password"
    local n
    n=$(find "$TDX_ROOT/work" -type f -name '*.*' | wc -l)
    [ "$n" -gt 0 ] || tdx_fail "no saved scripts in work/"
    grep -rqF '********' "$TDX_ROOT/work" || tdx_fail "saved scripts must contain the masked logon"
    n=$(tdx_fake_scripts "$TDX_TMP/scripts")
    grep -lF -- "$TD_PASS_TEST" "$TDX_TMP/scripts"/* >/dev/null 2>&1 || tdx_fail "password must reach the tools via stdin"
}

test_dry_run_and_status_make_no_calls() {
    tdx_env_new
    tdx_run --dry-run
    assert_rc 0 "$TDX_RC" "--dry-run: $TDX_OUT$TDX_ERR"
    tdx_run --status
    assert_rc 0 "$TDX_RC" "--status: $TDX_OUT$TDX_ERR"
    assert_eq 0 "$(tdx_fake_calls)" "fake calls"
}

test_tables_filter() {
    tdx_env_new
    tdx_run_ok --tables tdx_db.mixed
    assert_eq done "$(tdx_state "$MIXED" status)"
    assert_empty "$(it_export_reqs "$BIG")"
}

test_keep_raw_after_zip() {
    tdx_env_new
    tdx_config_set extract keep_raw_after_zip true
    tdx_run_ok
    local dats
    dats=$(cd "$TDX_ROOT/data" && ls | grep '\.dat$' | sort)
    printf '%s\n' "$dats" | grep -qx tdx_db_mixed.dat || tdx_fail "tdx_db_mixed.dat kept"
    printf '%s\n' "$dats" | grep -q '^tdx_db_big\.part' || tdx_fail "tdx_db_big.part*.dat kept"
    assert_not_empty "$(cd "$TDX_ROOT/data" && ls | grep '\.tar\.gz$')" "archives exist"
}

it_chunk_env() { tdx_env_new; tdx_set_tables "big TDX_DB BIG"; }

test_chunked_union_equals_fixture() {
    it_chunk_env
    tdx_run_ok
    local n i members sum=0 r
    n=$(tdx_state "$BIG" chunk_count)
    [ "$n" -gt 1 ] || tdx_fail "chunk_count $n"
    assert_ne none "$(tdx_state "$BIG" chunk_strategy)"
    assert_eq "$(seq 1 "$n" | tr '\n' ' ' | sed 's/ $//')" "$(it_chunk_list "$(tdx_state "$BIG" chunks_done)")"
    members=$(tdx_archive_members "$(tdx_archive_path "$BIG")")
    assert_eq "$(for i in $(seq 1 "$n"); do printf 'tdx_db_big.part%03d.dat\n' "$i"; done)" "$members"
    assert_eq "$(tdx_fixture_lines "$BIG" | sort)" "$(it_records "$BIG" | sort)"
    for i in $(seq 1 "$n"); do
        assert_eq done "$(tdx_state "$(printf '%s/part%03d' "$BIG" "$i")" status)"
        assert_match "$(tdx_state "$(printf '%s/part%03d' "$BIG" "$i")" sha256)" '^[0-9a-f]{64}$'
        r=$(tdx_state "$(printf '%s/part%03d' "$BIG" "$i")" rows); sum=$((sum + r))
    done
    assert_eq 25 "$sum"
}

test_resume_reruns_only_failed_chunk() {
    it_chunk_env
    tdx_fixture_add_failure "table=$BIG" query=export chunk=2 times=1 code=3707 "message=Syntax error, expected something"
    tdx_run
    assert_rc 1 "$TDX_RC" "first run: $TDX_OUT$TDX_ERR"
    local n reqs
    n=$(tdx_state "$BIG" chunk_count)
    assert_eq failed "$(tdx_state "$BIG" status)"
    assert_not_empty "$(tdx_state "$BIG" last_error)"
    assert_eq "$(seq 1 "$n" | grep -vx 2 | tr '\n' ' ' | sed 's/ $//')" "$(it_chunk_list "$(tdx_state "$BIG" chunks_done)")"
    assert_contains "$TDX_OUT" FAILED
    tdx_reset_fake_log
    tdx_run_ok
    reqs=$(it_export_reqs "$BIG")
    assert_count 1 "$reqs" "export requests on resume"
    assert_eq 2 "$(it_chunk_of "$reqs")"
    assert_eq done "$(tdx_state "$BIG" status)"
    assert_eq "$(seq 1 "$n" | tr '\n' ' ' | sed 's/ $//')" "$(it_chunk_list "$(tdx_state "$BIG" chunks_done)")"
    assert_eq 25 "$(tdx_state "$BIG" rows_exported)"
    assert_eq "$(tdx_fixture_lines "$BIG" | sort)" "$(it_records "$BIG" | sort)"
}

test_session_limit_retry() {
    it_chunk_env
    tdx_fixture_add_failure "table=$BIG" query=export chunk=1 times=1 code=2633 "message=Too many load/unload tasks running now"
    tdx_run_ok
    local n=0 r
    while IFS= read -r r; do [ "$(it_chunk_of "$r")" = 1 ] && n=$((n + 1)); done <<<"$(it_export_reqs "$BIG")"
    assert_eq 2 "$n" "chunk 1 export requests"
    assert_eq done "$(tdx_state "$BIG" status)"
}

test_bteq_fallback_after_retries() {
    it_chunk_env
    tdx_fixture_add_failure "table=$BIG" tool=fexp query=export chunk=1 times=-1 code=2633 "message=Too many load/unload tasks running now"
    tdx_run_ok
    assert_eq done "$(tdx_state "$BIG" status)"
    assert_eq bteq "$(tdx_state "$BIG/part001" method)"
    local tools="" r
    while IFS= read -r r; do [ "$(it_chunk_of "$r")" = 1 ] && tools+="${r%%$'\t'*} "; done <<<"$(it_export_reqs "$BIG")"
    assert_eq "fexp fexp fexp bteq " "$tools" "1 + retry_attempts(2), then fallback"
    assert_eq 25 "$(tdx_state "$BIG" rows_exported)"
}

it_cdc_env() { tdx_env_new; tdx_set_tables "cdc TDX_DB CDC cdc_column=UPDATED_TS"; }

test_incremental_cycles() {
    it_cdc_env
    local lines reqs r
    lines=$(tdx_fixture_lines "$CDC")
    tdx_run_ok
    assert_eq "$WM1" "$(tdx_state "$CDC" watermark)"
    assert_eq 3 "$(tdx_state "$CDC" rows_exported)"
    assert_eq "$(printf '%s\n' "$lines" | sed -n 1,3p | sort)" "$(it_records "$CDC" | sort)"
    tdx_fixture_set "$CDC" cdc_max "$WM2"
    tdx_reset_fake_log
    tdx_run_ok --new-cycle
    assert_eq done "$(tdx_state "$CDC" status)"
    assert_eq "$WM2" "$(tdx_state "$CDC" watermark)"
    assert_eq 2 "$(tdx_state "$CDC" rows_exported)"
    assert_eq "$(printf '%s\n' "$lines" | sed -n '4,$p' | sort)" "$(it_records "$CDC" | sort)"
    reqs=$(it_export_reqs "$CDC")
    assert_not_empty "$reqs" "cycle 2 export requests"
    while IFS= read -r r; do
        assert_eq "$WM1" "$(tdx_req_get "$r" cdc_gt)" "cdc_gt"
        assert_eq "$WM2" "$(tdx_req_get "$r" cdc_le)" "cdc_le"
    done <<<"$reqs"
}

test_no_new_rows_keeps_watermark() {
    it_cdc_env
    tdx_run_ok
    assert_eq "$WM1" "$(tdx_state "$CDC" watermark)"
    tdx_fixture_set "$CDC" cdc_max '\N'
    tdx_run_ok --new-cycle
    assert_eq done "$(tdx_state "$CDC" status)"
    assert_eq 0 "$(tdx_state "$CDC" rows_exported)"
    assert_eq "$WM1" "$(tdx_state "$CDC" watermark)"
}

test_lob_over_limit_fails_table() {
    tdx_env_new
    tdx_set_tables "mixed TDX_DB MIXED" "lob TDX_DB LOB_BIG" "big TDX_DB BIG"
    tdx_run
    assert_rc 1 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    assert_eq failed "$(tdx_state "$LOB" status)"
    assert_contains "$(tdx_state "$LOB" last_error)" lob_max_length
    assert_eq done "$(tdx_state "$MIXED" status)"
    assert_eq done "$(tdx_state "$BIG" status)"
    assert_match "$TDX_OUT" 'done=2 failed=1'
    assert_contains "$TDX_OUT" FAILED
    assert_contains "$TDX_OUT" "$LOB"
    assert_empty "$(it_export_reqs "$LOB")"
    tdx_audit_lines | grep -qF " | $LOB | failed | " || tdx_fail "audit line for failed $LOB"
}

it_cred_env() { tdx_env_new; tdx_set_tables "mixed TDX_DB MIXED"; }

test_no_credentials() {
    it_cred_env
    tdx_run --cred none
    assert_rc 2 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    assert_eq 0 "$(tdx_fake_calls)"
}

test_only_user_set() {
    it_cred_env
    tdx_run --cred none --env TD_USER=someone
    assert_rc 2 "$TDX_RC" "$TDX_OUT$TDX_ERR"
}

test_credentials_file_too_open() {
    it_cred_env
    tdx_write_credentials_file 644
    tdx_run --cred none
    assert_rc 2 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    assert_eq 0 "$(tdx_fake_calls)"
}

test_credentials_file_0600() {
    it_cred_env
    tdx_write_credentials_file 600
    tdx_run --cred none
    assert_rc 0 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    assert_eq done "$(tdx_state "$MIXED" status)"
    assert_empty "$(tdx_files_containing "$TD_PASS_TEST")"
    local n f
    n=$(tdx_fake_scripts "$TDX_TMP/scripts")
    [ "$n" -gt 0 ] || tdx_fail "no fake calls"
    for f in "$TDX_TMP/scripts"/*; do grep -qF -- "$TD_PASS_TEST" "$f" || tdx_fail "password missing from $f"; done
}
