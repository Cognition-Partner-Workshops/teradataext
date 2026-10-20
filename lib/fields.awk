# Internal query records (one per line, "|"-delimited, "\"-escaped, NULL = \N) -> row file:
# "R<nfields>" then one line per field: "N" (NULL) or "V<value>".
{
    n = 0; buf = ""; i = 1; L = length($0)
    while (i <= L) {
        c = substr($0, i, 1)
        if (c == "\\" && i < L) { buf = buf substr($0, i, 2); i += 2; continue }
        if (c == "|") { f[++n] = buf; buf = "" } else buf = buf c
        i++
    }
    f[++n] = buf
    print "R" n
    for (k = 1; k <= n; k++) {
        if (f[k] == "\\N") { print "N"; continue }
        out = ""; s = f[k]; j = 1; M = length(s)
        while (j <= M) {
            c = substr(s, j, 1)
            if (c == "\\" && j < M) { out = out substr(s, j + 1, 1); j += 2 } else { out = out c; j++ }
        }
        print "V" out
    }
}
