# Check a [table] where filter (stdin): prints "OK", or the reason it is rejected
# (statement separators and comments are only allowed inside '...' literals).
BEGIN { q = sprintf("%c", 39) }
{ if (NR > 1) s = s "\n"; s = s $0 }
END {
    out = ""; i = 1; n = length(s)
    while (i <= n) {
        c = substr(s, i, 1)
        if (c != q) { out = out c; i++; continue }
        j = i + 1; closed = 0
        while (j <= n) {
            if (substr(s, j, 1) == q) {
                if (substr(s, j + 1, 1) == q) { j += 2; continue }
                closed = 1
                break
            }
            j++
        }
        if (!closed) { print "unbalanced quote"; exit }
        out = out " "
        i = j + 1
    }
    nt = split(";|--|/*|*/", tok, "|")
    for (k = 1; k <= nt; k++) {
        if (index(out, tok[k])) { msg = q tok[k] q; msg = msg " is not allowed"; print msg; exit }
    }
    print "OK"
}
