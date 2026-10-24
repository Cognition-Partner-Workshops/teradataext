# process_state.ini store. Reads the state file (last argument) and either answers a query
# (mode=get|section|sections) or applies the operations in the ops file (mode=apply, first
# argument; one op per line, fields separated by \037) and prints the new file.
# Ops: set S K V | del S K | rmsec S | rmchunks KEY | reset KEY CLEARWM | ensure S |
#      pending_all | addchunk KEY N | resetall
BEGIN { US = "\037"; ns = 0; cur = 0; nops = 0; sec = ENVIRON["TDX_SEC"]; key = ENVIRON["TDX_KEY"] }
function strip(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function addsec(name) { ns++; sn[ns] = name; sd[ns] = 0; sp[name] = ns; kc[ns] = 0; return ns }
function secidx(name, create) {
    if ((name in sp) && sp[name] > 0) return sp[name]
    return create ? addsec(name) : 0
}
function setk(s, k, v,    i) {
    if (((s, k) in kp) && kp[s, k] > 0) { kv[s, kp[s, k]] = v; return }
    i = ++kc[s]; kn[s, i] = k; kv[s, i] = v; kd[s, i] = 0; kp[s, k] = i
}
function getk(s, k) { return (s && ((s, k) in kp) && kp[s, k] > 0) ? kv[s, kp[s, k]] : "" }
function hask(s, k) { return s && ((s, k) in kp) && kp[s, k] > 0 }
function delk(s, k) { if (hask(s, k)) { kd[s, kp[s, k]] = 1; kp[s, k] = 0 } }
function rmsec(name,    s) { s = secidx(name, 0); if (s) { sd[s] = 1; sp[name] = 0 } }
function rmchunks(key,    i, pre) {
    pre = key "/part"
    for (i = 1; i <= ns; i++) if (!sd[i] && index(sn[i], pre) == 1) rmsec(sn[i])
}
function reset(key, clearwm,    s, wm, haswm) {
    s = secidx(key, 0); haswm = 0
    if (s) { wm = getk(s, "watermark"); if (!clearwm && wm != "") haswm = 1; rmsec(key) }
    rmchunks(key)
    s = addsec(key)
    setk(s, "status", "pending")
    if (haswm) setk(s, "watermark", wm)
}
function addchunk(key, n,    s, cur, m, a, i, j, t, seen, out, sep) {
    s = secidx(key, 1)
    cur = getk(s, "chunks_done")
    m = split(cur, a, ",")
    j = 0; split("", seen)
    for (i = 1; i <= m; i++) if (a[i] != "" && !((a[i] + 0) in seen)) { seen[a[i] + 0] = 1; b[++j] = a[i] + 0 }
    if (!((n + 0) in seen)) b[++j] = n + 0
    for (i = 2; i <= j; i++) { t = b[i]; for (m = i - 1; m >= 1 && b[m] > t; m--) b[m + 1] = b[m]; b[m + 1] = t }
    out = ""
    for (i = 1; i <= j; i++) { out = out sep b[i]; sep = "," }
    setk(s, "chunks_done", out)
}
function istable(name) { return name != "_run" && index(name, "/part") == 0 }
mode == "apply" && FILENAME == ARGV[1] { ops[++nops] = $0; next }
{
    line = $0; sub(/\r$/, "", line); t = strip(line)
    if (t == "" || substr(t, 1, 1) == "#" || substr(t, 1, 1) == ";") next
    if (substr(t, 1, 1) == "[" && substr(t, length(t), 1) == "]") { cur = secidx(substr(t, 2, length(t) - 2), 1); next }
    if (!cur) next
    p = index(t, "="); if (!p) next
    setk(cur, strip(substr(t, 1, p - 1)), strip(substr(t, p + 1)))
}
END {
    if (mode == "get") { print getk(secidx(sec, 0), key); exit 0 }
    if (mode == "section") {
        s = secidx(sec, 0)
        if (s) for (i = 1; i <= kc[s]; i++) if (!kd[s, i]) print kn[s, i] US kv[s, i]
        exit 0
    }
    if (mode == "sections") { for (i = 1; i <= ns; i++) if (!sd[i]) print sn[i]; exit 0 }
    for (o = 1; o <= nops; o++) {
        n = split(ops[o], f, US)
        op = f[1]
        if (op == "set") { v = f[4]; for (q = 5; q <= n; q++) v = v US f[q]; setk(secidx(f[2], 1), f[3], v) }
        else if (op == "del") delk(secidx(f[2], 0), f[3])
        else if (op == "rmsec") rmsec(f[2])
        else if (op == "rmchunks") rmchunks(f[2])
        else if (op == "reset") reset(f[2], f[3] + 0)
        else if (op == "ensure") secidx(f[2], 1)
        else if (op == "addchunk") addchunk(f[2], f[3])
        else if (op == "pending_all") {
            for (i = 1; i <= ns; i++) if (!sd[i] && getk(i, "status") == "in_progress") setk(i, "status", "pending")
        } else if (op == "resetall") {
            m = 0
            for (i = 1; i <= ns; i++) if (!sd[i] && istable(sn[i])) tk[++m] = sn[i]
            for (i = 1; i <= m; i++) { reset(tk[i], 0); delk(secidx(tk[i], 0), "pending_watermark") }
        }
    }
    print "# THIS FILE IS MANAGED BY teradata_extract - DO NOT EDIT."
    print "# Use --reset-table / --reset-watermark / --new-cycle to change extraction state."
    print ""
    for (i = 1; i <= ns; i++) {
        if (sd[i]) continue
        print "[" sn[i] "]"
        for (j = 1; j <= kc[i]; j++) if (!kd[i, j]) print kn[i, j] " = " kv[i, j]
        print ""
    }
}
