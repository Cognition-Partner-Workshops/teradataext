# Shared logic of the fake fexp/bteq (see tests/fakes/README.md). Run with LC_ALL=C.
# mode=logon  : script file -> "1" if it has a .LOGON host/user,password line, else "0"
# mode=events : script file -> one line per request marker: path=<p> TAB key=value ... (%XX-encoded)
# mode=plan   : fixture file + script file, tool=fexp|bteq -> execution plan for _tdxfake.sh:
#   REQ <key> / FAIL <idx> <times> <code> <msg> / MISSING / UNKNOWN <kind> / OPEN <path> /
#   REC <bytes> / END <n>     (<key>, <msg>, <kind>, <path>, <bytes> are printf formats)
BEGIN {
    for (i = 1; i < 256; i++) { chr[i] = sprintf("%c", i); ord[chr[i]] = i }
    WS = " \t\n\r" sprintf("%c%c", 11, 12)
    WORDC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
    HEXD = "0123456789abcdef"
    NULLV = sprintf("%c", 1) "NULL" sprintf("%c", 1)
    if (mode == "plan") load_fixture(fixture)
    s = ""
    while ((getline line < script) > 0) s = s line "\n"
    close(script)
    if (mode == "logon") { print has_logon(s); exit }
    scan(s)
    exit
}

function isws(c) { return c != "" && index(WS, c) > 0 }
function isw(c) { return c != "" && index(WORDC, c) > 0 }
function skipws(t, p) { while (isws(substr(t, p, 1))) p++; return p }

function has_logon(t,   n, a, i, l, p, q) {
    n = split(t, a, "\n")
    for (i = 1; i <= n; i++) {
        l = a[i]; p = skipws(l, 1)
        if (toupper(substr(l, p, 6)) != ".LOGON" || !isws(substr(l, p + 6, 1))) continue
        p = skipws(l, p + 6)
        q = p; while (substr(l, q, 1) != "" && !isws(substr(l, q, 1)) && index("/;", substr(l, q, 1)) == 0) q++
        if (q == p || substr(l, q, 1) != "/") continue
        p = ++q; while (substr(l, q, 1) != "" && !isws(substr(l, q, 1)) && index(",;", substr(l, q, 1)) == 0) q++
        if (q == p || substr(l, q, 1) != ",") continue
        if (substr(l, q + 1, 1) != "" && !isws(substr(l, q + 1, 1))) return 1
    }
    return 0
}

# ---- script scanning (same alternatives and order as the former Python EVENT_RE) ----
function ppath(t, p,   c, j) {
    c = substr(t, p, 1)
    if (c == "\"" || c == "'") {
        j = index(substr(t, p + 1), c)
        if (j > 1) { PV = substr(t, p + 1, j - 1); PE = p + j + 1; return 1 }
    }
    j = p
    while ((c = substr(t, j, 1)) != "" && c != ";" && !isws(c)) j++
    if (j == p) return 0
    PV = substr(t, p, j - p); PE = j
    return 1
}
function pfile2(t, u, r) {
    if (substr(u, r, 4) != "FILE") return 0
    r = skipws(t, r + 4)
    if (substr(t, r, 1) != "=") return 0
    return ppath(t, skipws(t, r + 1))
}
function pfile(t, u, q,   w, k, n) {
    n = split("DATA INDICDATA REPORT", w, " ")
    for (k = 1; k <= n; k++)
        if (substr(u, q, length(w[k])) == w[k] && isws(substr(t, q + length(w[k]), 1)))
            if (pfile2(t, u, skipws(t, q + length(w[k])))) return 1
    return pfile2(t, u, q)
}
function scan(t,   u, L, p, c, q, j, body, mend, k, sql, cur, have) {
    u = toupper(t); L = length(t); p = 1; have = 0; cur = ""
    while (p <= L) {
        c = substr(t, p, 1)
        if (c == "/" && substr(t, p + 1, 1) == "*") {
            q = skipws(t, p + 2)
            if (substr(u, q, 3) == "TDX" && isws(substr(t, q + 3, 1))) {
                q = skipws(t, q + 3)
                j = index(substr(t, q), "*/")
                if (j > 0) {
                    body = substr(t, q, j - 1); mend = q + j + 1
                    k = index(substr(t, mend), ";")
                    sql = k > 0 ? substr(t, mend, k - 1) : substr(t, mend)
                    request(body, have, cur, sql)
                    p = mend; continue
                }
            }
        } else if (c == "." && substr(u, p, 7) == ".EXPORT" && isws(substr(t, p + 7, 1))) {
            q = skipws(t, p + 7)
            if (substr(u, q, 7) == "OUTFILE" && isws(substr(t, q + 7, 1)) && ppath(t, skipws(t, q + 7))) {
                cur = PV; have = 1; p = PE; continue
            }
            if (pfile(t, u, q)) { cur = PV; have = 1; p = PE; continue }
            if (substr(u, q, 5) == "RESET") { cur = ""; have = 0; p = q + 5; continue }
        }
        p++
    }
}
function pmarker(b,   n, p, j, k, e, key) {
    for (key in M) delete M[key]
    n = length(b); p = 1
    while (p <= n) {
        if (!isw(substr(b, p, 1))) { p++; continue }
        j = p; while (isw(substr(b, j, 1))) j++
        key = tolower(substr(b, p, j - p))
        k = skipws(b, j)
        if (substr(b, k, 1) != "=") { p++; continue }
        k = skipws(b, k + 1)
        if (substr(b, k, 1) == "\"") {
            e = index(substr(b, k + 1), "\"")
            if (e > 0) { M[key] = substr(b, k + 1, e - 1); p = k + e + 1; continue }
        }
        e = k; while (e <= n && !isws(substr(b, e, 1))) e++
        if (e == k) { p++; continue }
        M[key] = substr(b, k, e - k); p = e
    }
}

