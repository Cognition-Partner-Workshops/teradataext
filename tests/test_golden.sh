# Golden comparison: re-runs the scenarios that produced tests/golden/<scenario>/ and compares
# every captured file (normalized like the generator's norm()), stdout and the exit code byte for
# byte; archives are compared by their sorted member list (data/<archive name>.members).

GOLDEN_DIR=$TDX_TESTS_DIR/golden

gd_sed_lit() { printf '%s' "$1" | sed 's/[]\/$*.^[&]/\\&/g'; }
# gd_norm < text > text  (uses GD_LAST_RUN_ID / GD_CYCLE_ID captured at snapshot time)
gd_norm() {
    local lits=()
    [ -n "$GD_LAST_RUN_ID" ] && lits+=(-e "s/$(gd_sed_lit "$GD_LAST_RUN_ID")/<LAST_RUN_ID>/g")
    [ -n "$GD_CYCLE_ID" ] && lits+=(-e "s/$(gd_sed_lit "$GD_CYCLE_ID")/<CYCLE_ID>/g")
    sed "${lits[@]}" -e "s/$(gd_sed_lit "$TDX_ROOT")/<ROOT>/g" -e "s/$(gd_sed_lit "$TDX_TMP")/<TMP>/g" |
        sed -E \
            -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z/<TS>/g' \
            -e 's/[0-9]{8}T[0-9]{6}Z(-[0-9]+)?-[0-9]+/<RUN_ID>/g' \
            -e 's/[0-9]{8}T[0-9]{6}Z(-[0-9]+)?/<CYCLE>/g' \
            -e 's/(elapsed_seconds = )[0-9.]+/\1<S>/g' \
            -e 's/(elapsed=)[0-9.]+s/\1<S>s/g' \
            -e 's/(Elapsed[[:space:]]*: )[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/\1<HMS>/g' \
            -e 's/tdx_lt_[0-9a-f]{12}/tdx_lt_<H>/g' \
            -e 's/(zip_sha256 = )[0-9a-f]{64}/\1<ARCHIVE_SHA>/g' \
            -e 's/(zip_file = [^[:space:]]+)\.(zip|tar\.gz)/\1.<ARCHIVE>/g' |
        gd_norm_extra
}
# applied to both sides: a previous run's id is only half-normalized by the generator
gd_norm_extra() { sed -E 's/<CYCLE_ID>-[0-9]+/<RUN_ID>/g'; }

# gd_snap NAME: capture the current run (TDX_RC / run.out) like the generator's snap(), then
# compare with tests/golden/NAME. Differences are collected in GD_FAILS.
gd_snap() {
    local name=$1 d=$TDX_TMP/snap/$1 sub p f n
    GD_LAST_RUN_ID="" GD_CYCLE_ID=""
    if [ -f "$TDX_STATE" ]; then
        GD_LAST_RUN_ID=$(tt_state _run last_run_id) || GD_LAST_RUN_ID=""
        GD_CYCLE_ID=$(tt_state _run cycle_id) || GD_CYCLE_ID=""
    fi
    rm -rf "$d"; mkdir -p "$d"
    printf '%s\n' "$TDX_RC" | gd_norm >"$d/exit_code"
    gd_norm <"$TDX_TMP/run.out" >"$d/stdout.txt"
    [ -f "$TDX_STATE" ] && mkdir -p "$d/config" && gd_norm <"$TDX_STATE" >"$d/config/process_state.ini"
    for sub in metadata work logs; do
        for p in "$TDX_ROOT/$sub"/*; do
            [ -f "$p" ] || continue
            f=${p##*/}
            case $f in .*|extract_*) continue ;; esac
            mkdir -p "$d/$sub"
            gd_norm <"$p" >"$d/$sub/$(printf '%s' "$f" | gd_norm)"
        done
    done
    for p in "$TDX_ROOT/data"/*; do
        [ -f "$p" ] || continue
        f=${p##*/}
        case $f in
        *.dat) mkdir -p "$d/data"; cp "$p" "$d/data/$f" ;;
        *.tar.gz) mkdir -p "$d/data"
            n=$(printf '%s' "${f%.tar.gz}" | gd_norm)
            tt_archive_members "$p" >"$d/data/$n.members" || GD_FAILS+="$name: data/$f: unreadable archive"$'\n' ;;
        esac
    done
    gd_compare "$name" "$d"
}

