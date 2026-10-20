# INI reader (configparser-compatible subset, no interpolation, full-line comments only).
# Output: "S<US>section" per section and "K<US>section<US>key<US>value" per option.
# On a syntax error prints "E<US>message" and exits 1.
BEGIN { US = "\037"; sec = ""; key = ""; nerr = 0 }
function strip(s) { sub(/^[ \t\r\f\v]+/, "", s); sub(/[ \t\r\f\v]+$/, "", s); return s }
function flush() { if (key != "") { gsub(/\n/, "\036", val); print "K" US sec US key US val; key = "" } }
function fail(msg) { flush(); print "E" US "While reading from '" FILENAME "' [line " FNR "]: " msg; nerr = 1; exit 1 }
{
    line = $0
    sub(/\r$/, "", line)
    t = strip(line)
    if (t == "") { flush(); next }
    if (substr(t, 1, 1) == "#" || substr(t, 1, 1) == ";") next
    match(line, /^[ \t]*/); ind = RLENGTH
    if (key != "" && ind > kind) { val = val "\n" t; next }
    if (substr(t, 1, 1) == "[" && (p = lastbr(t)) > 2) {
        flush()
        sec = substr(t, 2, p - 2)
        if (sec in seen_sec) fail("section '" sec "' already exists")
        seen_sec[sec] = 1
        print "S" US sec
        next
    }
    if (sec == "") fail("File contains no section headers.")
    pe = index(t, "="); pc = index(t, ":")
    p = (pe && (!pc || pe < pc)) ? pe : pc
    if (!p) fail("could not parse line " t)
    flush()
    key = strip(substr(t, 1, p - 1)); val = strip(substr(t, p + 1)); kind = ind
    if ((sec SUBSEP key) in seen_key) fail("option '" key "' in section '" sec "' already exists")
    seen_key[sec SUBSEP key] = 1
}
function lastbr(s,    i) { for (i = length(s); i > 0; i--) if (substr(s, i, 1) == "]") return i; return 0 }
END { if (!nerr) flush() }