# ---- encoding helpers ----
function pfmt(v,   out, i, n, c, b) {
    out = ""; n = length(v)
    for (i = 1; i <= n; i++) {
        c = substr(v, i, 1); b = ord[c]
        if (c == "%") out = out "%%"
        else if (c == "\\") out = out "\\\\"
        else if (b >= 32 && b < 127) out = out c
        else out = out sprintf("\\%03o", b)
    }
    return out
}
function penc(v,   out, i, n, c) {
    out = ""; n = length(v)
    for (i = 1; i <= n; i++) {
        c = substr(v, i, 1)
        if (c == "%" || c == "\t" || c == "\n" || c == "\r") out = out sprintf("%%%02X", ord[c])
        else out = out c
    }
    return out
}
function dec(v,   out, i, h) {
    if (index(v, "%") == 0) return v
    out = ""
    while ((i = index(v, "%")) > 0) {
        h = tolower(substr(v, i + 1, 2))
        if (length(h) == 2 && index(HEXD, substr(h, 1, 1)) && index(HEXD, substr(h, 2, 1)) && h != "00") {
            out = out substr(v, 1, i - 1) chr[(index(HEXD, substr(h, 1, 1)) - 1) * 16 + index(HEXD, substr(h, 2, 1)) - 1]
            v = substr(v, i + 3)
        } else { out = out substr(v, 1, i); v = substr(v, i + 1) }
    }
    return out v
}
function val(v) { return v == "\\N" ? NULLV : dec(v) }
function escf(v,   out, i, n, c) {
    if (v == NULLV) return "\\N"
    if (index(v, "\\") == 0 && index(v, "|") == 0 && index(v, "\r") == 0 && index(v, "\n") == 0) return v
    out = ""; n = length(v)
    for (i = 1; i <= n; i++) {
        c = substr(v, i, 1)
        if (c == "\\" || c == "|" || c == "\r" || c == "\n") out = out "\\"
        out = out c
    }
    return out
}
# join_fields of f[from..n]
function joinf(f, from, n,   i, out) {
    out = ""
    for (i = from; i <= n; i++) { if (i > from) out = out "|"; out = out escf(val(f[i])) }
    return out
}
function u8len(v,   i, n, b, c) {
    n = length(v); c = 0
    for (i = 1; i <= n; i++) { b = ord[substr(v, i, 1)]; if (b < 128 || b > 191) c++ }
    return c
}