gd_compare() {
    local name=$1 d=$2 g=$GOLDEN_DIR/$1 rel
    [ -d "$g" ] || tt_fail "no golden directory $g"
    for rel in $( (cd "$g" && find . -type f; cd "$d" && find . -type f) | sed 's|^\./||' | sort -u); do
        if [ ! -f "$g/$rel" ]; then GD_FAILS+="$name: unexpected file $rel"$'\n'; continue; fi
        if [ ! -f "$d/$rel" ]; then GD_FAILS+="$name: missing file $rel"$'\n'; continue; fi
        case $rel in
        data/*.dat) cmp -s "$g/$rel" "$d/$rel" && continue ;;
        *) gd_norm_extra <"$g/$rel" >"$TDX_TMP/gold.txt"
           cmp -s "$TDX_TMP/gold.txt" "$d/$rel" && continue
           diff "$TDX_TMP/gold.txt" "$d/$rel" | sed -n '1,12p' | sed "s#^#    $name/$rel: #" >&2 ;;
        esac
        GD_FAILS+="$name: $rel differs"$'\n'
    done
}

gd_done() {
    [ -z "${GD_FAILS:-}" ] && return 0
    printf '%s' "$GD_FAILS" >&2
    tt_fail "golden differences: $(printf '%s' "$GD_FAILS" | grep -c .)"
}

gd_run() { tt_run "$@"; }
TYPES_TABLES=("types TDX_DB TYPES" "lobs TDX_DB LOBS" "hashed TDX_DB HASHED" "dated TDX_DB DATED")

test_golden_full() {
    tt_env_new; tt_config_set extract keep_raw_after_zip true
    gd_run; gd_snap full; gd_done
}

test_golden_types_utf8() {
    tt_env_new types.fixture; tt_set_tables "${TYPES_TABLES[@]}"
    tt_config_set extract keep_raw_after_zip true; tt_config_set teradata session_charset UTF8
    gd_run; gd_snap types_utf8; gd_done
}

test_golden_types_ascii_unicode_fail() {
    tt_env_new types.fixture; tt_set_tables "${TYPES_TABLES[0]}"
    tt_config_set extract keep_raw_after_zip true; tt_config_set extract char_trim none
    tt_config_set format empty_sentinel ""; tt_config_set format big_decimal_quote ""
    gd_run; gd_snap types_ascii_unicode_fail; gd_done
}

test_golden_types_options() {
    tt_env_new types.fixture; tt_set_tables "${TYPES_TABLES[0]}"
    tt_config_set extract keep_raw_after_zip true; tt_config_set extract char_trim none
    tt_config_set teradata session_charset UTF8
    tt_config_set format empty_sentinel ""; tt_config_set format big_decimal_quote ""
    gd_run; gd_snap types_options; gd_done
}

test_golden_cdc_cycles() {
    tt_env_new; tt_set_tables "cdc TDX_DB CDC cdc_column=UPDATED_TS"
    tt_config_set extract keep_raw_after_zip true
    gd_run; gd_snap cdc_cycle1
    tt_fixture_set TDX_DB.CDC cdc_max "2024-04-15 00:00:00.000000"
    gd_run --new-cycle; gd_snap cdc_cycle2; gd_done
}

test_golden_resume() {
    tt_env_new; tt_set_tables "big TDX_DB BIG"; tt_config_set extract keep_raw_after_zip true
    tt_fixture_add_failure table=TDX_DB.BIG query=export chunk=2 times=1 code=3707 "message=Syntax error, expected something"
    gd_run; gd_snap resume_run1
    gd_run; gd_snap resume_run2; gd_done
}

test_golden_bteq_fallback() {
    tt_env_new; tt_set_tables "big TDX_DB BIG"; tt_config_set extract keep_raw_after_zip true
    tt_fixture_add_failure table=TDX_DB.BIG tool=fexp query=export chunk=1 times=-1 code=2633 "message=Too many load/unload tasks running now"
    gd_run; gd_snap bteq_fallback; gd_done
}

test_golden_lob_fail() {
    tt_env_new; tt_set_tables "mixed TDX_DB MIXED" "lob TDX_DB LOB_BIG" "big TDX_DB BIG"
    gd_run; gd_snap lob_fail; gd_done
}

gd_log_mode() {
    tt_env_new; tt_set_tables "big TDX_DB BIG"; tt_config_set extract log_tool_output "$1"
    tt_fixture_add_failure table=TDX_DB.BIG query=export chunk=2 times=1 code=3707 "message=Syntax error, expected something"
    gd_run; gd_snap "log_$1"; gd_done
}
test_golden_log_errors() { gd_log_mode errors; }
test_golden_log_none() { gd_log_mode none; }

test_golden_dry_run_and_status() {
    tt_env_new
    gd_run --dry-run; gd_snap dry_run
    gd_run --status; gd_snap status_before
    gd_run
    gd_run --status; gd_snap status_after; gd_done
}
