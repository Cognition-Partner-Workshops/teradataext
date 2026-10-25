# Decode one raw FastExport/BTEQ export of a single VARCHAR column into LF-terminated records.
# Input: `od -An -v -tu1 <raw>` (decimal byte values). Run with LC_ALL=C.
# Vars: rec_prefix, eor, be (0/1: the layout tried; be = big-endian lengths), want (fields per record, 0 = no check),
#       limit (max record length, 0 = no check), utf8 (1 = length in UTF-8 characters, else bytes),
#       delim, esc (byte values), out (target file).
# Prints one line: "OK <records>", "MISMATCH" (layout does not fit) or
# "ERROR fields <record> <nfields>" / "ERROR limit <record>" / "ERROR nul <record>".
BEGIN {
    for (i = 1; i < 256; i++) chr[i] = sprintf("%c", i)
    hlen = rec_prefix ? 4 : 2
    st = 0; hn = 0; n = 0; err = ""; bad = 0
    printf "" > out
}
{
    if (bad) next
    buf = ""
    for (i = 1; i <= NF; i++) {
        b = $i + 0
        if (st == 0) {
            h[hn++] = b
            if (hn < hlen) continue
            if (be) { vlen = 256 * h[hlen - 2] + h[hlen - 1]; rlen = 256 * h[0] + h[1] }
            else { vlen = h[hlen - 2] + 256 * h[hlen - 1]; rlen = h[0] + 256 * h[1] }
            if (rec_prefix && rlen != vlen + 2) { bad = 1; break }
            hn = 0; nf = 1; clen = 0; escd = 0; vrem = vlen
            if (vrem == 0) { if (eor) st = 2; else { endrec(); st = 0 } } else st = 1
        } else if (st == 1) {
            if (err == "") {
                if (b == 0) err = "nul " (n + 1)
                else {
                    if (escd) escd = 0
                    else if (b == esc) escd = 1
                    else if (b == delim) nf++
                    if (!utf8 || b < 128 || b > 191) clen++
                    buf = buf chr[b]
                }
            }
            if (--vrem == 0) {
                if (err == "") { printf "%s", buf > out; buf = "" }
                if (eor) st = 2; else { endrec(); st = 0 }
            }
        } else {
            if (b != 10) { bad = 1; break }
            endrec(); st = 0
        }
    }
    if (!bad && err == "" && buf != "") printf "%s", buf > out
}
function endrec() {
    n++
    if (err != "") return
    if (want > 0 && nf != want) err = "fields " n " " nf
    else if (limit > 0 && clen > limit) err = "limit " n
    else printf "\n" > out
}
END {
    close(out)
    if (bad || st != 0 || hn != 0) print "MISMATCH"
    else if (err != "") print "ERROR " err
    else print "OK " n
}
