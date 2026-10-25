# Reads unmasked fexp/bteq output (stdin). Writes the job-log body (masked, per log_tool_output
# = mode) to the file "body" and prints facts parsed from the UNMASKED text on stdout:
# fexp_rows=, bteq_rows=, bteq_fail=, session_limit=, err_code=, err_line=
# Password: ENVIRON["TDX_MASK_PW"]; session-limit codes/patterns: ENVIRON["TDX_SL_CODES"/"TDX_SL_PATTERNS"].
BEGIN {
    mask_init(ENVIRON["TDX_MASK_PW"])
    nc = split(ENVIRON["TDX_SL_CODES"], codes, ",")
    for (i = 1; i <= nc; i++) if (codes[i] != "") slc[codes[i] + 0] = 1
    np = split(ENVIRON["TDX_SL_PATTERNS"], pats, "\037")
    fexp_rows = ""; bteq_rows = ""; bteq_fail = 0; sl = 0; err_code = ""; err_line = ""; err_coded = 0; nerr = 0
    printf "" > body
}
function isw(c) { return c ~ /[A-Za-z0-9_]/ }
# Each "Failure|Error" + blanks + digit run, with word boundaries; calls back via globals.
function scan_codes(s, minlen, maxlen,    p, rest, pre, m, q, d, nxt, found, off) {
    rest = s; off = 0; found = ""
    while (match(rest, /(Failure|Error)[ \t]+[0-9]+/)) {
        p = RSTART; m = RLENGTH
        pre = (off + p > 1) ? substr(s, off + p - 1, 1) : ""
        q = substr(rest, p, m); d = q; sub(/^[A-Za-z]+[ \t]+/, "", d)
        nxt = substr(rest, p + m, 1)
        if (!isw(pre) && length(d) >= minlen && (maxlen == 0 || (length(d) <= maxlen && !isw(nxt)))) {
            if (found == "") found = d
            if (maxlen) { if ((d + 0) in slc) sl = 1 }
        }
        off += p + m - 1; rest = substr(rest, p + m)
    }
    return found
}
function has_word(ls, w,    rest, p, off, pre, nxt) {
    rest = ls; off = 0
    while ((p = index(rest, w)) > 0) {
        pre = (off + p > 1) ? substr(ls, off + p - 1, 1) : ""
        nxt = substr(rest, p + length(w), 1)
        if (!isw(pre) && !isw(nxt)) return 1
        off += p; rest = substr(rest, p + 1)
    }
    return 0
}
function is_err_line(s,    ls) {
    ls = tolower(s)
    if (has_word(ls, "failure") || has_word(ls, "error") || has_word(ls, "failed") || has_word(ls, "warning")) return 1
    return ls ~ /return code encountered = '?[1-9]/
}
function pystrip(s) { sub(/^[ \t\r\f\v]+/, "", s); sub(/[ \t\r\f\v]+$/, "", s); return s }
{
    raw = $0; lraw = tolower(raw)
    if (match(lraw, /[0-9][0-9,]*[ \t]+total records written/)) {
        v = substr(lraw, RSTART, RLENGTH); sub(/[ \t].*/, "", v); gsub(/,/, "", v); fexp_rows = v + 0
    }
    if (match(lraw, /query completed\.[ \t]+([0-9][0-9,]*[ \t]+rows?[ \t]+found|no[ \t]+rows[ \t]+found)/)) {
        v = substr(lraw, RSTART, RLENGTH); sub(/^query completed\.[ \t]+/, "", v)
        if (v ~ /^no/) bteq_rows = 0
        else { sub(/[ \t].*/, "", v); gsub(/,/, "", v); bteq_rows = v + 0 }
    }
    if (raw ~ /\*\*\* (Failure|Error) [0-9]/) bteq_fail = 1
    scan_codes(raw, 3, 5)
    for (i = 1; i <= np; i++) if (pats[i] != "" && index(lraw, pats[i])) sl = 1
    m = mask_line(raw)
    if (err_code == "") err_code = scan_codes(m, 1, 0)
    # a numbered "*** Failure/Error NNNN" line wins over notices such as "*** Error messages now ..."
    if (!err_coded && m ~ /\*\*\* (Failure|Error) [0-9]/) { err_line = pystrip(m); err_coded = 1 }
    else if (err_line == "" && (index(m, "Failure") || index(m, "Error"))) err_line = pystrip(m)
    if (mode == "masked") print m > body
    else if (mode == "errors" && is_err_line(m)) { printf "%s%s", (nerr++ ? "\n" : ""), m > body }
}
END {
    if (mode == "none") printf "%s", "(tool output not persisted: log_tool_output = none)" > body
    else if (mode == "masked" && NR > 0) { }
    close(body)
    print "fexp_rows=" fexp_rows
    print "bteq_rows=" bteq_rows
    print "bteq_fail=" bteq_fail
    print "session_limit=" sl
    print "err_code=" err_code
    print "err_line=" err_line
}
