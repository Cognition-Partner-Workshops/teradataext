# Password masking shared by mask.awk and toolout.awk (run with LC_ALL=C).
# mask_init(secret) once, then mask_line(line) per line.
function mask_add(v) {
    if (v == "" || (v in mask_seen)) return
    mask_seen[v] = 1
    mask_v[++mask_n] = v
}
function mask_repl(s, a, b,    out, p) {
    out = ""
    while ((p = index(s, a)) > 0) {
        out = out substr(s, 1, p - 1) b
        s = substr(s, p + length(a))
    }
    return out s
}
function mask_pyrepr(s,    q, out, i, c) {
    q = (index(s, "'") && !index(s, "\"")) ? "\"" : "'"
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\n") out = out "\\n"
        else if (c == "\t") out = out "\\t"
        else if (c == "\r") out = out "\\r"
        else if (c == q) out = out "\\" c
        else out = out c
    }
    return out
}
function mask_init(secret,    n, frag, i, j, k, t) {
    MASK = "********"
    mask_n = 0
    if (secret == "") return
    mask_add(secret); mask_add(toupper(secret)); mask_add(tolower(secret))
    mask_add(mask_repl(secret, "'", "''")); mask_add(mask_repl(secret, "\"", "\"\""))
    mask_add(mask_pyrepr(secret))
    n = length(secret)
    frag = int((n + 1) / 2); if (frag < 4) frag = 4
    for (i = 1; i <= n; i++)
        for (j = i + frag - 1; j <= n; j++)
            mask_add(substr(secret, i, j - i + 1))
    for (i = 2; i <= mask_n; i++) {
        t = mask_v[i]
        for (k = i - 1; k >= 1 && length(mask_v[k]) < length(t); k--) mask_v[k + 1] = mask_v[k]
        mask_v[k + 1] = t
    }
    for (i = 1; i <= mask_n; i++) mask_lv[i] = tolower(mask_v[i])
}
function mask_is_space(c) { return c == " " || c == "\t" || c == "\r" || c == "\f" || c == "\v" }
function mask_logon(line,    out, rest, p, q, k, L) {
    out = ""
    rest = line
    while ((p = index(tolower(rest), ".logon")) > 0) {
        q = p + 6
        L = length(rest)
        k = q
        while (k <= L && mask_is_space(substr(rest, k, 1))) k++
        if (k == q) { out = out substr(rest, 1, q - 1); rest = substr(rest, q); continue }
        while (k <= L && index(", \t\r\f\v;", substr(rest, k, 1)) == 0) k++
        return out substr(rest, 1, k - 1) "," MASK
    }
    return out rest
}
function mask_line(line,    i, s, ls, out, p, L) {
    line = mask_logon(line)
    for (i = 1; i <= mask_n; i++) {
        L = length(mask_lv[i])
        s = line; ls = tolower(line); out = ""
        while ((p = index(ls, mask_lv[i])) > 0) {
            out = out substr(s, 1, p - 1) MASK
            s = substr(s, p + L); ls = substr(ls, p + L)
        }
        line = out s
    }
    return line
}