# ---- fixture ----
function load_fixture(path,   line, n, f, K, k, cu, i, eq, fk) {
    nfail = 0
    while ((getline line < path) > 0) {
        sub(/\r$/, "", line)
        if (line ~ /^[ \t]*(#|$)/) continue
        n = split(line, f, "\t")
        if (f[1] == "failure") {
            nfail++
            ftool[nfail] = ""; fquery[nfail] = "export"; fchunk[nfail] = ""; ftimes[nfail] = 1
            fcode[nfail] = 2633; fmsg[nfail] = "Too many load/unload tasks running now"; ftable[nfail] = ""
            for (i = 2; i <= n; i++) {
                eq = index(f[i], "="); if (!eq) continue
                fk = substr(f[i], 1, eq - 1); v = substr(f[i], eq + 1)
                if (v == "\\N") { if (fk == "times") ftimes[nfail] = -1; else if (fk == "tool" || fk == "chunk") v = ""; else continue }
                else v = dec(v)
                if (fk == "table") ftable[nfail] = v
                else if (fk == "tool") ftool[nfail] = v
                else if (fk == "query") fquery[nfail] = v
                else if (fk == "chunk") fchunk[nfail] = v
                else if (fk == "times" && v != "\\N") ftimes[nfail] = v + 0
                else if (fk == "code") fcode[nfail] = v
                else if (fk == "message") fmsg[nfail] = v
            }
            continue
        }
        K = toupper(dec(f[1])); k = f[2]
        if (!(K in T)) T[K] = 1
        if (k == "column") col[K, ++ncol[K]] = joinf(f, 3, n)
        else if (k == "index") idx[K, ++nidx[K]] = joinf(f, 3, n)
        else if (k == "row") {
            nrow[K]++; rline[K, nrow[K]] = dec(f[3])
            rhas[K, nrow[K]] = (n >= 4 && f[4] != "\\N")
            rcdc[K, nrow[K]] = n >= 4 ? dec(f[4]) : ""
        } else if (k == "minmax") {
            cu = toupper(dec(f[3]))
            if (!((K, cu) in mm)) { mmn[K]++; mmk[K, mmn[K]] = cu }
            mm[K, cu] = n >= 4 ? joinf(f, 4, n) : ""
        } else if (k == "lob_max") {
            cu = toupper(dec(f[3]))
            if (!((K, cu) in lob)) { lobn[K]++; lobk[K, lobn[K]] = cu }
            lob[K, cu] = val(f[4])
        } else if (k != "table") { sc[K, k] = val(f[3]); has[K, k] = 1 }
    }
    close(path)
}

function rec(r,   n) {
    n = length(r)
    if (tool == "bteq") printf "REC\t%s", u16(n + 2)
    else printf "REC\t"
    printf "%s%s\\012\n", u16(n), pfmt(r)
    nrec++
}
# uint16 in the fake's byte order (be=1: big-endian, as fexp/bteq write on AIX/Solaris SPARC)
function u16(n) {
    if (be) return sprintf("\\%03o\\%03o", int(n / 256) % 256, n % 256)
    return sprintf("\\%03o\\%03o", n % 256, int(n / 256) % 256)
}

function request(body, have, path, sql,   key, kind, ci, cn, i, w, K, c, lst, nl, m, cols, gt, le, v, q, j) {
    pmarker(body)
    if (mode == "events") {
        printf "path=%s", have ? penc(path) : ""
        for (m in M) printf "\t%s=%s", m, penc(M[m])
        printf "\n"
        return
    }
    key = toupper((("db" in M) ? M["db"] : "") "." (("table" in M) ? M["table"] : ""))
    kind = ("query" in M) ? M["query"] : ""
    ci = ""; cn = 1
    if (("chunk" in M) && M["chunk"] != "") {
        j = index(M["chunk"], "/")
        if (j) { ci = substr(M["chunk"], 1, j - 1) + 0; cn = substr(M["chunk"], j + 1); cn = cn == "" ? 1 : cn + 0 }
        else ci = M["chunk"] + 0
    }
    printf "REQ\t%s\n", pfmt(key)
    if ((v = sqlcheck(sql)) != "") { printf "SQLERR\t%s\n", pfmt(v); return }
    for (i = 1; i <= nfail; i++) {
        if (toupper(ftable[i]) != key) continue
        if (ftool[i] != "" && ftool[i] != tool) continue
        if (fquery[i] != "*" && fquery[i] != kind) continue
        if (fchunk[i] != "") {
            w = fchunk[i]; j = index(w, "/"); if (j) w = substr(w, 1, j - 1)
            if (ci == "" || ci != w + 0) continue
        }
        printf "FAIL\t%d\t%d\t%s\t%s\n", i - 1, ftimes[i], pfmt(fcode[i]), pfmt(fmsg[i])
    }
    K = ""
    if (key in T) K = key
    if (K == "") { print "MISSING"; return }
    known = "|columns|index|stats|count|minmax|lobcheck|rowcheck|cdcmax|export|"
    if (kind == "" || index(known, "|" kind "|") == 0) { printf "UNKNOWN\t%s\n", pfmt(kind); return }
    if (have) printf "OPEN\t%s\n", pfmt(path)
    nrec = 0
    if (kind == "columns") { for (i = 1; i <= ncol[K]; i++) rec(col[K, i]) }
    else if (kind == "index") { for (i = 1; i <= nidx[K]; i++) rec(idx[K, i]) }
    else if (kind == "stats") rec(escf(((K, "stats_rows") in sc) ? sc[K, "stats_rows"] : NULLV))
    else if (kind == "count") rec(escf(((K, "count") in has) ? sc[K, "count"] : nrow[K] + 0))
    else if (kind == "minmax") {
        c = ""
        if (M["col"] != "") c = M["col"]; else if (M["column"] != "") c = M["column"]; else if (M["chunk_column"] != "") c = M["chunk_column"]
        c = toupper(c)
        if (c == "") c = toupper(minre(sql))
        if (c == "" && mmn[K] == 1) c = mmk[K, 1]
        rec(((K, c) in mm) && mm[K, c] != "" ? mm[K, c] : "\\N|\\N")
    } else if (kind == "lobcheck") {
        nl = split(M["cols"], lst, ",")
        cols = 0
        for (i = 1; i <= nl; i++) { v = lst[i]; gsub(/^[ \t\n\r]+|[ \t\n\r]+$/, "", v); if (v != "") cl[++cols] = toupper(v) }
        if (!cols) for (i = 1; i <= lobn[K]; i++) cl[++cols] = lobk[K, i]
        v = ""
        for (i = 1; i <= cols; i++) { if (i > 1) v = v "|"; v = v escf(((K, cl[i]) in lob) ? lob[K, cl[i]] : NULLV) }
        rec(v)
    } else if (kind == "rowcheck") {
        if (((K, "row_max") in sc) && sc[K, "row_max"] != NULLV) rec(escf(sc[K, "row_max"]))
        else { m = 0; for (i = 1; i <= nrow[K]; i++) if ((w = u8len(rline[K, i])) > m) m = w; rec(m) }
    } else if (kind == "cdcmax") {
        v = ((K, "cdc_max") in sc) ? sc[K, "cdc_max"] : NULLV
        if (v != NULLV && ("cdc_gt" in M) && (v "") <= (M["cdc_gt"] "")) v = NULLV
        rec(escf(v))
    } else {
        for (i = 1; i <= nrow[K]; i++) {
            if (ci != "" && (i - 1) % cn != ci - 1) continue
            if (("cdc_gt" in M) || ("cdc_le" in M)) {
                if (!rhas[K, i]) continue
                q = rcdc[K, i] ""
                if (("cdc_gt" in M) && !(q > (M["cdc_gt"] ""))) continue
                if (("cdc_le" in M) && !(q <= (M["cdc_le"] ""))) continue
            }
            rec(rline[K, i])
        }
    }
    printf "END\t%d\n", nrec
}
# ---- SQL shape checks (not a parser): "" if fine, else "<code>\t<message>" ----
# Balanced parentheses; OREPLACE takes 2 or 3 arguments; an OREPLACE result is VARCHAR(8000)
# UNICODE, so it must be bounded (CAST, TRANSLATE, OREPLACE) or measured (CHARACTER_LENGTH)
# before anything else (e.g. ||) uses it. Strings, "identifiers" and comments are skipped.
function sqlcheck(t,   u, L, p, c, j, d, w, fn, na, top) {
    u = toupper(t); L = length(t); p = 1; d = 0; w = ""
    split("", fn); split("", na)
    while (p <= L) {
        c = substr(t, p, 1)
        if (c == "'" || c == "\"") {
            j = p + 1
            while (j <= L) {
                if (substr(t, j, 1) == c) { if (substr(t, j + 1, 1) == c) { j += 2; continue } break }
                j++
            }
            if (j > L) return "3760\tString not terminated before end of text"
            p = j + 1; w = ""; continue
        }
        if (c == "/" && substr(t, p + 1, 1) == "*") {
            j = index(substr(t, p + 2), "*/")
            if (!j) return "3706\tSyntax error: unterminated comment"
            p += j + 3; continue
        }
        if (isw(c)) {
            j = p; while (j <= L && isw(substr(t, j, 1))) j++
            w = substr(u, p, j - p); p = j; continue
        }
        if (c == "(") { d++; fn[d] = w; na[d] = 1 }
        else if (c == ",") { if (d > 0) na[d]++ }
        else if (c == ")") {
            if (d == 0) return "3706\tSyntax error: unbalanced ')'"
            if (fn[d] == "OREPLACE") {
                if (na[d] < 2 || na[d] > 3) return "3706\tSyntax error: OREPLACE takes 2 or 3 arguments, got " na[d]
                top = d > 1 ? fn[d - 1] : ""
                if (top != "CAST" && top != "TRANSLATE" && top != "OREPLACE" && top != "CHARACTER_LENGTH")
                    return "3798\tA column or character expression is larger than the max size (unbounded OREPLACE result)"
            }
            d--
        }
        if (!isws(c)) w = ""
        p++
    }
    if (d > 0) return "3706\tSyntax error: expected ')'"
    return ""
}

# first MIN(<word>) / MIN("<word>") in the SQL (case-insensitive)
function minre(t,   u, p, q, j, w) {
    u = toupper(t)
    while ((p = index(u, "MIN")) > 0) {
        q = skipws(u, p + 3)
        if (substr(u, q, 1) == "(") {
            q = skipws(u, q + 1)
            if (substr(u, q, 1) == "\"") q++
            j = q; while (isw(substr(u, j, 1))) j++
            if (j > q) {
                w = substr(t, q, j - q)
                if (substr(u, j, 1) == "\"") j++
                j = skipws(u, j)
                if (substr(u, j, 1) == ")") return w
            }
        }
        u = substr(u, p + 1); t = substr(t, p + 1)
    }
    return ""
}
