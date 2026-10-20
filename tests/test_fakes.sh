# Direct tests of the fake fexp/bteq (no engine required). Port of the former test_fakes.py.

fk_setup() {
    TDX_TMP=$TDX_TEST_TMP
    TDX_FIXTURE=$TDX_TMP/fixture.txt
    TDX_FAKE_LOG_FILE=$TDX_TMP/calls.log
    cp "$TDX_FIXTURES_DIR/basic.fixture" "$TDX_FIXTURE"
    FK_LOGON=".LOGON tdfake/user,$TD_PASS_TEST;"
}

fk_run_tool() {   # fk_run_tool TOOL SCRIPT_FILE -> FK_RC, FK_OUT
    FK_OUT=$(TDX_FAKE_FIXTURE=$TDX_FIXTURE TDX_FAKE_LOG=$TDX_FAKE_LOG_FILE "$TDX_FAKES_DIR/$1" <"$2" 2>&1)
    FK_RC=$?
}

fk_bteq() {   # fk_bteq MARKER... -> FK_RC FK_OUT, outputs $TDX_TMP/out<i>.raw
    local s=$TDX_TMP/bteq.script i=0 m
    { printf '%s\n' ".SET SESSION CHARSET 'ASCII';" "$FK_LOGON" ".SET ERROROUT STDOUT;"
      for m in "$@"; do
          printf '%s\n' ".EXPORT DATA FILE = $TDX_TMP/out$i.raw;" "/* TDX $m */ SELECT 1;" \
              ".IF ERRORCODE <> 0 THEN .QUIT ERRORCODE;" ".EXPORT RESET;"
          i=$((i + 1))
      done
      printf '%s\n' ".LOGOFF;" ".QUIT 0;"; } >"$s"
    fk_run_tool bteq "$s"
}

fk_fexp() {   # fk_fexp MARKER [OUT] -> FK_RC FK_OUT
    local s=$TDX_TMP/fexp.script out=${2:-$TDX_TMP/fexp.raw}
    printf '%s\n' ".LOGTABLE TDX_DB.tdx_lt_abc;" "$FK_LOGON" ".BEGIN EXPORT SESSIONS 4 TENACITY 0;" \
        ".EXPORT OUTFILE $out FORMAT TEXT MODE RECORD;" "/* TDX $1 */ SELECT x FROM t;" \
        ".END EXPORT;" ".LOGOFF;" >"$s"
    fk_run_tool fexp "$s"
}

