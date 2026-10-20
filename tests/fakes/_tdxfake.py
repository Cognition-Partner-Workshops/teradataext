"""Shared implementation of the fake ``fexp`` / ``bteq`` binaries (stdlib only).

See tests/fakes/README.md for the fixture schema and behaviour.
"""
import fcntl
import json
import os
import re
import struct
import sys
import time

EXIT_CODES = {"fexp": 12, "bteq": 8}

LOGON_RE = re.compile(r"^\s*\.LOGON\s+[^/\s;]+/[^,\s;]+,\S.*$", re.IGNORECASE | re.MULTILINE)
_PATH = r"(?:\"(?P<{0}q>[^\"]+)\"|'(?P<{0}s>[^']+)'|(?P<{0}p>[^\s;]+))"
EVENT_RE = re.compile(
    r"(?P<marker>/\*\s*TDX\s+(?P<body>.*?)\*/)"
    r"|(?P<outfile>\.EXPORT\s+OUTFILE\s+" + _PATH.format("o") + r")"
    r"|(?P<datafile>\.EXPORT\s+(?:(?:DATA|INDICDATA|REPORT)\s+)?FILE\s*=\s*" + _PATH.format("d") + r")"
    r"|(?P<reset>\.EXPORT\s+RESET)",
    re.IGNORECASE | re.DOTALL,
)
KV_RE = re.compile(r"(\w+)\s*=\s*(?:\"([^\"]*)\"|(\S+))")
MIN_RE = re.compile(r"MIN\s*\(\s*\"?(\w+)\"?\s*\)", re.IGNORECASE)


