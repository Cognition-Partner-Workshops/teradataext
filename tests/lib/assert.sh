# Assertion helpers for tests/run_tests.sh. A failed assertion prints a message and exits the
# test's subshell with 1; tdx_skip exits with 77 (reported as SKIP).

tdx_fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
tdx_skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
tdx_show() { printf '%s' "$1" | sed -n '1,40p' | sed 's/^/    | /' >&2; }

assert_eq() {   # assert_eq EXPECTED ACTUAL [MSG]
    [ "$1" = "$2" ] && return 0
    printf 'expected: [%s]\n  actual: [%s]\n' "$1" "$2" >&2
    tdx_fail "${3:-values differ}"
}
assert_ne() { [ "$1" != "$2" ] || tdx_fail "${3:-value must not be [$1]}"; }
assert_contains() {   # assert_contains HAYSTACK NEEDLE [MSG]
    case $1 in *"$2"*) return 0 ;; esac
    tdx_show "$1"; tdx_fail "${3:-text does not contain [$2]}"
}
assert_not_contains() {
    case $1 in *"$2"*) tdx_show "$1"; tdx_fail "${3:-text must not contain [$2]}" ;; esac
    return 0
}
assert_match() {   # assert_match TEXT ERE [MSG]   (ERE matched against the whole text, any line)
    printf '%s\n' "$1" | grep -Eq -- "$2" && return 0
    tdx_show "$1"; tdx_fail "${3:-text does not match /$2/}"
}
assert_rc() {   # assert_rc EXPECTED ACTUAL [MSG]
    [ "$1" = "$2" ] && return 0
    tdx_fail "${3:-exit code} (expected $1, got $2)"
}
assert_file() { [ -f "$1" ] || tdx_fail "${2:-missing file $1}"; }
assert_no_file() { [ ! -e "$1" ] || tdx_fail "${2:-file must not exist: $1}"; }
assert_empty() { [ -z "$1" ] || { tdx_show "$1"; tdx_fail "${2:-expected empty}"; }; }
assert_not_empty() { [ -n "$1" ] || tdx_fail "${2:-expected a non-empty value}"; }
assert_count() {   # assert_count N TEXT [MSG]   (number of lines of TEXT; empty text = 0)
    local n=0
    [ -n "$2" ] && n=$(printf '%s\n' "$2" | wc -l | tr -d ' ')
    [ "$1" = "$n" ] && return 0
    tdx_show "$2"; tdx_fail "${3:-line count} (expected $1, got $n)"
}
assert_files_equal() {   # assert_files_equal EXPECTED_FILE ACTUAL_FILE [MSG]
    cmp -s "$1" "$2" && return 0
    diff "$1" "$2" 2>/dev/null | sed -n '1,30p' | sed 's/^/    | /' >&2
    tdx_fail "${3:-files differ: $1 $2}"
}