# fk_parse fexp|bteq FILE: records (%-encoded, one per line); fails on a malformed layout
fk_parse() {
    local out
    out=$(od -An -v -tu1 "$2" | tdx_awk -v bteq="$([ "$1" = bteq ] && echo 1 || echo 0)" '
        { for (i = 1; i <= NF; i++) b[n++] = $i + 0 }
        END {
            for (i = 1; i < 256; i++) chr[i] = sprintf("%c", i)
            p = 0
            while (p < n) {
                if (bteq) { rl = b[p] + 256 * b[p + 1]; p += 2 }
                len = b[p] + 256 * b[p + 1]; p += 2
                if (bteq && rl != len + 2) { print "BAD record length"; exit 1 }
                r = ""
                for (j = 0; j < len; j++) r = r chr[b[p + j]]
                p += len
                if (p >= n || b[p] != 10) { print "BAD end of record"; exit 1 }
                p++
                gsub(/%/, "%25", r); gsub(/\t/, "%09", r); gsub(/\n/, "%0A", r); gsub(/\r/, "%0D", r)
                print r
            }
        }') || tdx_fail "bad $1 layout in $2: $out"
    printf '%s' "$out"
}

test_executable() {
    local t
    for t in fexp bteq; do
        [ -x "$TDX_FAKES_DIR/$t" ] || tdx_fail "$t not executable"
        assert_eq '#!/usr/bin/env bash' "$(head -1 "$TDX_FAKES_DIR/$t")" "$t shebang"
    done
}

test_missing_logon() {
    fk_setup
    local t
    printf '%s\n' "/* TDX query=count db=TDX_DB table=BIG */ SELECT 1;" >"$TDX_TMP/s"
    for t in fexp bteq; do
        fk_run_tool "$t" "$TDX_TMP/s"
        assert_rc 12 "$FK_RC" "$t"
        assert_contains "$FK_OUT" LOGON
    done
}

test_script_logged_with_password() {
    fk_setup
    fk_bteq "query=count db=TDX_DB table=BIG"
    assert_eq 1 "$(tdx_fake_calls)" "one call logged"
    assert_match "$(grep '^@call ' "$TDX_FAKE_LOG_FILE")" '^@call tool=bteq '
    assert_eq 1 "$(tdx_fake_scripts "$TDX_TMP/scripts")"
    assert_contains "$(cat "$TDX_TMP/scripts/001.bteq")" "$TD_PASS_TEST"
    assert_files_equal "$TDX_TMP/bteq.script" "$TDX_TMP/scripts/001.bteq" "logged script = stdin"
}

test_unknown_table() {
    fk_setup
    fk_bteq "query=count db=TDX_DB table=NOPE"
    assert_rc 8 "$FK_RC"
    assert_contains "$FK_OUT" "*** Failure 3807 Object 'TDX_DB.NOPE' does not exist."
    fk_fexp "query=export db=TDX_DB table=NOPE"
    assert_rc 12 "$FK_RC"
    assert_contains "$FK_OUT" "Failure 3807"
}

test_metadata_queries_bteq_layout() {
    fk_setup
    fk_bteq "query=columns db=tdx_db table=mixed" \
        "query=index db=TDX_DB table=MIXED" \
        "query=stats db=TDX_DB table=BIG" \
        "query=stats db=TDX_DB table=MIXED" \
        "query=count db=TDX_DB table=BIG" \
        "query=minmax db=TDX_DB table=BIG col=ID" \
        "query=minmax db=TDX_DB table=BIG col=VAL" \
        'query=lobcheck db=TDX_DB table=LOB_BIG cols="NOTES,ID"' \
        "query=rowcheck db=TDX_DB table=BIG"
    assert_rc 0 "$FK_RC" "$FK_OUT"
    local cols
    cols=$(fk_parse bteq "$TDX_TMP/out0.raw")
    assert_count 8 "$cols"
    assert_eq '1|ID|I|4|\N|\N|N|0' "$(printf '%s\n' "$cols" | sed -n 1p)"
    assert_eq '2|AMT|D|8|10|2|Y|0' "$(printf '%s\n' "$cols" | sed -n 2p)"
    assert_eq 'P|Y|1|ID' "$(fk_parse bteq "$TDX_TMP/out1.raw")"
    assert_eq '25' "$(fk_parse bteq "$TDX_TMP/out2.raw")"
    assert_eq '\N' "$(fk_parse bteq "$TDX_TMP/out3.raw")"
    assert_eq '25' "$(fk_parse bteq "$TDX_TMP/out4.raw")"
    assert_eq '1|25' "$(fk_parse bteq "$TDX_TMP/out5.raw")"
    assert_eq '\N|\N' "$(fk_parse bteq "$TDX_TMP/out6.raw")"
    assert_eq '50000|\N' "$(fk_parse bteq "$TDX_TMP/out7.raw")"
    assert_eq '20' "$(fk_parse bteq "$TDX_TMP/out8.raw")"
    assert_eq 8 "$(printf '%s\n' "$FK_OUT" | grep -cF '*** Query completed. 1 rows found. 1 column returned.')"
    assert_contains "$FK_OUT" "*** Query completed. 8 rows found. 1 column returned."
}

test_minmax_column_from_sql() {
    fk_setup
    printf '%s\n' "$FK_LOGON" ".EXPORT DATA FILE=$TDX_TMP/mm.raw;" \
        "/* TDX query=minmax db=TDX_DB table=BIG */ SELECT MIN(ID), MAX(ID) FROM TDX_DB.BIG;" >"$TDX_TMP/s"
    fk_run_tool bteq "$TDX_TMP/s"
    assert_rc 0 "$FK_RC" "$FK_OUT"
    assert_eq '1|25' "$(fk_parse bteq "$TDX_TMP/mm.raw")"
}

test_field_escaping() {
    fk_setup
    tdx_fixture_set TDX_DB.BIG column 1 'A|B\C'$'\n''D' CV 5 '\N' '\N' Y 1
    fk_bteq "query=columns db=TDX_DB table=BIG"
    assert_rc 0 "$FK_RC" "$FK_OUT"
    assert_eq '1|A\|B\\C\%0AD|CV|5|\N|\N|Y|1' "$(fk_parse bteq "$TDX_TMP/out0.raw")"
}

test_cdcmax() {
    fk_setup
    fk_bteq "query=cdcmax db=TDX_DB table=CDC" \
        'query=cdcmax db=TDX_DB table=CDC cdc_gt="2024-02-01 00:00:00.000000"' \
        'query=cdcmax db=TDX_DB table=CDC cdc_gt="2024-03-01 00:00:00.000000"' \
        "query=cdcmax db=TDX_DB table=BIG"
    assert_rc 0 "$FK_RC" "$FK_OUT"
    assert_eq '2024-03-01 00:00:00.000000' "$(fk_parse bteq "$TDX_TMP/out0.raw")"
    assert_eq '2024-03-01 00:00:00.000000' "$(fk_parse bteq "$TDX_TMP/out1.raw")"
    assert_eq '\N' "$(fk_parse bteq "$TDX_TMP/out2.raw")"
    assert_eq '\N' "$(fk_parse bteq "$TDX_TMP/out3.raw")"
}

test_fexp_export_text_layout() {
    fk_setup
    fk_fexp "query=export db=TDX_DB table=MIXED"
    assert_rc 0 "$FK_RC" "$FK_OUT"
    assert_eq "$(tdx_fixture_lines TDX_DB.MIXED)" "$(fk_parse fexp "$TDX_TMP/fexp.raw")"
    assert_contains "$FK_OUT" "**** 12:00:00 UTY8722 4 total records written to output file."
}

test_bteq_export_and_no_rows() {
    fk_setup
    fk_bteq "query=export db=TDX_DB table=BIG chunk=1/4" \
        'query=export db=TDX_DB table=CDC cdc_gt="2024-05-01 00:00:00.000000"'
    assert_rc 0 "$FK_RC" "$FK_OUT"
    assert_eq "$(for i in 1 5 9 13 17 21 25; do printf '%d|value %02d\n' "$i" "$i"; done)" \
        "$(fk_parse bteq "$TDX_TMP/out0.raw")"
    assert_file "$TDX_TMP/out1.raw"
    [ -s "$TDX_TMP/out1.raw" ] && tdx_fail "out1.raw must be empty"
    assert_contains "$FK_OUT" "*** Query completed. 7 rows found. 1 column returned."
    assert_contains "$FK_OUT" "*** Query completed. No rows found."
}

test_chunks_partition_rows() {
    fk_setup
    local i got=""
    for i in 1 2 3; do
        fk_fexp "query=export db=TDX_DB table=BIG chunk=$i/3" "$TDX_TMP/c$i"
        assert_rc 0 "$FK_RC" "$FK_OUT"
        got+=$(fk_parse fexp "$TDX_TMP/c$i")$'\n'
    done
    assert_eq "$(for i in $(seq 1 25); do printf '%d|value %02d\n' "$i" "$i"; done | sort)" \
        "$(printf '%s' "$got" | sort)"
}

test_cdc_window() {
    fk_setup
    fk_fexp 'query=export db=TDX_DB table=CDC cdc_gt="2024-01-01 00:00:00.000000" cdc_le="2024-04-01 00:00:00.000000"'
    assert_rc 0 "$FK_RC" "$FK_OUT"
    assert_eq "feb mar apr" "$(fk_parse fexp "$TDX_TMP/fexp.raw" | cut -d'|' -f2 | tr '\n' ' ' | sed 's/ $//')"
}

test_failure_times_across_processes() {
    fk_setup
    tdx_fixture_add_failure table=tdx_db.big tool=fexp query=export times=2 code=2633 \
        "message=Too many load/unload tasks running now"
    local out=$TDX_TMP/f.raw k
    for k in 1 2; do
        fk_fexp "query=export db=TDX_DB table=BIG" "$out"
        assert_rc 12 "$FK_RC"
        assert_contains "$FK_OUT" "*** Failure 2633 Too many load/unload tasks running now."
        assert_no_file "$out"
    done
    # bteq is not affected by a fexp-only failure
    fk_bteq "query=export db=TDX_DB table=BIG"
    assert_rc 0 "$FK_RC" "$FK_OUT"
    fk_fexp "query=export db=TDX_DB table=BIG" "$out"
    assert_rc 0 "$FK_RC" "$FK_OUT"
    assert_count 25 "$(fk_parse fexp "$out")"
    assert_file "$TDX_FIXTURE.state"
}

test_failure_chunk_and_bteq_exit_code() {
    fk_setup
    tdx_fixture_add_failure table=TDX_DB.BIG query=export chunk=2 times=1 code=3707 "message=Syntax error"
    fk_bteq "query=export db=TDX_DB table=BIG chunk=1/3"
    assert_rc 0 "$FK_RC" "$FK_OUT"
    fk_bteq "query=export db=TDX_DB table=BIG chunk=2/3"
    assert_rc 8 "$FK_RC"
    assert_contains "$FK_OUT" "*** Failure 3707 Syntax error."
    fk_bteq "query=export db=TDX_DB table=BIG chunk=2/3"
    assert_rc 0 "$FK_RC" "$FK_OUT"
}

test_metadata_queries_unaffected_by_export_failure() {
    fk_setup
    tdx_fixture_add_failure table=TDX_DB.BIG times=-1 code=2633 "message=Too many load/unload tasks running now"
    fk_bteq "query=count db=TDX_DB table=BIG"
    assert_rc 0 "$FK_RC" "$FK_OUT"
    local k
    for k in 1 2 3; do
        fk_bteq "query=export db=TDX_DB table=BIG"
        assert_rc 8 "$FK_RC"
    done
}