class FakeFailure(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def parse_marker(body):
    return {m.group(1).lower(): (m.group(2) if m.group(3) is None else m.group(3)) for m in KV_RE.finditer(body)}


def escape_field(value):
    if value is None:
        return "\\N"
    s = str(value)
    return s.replace("\\", "\\\\").replace("|", "\\|").replace("\r", "\\\r").replace("\n", "\\\n")


def join_fields(values):
    return "|".join(escape_field(v) for v in values)


def encode_records(records, tool):
    out = bytearray()
    for rec in records:
        payload = rec.encode("utf-8")
        if tool == "bteq":
            out += struct.pack("<HH", len(payload) + 2, len(payload))
        else:
            out += struct.pack("<H", len(payload))
        out += payload + b"\n"
    return bytes(out)


def parse_events(script):
    """Return the marked requests in order: {"marker": dict, "path": str|None, "sql": str}."""
    requests = []
    current = None
    for m in EVENT_RE.finditer(script):
        if m.group("outfile"):
            current = m.group("oq") or m.group("os") or m.group("op")
        elif m.group("datafile"):
            current = m.group("dq") or m.group("ds") or m.group("dp")
        elif m.group("reset"):
            current = None
        else:
            end = script.find(";", m.end())
            sql = script[m.end(): end if end >= 0 else len(script)]
            requests.append({"marker": parse_marker(m.group("body")), "path": current, "sql": sql})
    return requests


def _chunk_index(marker):
    chunk = marker.get("chunk")
    if not chunk:
        return None
    i, _, n = chunk.partition("/")
    return int(i), int(n or 1)


def _table_lookup(fixture, key):
    for name, spec in (fixture.get("tables") or {}).items():
        if name.upper() == key:
            return spec
    return None


class _State:
    """Failure counters persisted next to the fixture (``<fixture>.state``)."""

    def __init__(self, fixture_path):
        self.path = fixture_path + ".state"

    def consume(self, idx, times):
        lock_path = self.path + ".lock"
        with open(lock_path, "a+") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            try:
                with open(self.path, encoding="utf-8") as fh:
                    state = json.load(fh)
            except (OSError, ValueError):
                state = {}
            used = int(state.get(str(idx), 0))
            if times is not None and times >= 0 and used >= times:
                return False
            state[str(idx)] = used + 1
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(state, fh)
            os.replace(tmp, self.path)
            return True


def _check_failure(fixture, state, tool, key, marker):
    query = marker.get("query", "")
    chunk = _chunk_index(marker)
    for idx, f in enumerate(fixture.get("failures") or []):
        if str(f.get("table", "")).upper() != key:
            continue
        if f.get("tool") and f["tool"] != tool:
            continue
        if f.get("query", "export") not in ("*", query):
            continue
        want_chunk = f.get("chunk")
        if want_chunk is not None:
            want_i = int(str(want_chunk).partition("/")[0])
            if chunk is None or chunk[0] != want_i:
                continue
        if state.consume(idx, f.get("times", 1)):
            raise FakeFailure(int(f.get("code", 2633)), f.get("message", "Too many load/unload tasks running now"))


def _cdc_ok(cdc, marker):
    gt, le = marker.get("cdc_gt"), marker.get("cdc_le")
    if gt is None and le is None:
        return True
    if cdc is None:
        return False
    if gt is not None and not cdc > gt:
        return False
    if le is not None and not cdc <= le:
        return False
    return True


def answer(spec, req):
    marker = req["marker"]
    kind = marker.get("query", "")
    rows = spec.get("rows") or []
    if kind == "columns":
        return [join_fields(c) for c in spec.get("columns") or []]
    if kind == "index":
        return [join_fields(i) for i in spec.get("indexes") or []]
    if kind == "stats":
        return [join_fields([spec.get("stats_rows")])]
    if kind == "count":
        return [join_fields([spec.get("count", len(rows))])]
    if kind == "minmax":
        mm = {k.upper(): v for k, v in (spec.get("minmax") or {}).items()}
        col = (marker.get("col") or marker.get("column") or marker.get("chunk_column") or "").upper()
        if not col:
            m = MIN_RE.search(req["sql"])
            col = m.group(1).upper() if m else ""
        if not col and len(mm) == 1:
            col = next(iter(mm))
        entry = mm.get(col)
        return [join_fields(entry if entry else [None, None])]
    if kind == "lobcheck":
        lob = {k.upper(): v for k, v in (spec.get("lob_max") or {}).items()}
        cols = [c.strip().upper() for c in marker.get("cols", "").split(",") if c.strip()] or list(lob)
        return [join_fields([lob.get(c) for c in cols])]
    if kind == "rowcheck":
        row_max = spec.get("row_max")
        if row_max is None:
            row_max = max((len(r["line"]) for r in rows), default=0)
        return [join_fields([row_max])]
    if kind == "cdcmax":
        cdc_max = spec.get("cdc_max")
        gt = marker.get("cdc_gt")
        if cdc_max is not None and gt is not None and cdc_max <= gt:
            cdc_max = None
        return [join_fields([cdc_max])]
    if kind == "export":
        chunk = _chunk_index(marker)
        out = []
        for idx, row in enumerate(rows):
            if chunk is not None and idx % chunk[1] != chunk[0] - 1:
                continue
            if not _cdc_ok(row.get("cdc"), marker):
                continue
            out.append(row["line"])
        return out
    raise FakeFailure(3706, "Syntax error: unknown TDX query kind '%s'" % kind)


def _log(tool, script):
    log_path = os.environ.get("TDX_FAKE_LOG")
    if not log_path:
        return
    entry = {"tool": tool, "pid": os.getpid(), "time": time.time(), "argv": sys.argv[1:], "script": script}
    with open(log_path, "a", encoding="utf-8") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        fh.write(json.dumps(entry) + "\n")


def _report(tool, n):
    if tool == "fexp":
        print("**** 12:00:00 UTY8722 %d total records written to output file." % n)
    elif n:
        print("*** Query completed. %d rows found. 1 column returned." % n)
    else:
        print("*** Query completed. No rows found.")


def main(tool):
    exit_fail = EXIT_CODES[tool]
    raw = sys.stdin.buffer.read()
    script = raw.decode("utf-8", errors="replace")
    _log(tool, script)
    banner = "FastExport Utility (fake)" if tool == "fexp" else "BTEQ (fake)"
    print("     %s  Release 16.20.00.00" % banner)
    if not LOGON_RE.search(script):
        print("*** Error: no .LOGON host/user,password command found in script.")
        return 12
    print("*** Logon successfully completed.")
    fixture_path = os.environ.get("TDX_FAKE_FIXTURE")
    if not fixture_path:
        print("*** Error: TDX_FAKE_FIXTURE is not set.")
        return exit_fail
    with open(fixture_path, encoding="utf-8") as fh:
        fixture = json.load(fh)
    state = _State(fixture_path)
    written = set()
    try:
        for req in parse_events(script):
            marker = req["marker"]
            key = ("%s.%s" % (marker.get("db", ""), marker.get("table", ""))).upper()
            _check_failure(fixture, state, tool, key, marker)
            spec = _table_lookup(fixture, key)
            if spec is None:
                raise FakeFailure(3807, "Object '%s' does not exist" % key)
            records = answer(spec, req)
            if req["path"]:
                mode = "ab" if req["path"] in written else "wb"
                with open(req["path"], mode) as fh:
                    fh.write(encode_records(records, tool))
                written.add(req["path"])
            _report(tool, len(records))
    except FakeFailure as exc:
        print("*** Failure %d %s." % (exc.code, exc.message))
        sys.stdout.flush()
        return exit_fail
    print("*** Logoff completed.")
    return 0
