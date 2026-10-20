# Unit tests of engine internals (bash port of test_engine_units.py). Tests of lib/*.sh functions
# and lib/mask.awk SKIP while that interface does not exist yet; the rest are black-box.

ut_need_fn() {   # source every lib/*.sh, skip unless function $1 exists
    local f
    read -r -a TDX_AWK_CMD <<<"${TDX_AWK:-awk}"
    TDX_LIB=$TDX_REPO_ROOT/lib
    for f in common config types plan extract; do
        [ -f "$TDX_LIB/$f.sh" ] && source "$TDX_LIB/$f.sh" >/dev/null 2>&1
    done
    declare -F "$1" >/dev/null || tt_skip "$1 not defined by lib/*.sh (bash engine not present yet)"
}
ut_need_file() { [ -f "$TDX_REPO_ROOT/$1" ] || tt_skip "$1 not present yet"; }
ut_mask() { printf '%s\n' "$1" | TDX_MASK_PW=$2 tt_awk -f "$TDX_REPO_ROOT/lib/maskfn.awk" -f "$TDX_REPO_ROOT/lib/mask.awk"; }

# ----- rawdecode.awk ------------------------------------------------------------------------------
ut_le16() { printf "\\$(printf '%03o' $(($1 % 256)))\\$(printf '%03o' $(($1 / 256)))"; }
ut_rec() {   # ut_rec fexp|bteq|reclen|bare PAYLOAD -> one raw record on stdout
    local LC_ALL=C
    local n=${#2}
    case $1 in bteq|reclen) ut_le16 $((n + 2)) ;; esac
    ut_le16 "$n"; printf '%s' "$2"
    case $1 in fexp|bteq) printf '\n' ;; esac
}
ut_decode() {   # ut_decode RAW REC_PREFIX EOR [WANT] [LIMIT] [UTF8] -> status line; records in $RAW.dat
    od -An -v -tu1 "$1" | tt_awk -v rec_prefix="$2" -v eor="$3" -v want="${4:-1}" -v limit="${5:-64000}" \
        -v utf8="${6:-0}" -v delim=124 -v esc=92 -v out="$1.dat" -f "$TDX_REPO_ROOT/lib/rawdecode.awk"
}

test_stream_raw_export_layouts() {
    ut_need_file lib/rawdecode.awk
    local layout pfx eor r raw=$TDX_TEST_TMP/x.raw
    printf '%s\n' '\N' 'a\|b' '' >"$TDX_TEST_TMP/expected"
    for layout in "fexp 0 1" "bteq 1 1" "reclen 1 0" "bare 0 0"; do
        set -- $layout
        : >"$raw"
        for r in '\N' 'a\|b' ''; do ut_rec "$1" "$r" >>"$raw"; done
        assert_eq "OK 3" "$(ut_decode "$raw" "$2" "$3" 1)" "$1 layout (want=1 counts the escaped | once)"
        assert_files_equal "$TDX_TEST_TMP/expected" "$raw.dat" "$1 records"
        : >"$raw"
        assert_eq "OK 0" "$(ut_decode "$raw" "$2" "$3")" "$1 empty"
    done
    # a file in another layout must not decode (MISMATCH or ERROR)
    for r in 'abc' 'de'; do ut_rec bteq "$r"; done >"$raw"
    case $(ut_decode "$raw" 0 1) in OK*) tt_fail "bteq data, fexp layout must not decode";; esac
    for r in 'abc' 'de'; do ut_rec fexp "$r"; done >"$raw"
    case $(ut_decode "$raw" 1 1) in OK*) tt_fail "fexp data, bteq layout must not decode";; esac
    case $(ut_decode "$raw" 0 0) in OK*) tt_fail "fexp data, bare layout must not decode";; esac
}

test_stream_raw_export_rejects_garbage() {
    ut_need_file lib/rawdecode.awk
    local raw=$TDX_TEST_TMP/x.raw l
    printf '\377\377\001' >"$raw"
    for l in "0 1" "1 1" "1 0" "0 0"; do
        assert_eq MISMATCH "$(ut_decode "$raw" $l)" "garbage, layout $l"
    done
}

test_rawdecode_nul_byte() {
    ut_need_file lib/rawdecode.awk
    local raw=$TDX_TEST_TMP/x.raw
    { ut_rec fexp ok; ut_le16 3; printf 'a\000b\n'; } >"$raw"
    assert_eq "ERROR nul 2" "$(ut_decode "$raw" 0 1)"
}

test_rawdecode_field_count() {
    ut_need_file lib/rawdecode.awk
    local raw=$TDX_TEST_TMP/x.raw
    { ut_rec fexp 'a|b|c'; ut_rec fexp 'a\|b|c'; } >"$raw"
    assert_eq "ERROR fields 2 2" "$(ut_decode "$raw" 0 1 3)"
    ut_rec fexp 'a\\|b|c' >"$raw"
    assert_eq "OK 1" "$(ut_decode "$raw" 0 1 3)" "escaped backslash does not escape the delimiter"
}

