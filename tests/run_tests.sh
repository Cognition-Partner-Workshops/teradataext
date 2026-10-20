#!/usr/bin/env bash
# Test runner (bash only): runs every tests/test_*.sh; each test_* function runs in its own
# subshell with a fresh temporary directory ($TDX_TEST_TMP).
#   tests/run_tests.sh [--awk BIN] [--bash BIN] [-v] [-k] [FILTER...]
#   --awk BIN   awk under test, exported as TDX_AWK (engine and fakes); "busybox awk" is accepted
#   --bash BIN  put BIN first in PATH as "bash" (the engine and fakes use #!/usr/bin/env bash)
#   -v          show the output of passing/skipped tests too;  -k  keep the temp dirs
#   FILTER      substring (or glob) matched against "<file>:<test>"; any match selects a test
# Exit status: 0 all passed/skipped, 1 a test failed, 2 usage error.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
verbose=0 keep=0 filters=() awk_bin=${TDX_AWK:-} bash_bin=""
while [ $# -gt 0 ]; do
    case $1 in
    --awk) awk_bin=$2; shift 2 ;;
    --awk=*) awk_bin=${1#--awk=}; shift ;;
    --bash) bash_bin=$2; shift 2 ;;
    --bash=*) bash_bin=${1#--bash=}; shift ;;
    -v) verbose=1; shift ;;
    -k) keep=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    --) shift; filters+=("$@"); break ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) filters+=("$1"); shift ;;
    esac
done

RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/tdx_tests.XXXXXX") || exit 2
[ "$keep" = 1 ] || trap 'rm -rf "$RUN_TMP"' EXIT
mkdir -p "$RUN_TMP/bin"
if [ -n "$bash_bin" ]; then
    bash_path=$(command -v "$bash_bin") || { echo "bash not found: $bash_bin" >&2; exit 2; }
    ln -s "$bash_path" "$RUN_TMP/bin/bash"
fi
if [ -n "$awk_bin" ]; then
    case $awk_bin in
    *" "*) printf '#!/bin/sh\nexec %s "$@"\n' "$awk_bin" >"$RUN_TMP/bin/tdx-awk"; chmod +x "$RUN_TMP/bin/tdx-awk"
        awk_bin=$RUN_TMP/bin/tdx-awk ;;
    */*) ;;
    *) awk_bin=$(command -v "$awk_bin") || { echo "awk not found: $1" >&2; exit 2; } ;;
    esac
    export TDX_AWK=$awk_bin
fi
export PATH="$RUN_TMP/bin:$PATH"
if [ -n "$bash_bin" ]; then
    # re-run this runner under the requested bash so test code runs on it as well
    if [ -z "${TDX_RUNNER_REEXEC:-}" ]; then
        args=(); [ "$verbose" = 1 ] && args+=(-v); [ "$keep" = 1 ] && args+=(-k)
        [ -n "${TDX_AWK:-}" ] && args+=(--awk "$TDX_AWK")
        TDX_RUNNER_REEXEC=1 "$RUN_TMP/bin/bash" "$0" "${args[@]}" -- "${filters[@]}"
        exit $?
    fi
fi

selected() {
    local f
    [ ${#filters[@]} -eq 0 ] && return 0
    for f in "${filters[@]}"; do
        case $1 in *$f*) return 0 ;; esac
    done
    return 1
}

echo "bash: $BASH_VERSION ($BASH)   awk: ${TDX_AWK:-awk}"
pass=0 fail=0 skip=0 failed=()
for file in "$TESTS_DIR"/test_*.sh; do
    [ -f "$file" ] || continue
    base=$(basename "$file" .sh)
    tests=$(set +u; export TDX_TEST_TMP=$RUN_TMP; source "$TESTS_DIR/lib/assert.sh"; source "$TESTS_DIR/lib/env.sh"
        source "$file" >/dev/null 2>&1; declare -F | while read -r _ _ name; do
        case $name in test_*) echo "$name" ;; esac; done)
    for t in $tests; do
        selected "$base:$t" || continue
        dir=$RUN_TMP/$base.$t
        mkdir -p "$dir"
        start=$SECONDS
        (
            set +u
            export TDX_TEST_TMP=$dir
            cd "$dir" || exit 1
            source "$TESTS_DIR/lib/assert.sh"
            source "$TESTS_DIR/lib/env.sh"
            source "$file"
            "$t"
        ) >"$dir.log" 2>&1 </dev/null
        rc=$?
        el=$((SECONDS - start))
        case $rc in
        0) pass=$((pass + 1)); echo "PASS $base:$t (${el}s)"; [ "$verbose" = 1 ] && sed 's/^/    /' "$dir.log" ;;
        77) skip=$((skip + 1)); echo "SKIP $base:$t - $(grep '^SKIP: ' "$dir.log" | tail -1 | cut -c7-)" ;;
        *) fail=$((fail + 1)); failed+=("$base:$t"); echo "FAIL $base:$t (rc=$rc, ${el}s)"
           sed -n '1,80p' "$dir.log" | sed 's/^/    /' ;;
        esac
        [ "$keep" = 1 ] || rm -rf "$dir" "$dir.log"
    done
done
echo "----------------------------------------------------------------------"
echo "$((pass + fail + skip)) tests: $pass passed, $fail failed, $skip skipped"
for t in ${failed[@]+"${failed[@]}"}; do echo "  FAILED: $t"; done
[ "$fail" -eq 0 ]