test_rawdecode_record_limit() {
    ut_need_file lib/rawdecode.awk
    local raw=$TDX_TEST_TMP/x.raw
    { ut_rec bteq abc; ut_rec bteq abcd; } >"$raw"
    assert_eq "ERROR limit 2" "$(ut_decode "$raw" 1 1 1 3)"
    ut_rec bteq $'\303\251\303\251\303\251' >"$raw"
    assert_eq "OK 1" "$(ut_decode "$raw" 1 1 1 3 1)" "utf8=1 counts characters"
    assert_eq "ERROR limit 1" "$(ut_decode "$raw" 1 1 1 3 0)" "utf8=0 counts bytes"
}

# ----- lib/*.sh functions and mask.awk (skipped until the bash engine exists) -------------------
test_field_count_custom_escape() {
    ut_need_fn tdx_field_count
    assert_eq 2 "$(tdx_field_count 'a!|b|second' '|' '!')"
    assert_eq 2 "$(tdx_field_count 'a\|b|second' '|' '\')"
}

test_check_where() {
    ut_need_fn tdx_check_where
    tdx_check_where "STATUS <> 'X;--/*' AND ID > 5" || tt_fail "string literal content must be accepted"
    tdx_check_where "NAME = 'O''Brien'" || tt_fail "doubled quote must be accepted"
    local bad
    for bad in "1=1; DELETE FROM T" "1=1 -- x" "1=1 /* x */" "NAME = 'open"; do
        tdx_check_where "$bad" && tt_fail "must reject: $bad"
    done
    return 0
}

test_mask_text_variants_and_logon() {
    ut_need_file lib/mask.awk; ut_need_file lib/maskfn.awk
    local out
    out=$(ut_mask $'.LOGON host/user,Secr3t\nerr SECR3T and secr3t' Secr3t)
    assert_not_contains "$(tt_lower "$out")" ecr3t
    assert_contains "$out" ".LOGON host/user,"
    out=$(ut_mask ".logon h/u,other-pw-form" Secr3t)
    assert_contains "$(tt_lower "$out")" ".logon h/u,"
    assert_not_contains "$out" other-pw-form
}

test_mask_text_fragments() {
    ut_need_file lib/mask.awk; ut_need_file lib/maskfn.awk
    local out
    out=$(ut_mask "bad logon: 'LongSecret' ... 'Secret9'" LongSecret99)
    assert_not_contains "$out" LongSecret
    assert_not_contains "$out" Secret9
}

test_tool_log_modes() {
    ut_need_fn tdx_tool_log_text
    ut_need_fn tdx_tool_error_summary
    local out=$'UTY8724 Logon ok\n12 total records written\n*** Failure 3807 Object \'X\' does not exist.'
    assert_eq "$out" "$(printf '%s' "$out" | tdx_tool_log_text masked)"
    assert_eq "*** Failure 3807 Object 'X' does not exist." "$(printf '%s' "$out" | tdx_tool_log_text errors)"
    assert_not_contains "$(printf '%s' "$out" | tdx_tool_log_text none)" Object
    assert_eq "Teradata error 3807" "$(printf '%s' "$out" | tdx_tool_error_summary none 8)"
    assert_contains "$(printf '%s' "$out" | tdx_tool_error_summary errors 8)" "Object 'X'"
    assert_eq "exit code 12" "$(printf '' | tdx_tool_error_summary none 12)"
}

test_cdc_window_pred_initial_includes_nulls() {
    ut_need_fn tdx_cdc_window_pred
    tdx_cdc_window_pred I UPD "" 10 || tt_fail "rc $?"
    assert_contains "$REPLY" '"UPD" IS NULL'
    tdx_cdc_window_pred I UPD 5 10 || tt_fail "rc $?"
    assert_not_contains "$REPLY" "IS NULL"
    assert_contains "$REPLY" '"UPD" > 5'
    tdx_cdc_window_pred I UPD "" "" || tt_fail "rc $?"
    assert_eq "" "$REPLY"
}

# ----- black-box replacements of former white-box tests -----------------------------------------
ut_export_sql() {   # all export requests' scripts of the last runs, concatenated
    local d=$TDX_TMP/scripts.$RANDOM
    tt_fake_scripts "$d" >/dev/null
    cat "$d"/* 2>/dev/null | grep -F '/* TDX query=export'
}

test_record_cast_stays_within_varchar_max() {
    tt_env_new
    tt_set_tables "mixed TDX_DB MIXED"
    tt_run_ok
    assert_contains "$(ut_export_sql)" "AS VARCHAR(64000))" "latin columns: 64000 (63999 + 1 headroom)"
    tt_env_new types.fixture
    tt_set_tables "types TDX_DB TYPES"
    tt_config_set teradata session_charset UTF8
    tt_run_ok
    assert_contains "$(ut_export_sql)" "AS VARCHAR(32000))" "unicode columns: 32000"
    tt_env_new types.fixture
    tt_set_tables "types TDX_DB TYPES"
    tt_config_set teradata session_charset UTF8
    tt_config_set extract max_row_length 100
    tt_fixture_set TDX_DB.TYPES row_max 50
    tt_run
    assert_contains "$(ut_export_sql)" "AS VARCHAR(101))" "max_row_length 100 -> 101"
}

test_wrap_fields_keeps_identifier_spaces() {
    tt_env_new
    tt_set_tables "mixed TDX_DB MIXED"
    tt_run_ok
    local d=$TDX_TMP/scripts sql
    tt_fake_scripts "$d" >/dev/null
    sql=$(cat "$d"/* | grep -F '/* TDX query=columns')
    assert_contains "$sql" "TRIM(CAST(ColumnId"
    assert_not_contains "$sql" "TRIM(CAST(ColumnName"
}

test_new_cycle_id_never_reuses_archive_name() {
    tt_env_new
    tt_set_tables "mixed TDX_DB MIXED"
    mkdir -p "$TDX_ROOT/data"
    local now k ts cycle
    now=$(date -u +%s)
    for k in $(seq 0 30); do
        TZ=UTC printf -v ts '%(%Y%m%dT%H%M%SZ)T' $((now + k))
        for ext in tar.gz zip; do : >"$TDX_ROOT/data/x_$ts.$ext"; : >"$TDX_ROOT/data/x_$ts-2.$ext"; done
    done
    tt_run_ok
    cycle=$(tt_state _run cycle_id)
    assert_match "$cycle" '^[0-9]{8}T[0-9]{6}Z-[0-9]+$' "taken base id must get a suffix"
    [ "${cycle##*-}" -ge 3 ] || tt_fail "suffix -2 is taken too: $cycle"
    assert_empty "$(find "$TDX_ROOT/data" -name 'x_*' -size +0 | head -1)" "existing archives untouched"
    tt_reset_fake_log
    tt_run_ok --new-cycle
    assert_ne "$cycle" "$(tt_state _run cycle_id)" "a new cycle never reuses the previous id"
}

test_interrupted_cleanup_resumes_from_recorded_zip() {
    tt_env_new
    tt_run_ok
    local key=TDX_DB.BIG z sha
    z=$(tt_state "$key" zip_file); sha=$(tt_state "$key" zip_sha256)
    # simulate a crash after the archive was recorded and raw files deleted, before status=done
    TDXK=$key tt_awk '
        /^\[/ { s = $0; sub(/^\[/, "", s); sub(/\][ \t\r]*$/, "", s) }
        s == ENVIRON["TDXK"] && /^status[ \t]*=/ { print "status = in_progress"; next }
        { print }' "$TDX_STATE" >"$TDX_STATE.new" && mv -f "$TDX_STATE.new" "$TDX_STATE"
    assert_eq in_progress "$(tt_state "$key" status)"
    tt_reset_fake_log
    tt_run_ok --tables "$key"
    assert_eq done "$(tt_state "$key" status)"
    assert_eq "$z $sha" "$(tt_state "$key" zip_file) $(tt_state "$key" zip_sha256)"
    assert_empty "$(tt_requests export)"
}

ut_run_failing() {   # ut_run_failing MODE -> UT_LOGS (all *.fexp.log / *.bteq.log)
    tt_env_new
    tt_config_set extract log_tool_output "$1"
    tt_fixture_add_failure table=TDX_DB.BIG query=export chunk=1 times=1 code=3707 "message=Syntax error, expected something"
    tt_run
    assert_rc 1 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    UT_LOGS=$(cat "$TDX_ROOT"/logs/*.fexp.log "$TDX_ROOT"/logs/*.bteq.log 2>/dev/null)
}

test_none_keeps_no_tool_output() {
    ut_run_failing none
    assert_contains "$UT_LOGS" "log_tool_output = none"
    assert_not_contains "$UT_LOGS" "Syntax error"
    assert_not_contains "$(tt_lower "$UT_LOGS")" records
    assert_contains "$(tt_state TDX_DB.BIG last_error)" 3707
    assert_not_contains "$(tt_state TDX_DB.BIG last_error)" "Syntax error"
}

test_errors_keeps_only_error_lines() {
    ut_run_failing errors
    assert_contains "$UT_LOGS" 3707
    assert_not_contains "$(tt_lower "$UT_LOGS")" "total records"
}

test_invalid_mode_is_config_error() {
    tt_env_new
    tt_config_set extract log_tool_output verbose
    tt_run --dry-run
    assert_rc 2 "$TDX_RC" "$TDX_OUT$TDX_ERR"
    assert_contains "$TDX_OUT$TDX_ERR" log_tool_output
}
