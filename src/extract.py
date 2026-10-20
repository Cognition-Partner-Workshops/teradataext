#!/usr/bin/env python3
"""Teradata 16.20 table extraction utility (FastExport for data, BTEQ for metadata).

Standard library only. See docs/DESIGN.md for the interface contract and
config/utility_user_guide.txt for operator documentation.
"""

from __future__ import annotations

import argparse
import configparser
import contextlib
import datetime as dt
import fcntl
import hashlib
import logging
import math
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor, wait
from dataclasses import dataclass, field
from pathlib import Path

LOG = logging.getLogger("teradata_extract")

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_CONFIG = 2
EXIT_INTERRUPTED = 130

STATE_HEADER = (
    "# THIS FILE IS MANAGED BY teradata_extract - DO NOT EDIT.\n"
    "# Use --reset-table / --reset-watermark / --new-cycle to change extraction state.\n"
)
MASK = "********"
MARKER_RE = re.compile(r"/\*\s*TDX\s+(.*?)\s*\*/", re.S)

INT_TYPES = {"I1": "SMALLINT", "I2": "SMALLINT", "I": "INTEGER", "I8": "BIGINT"}
INTERVAL_TYPES = {
    "YR", "YM", "MO", "DY", "DH", "DM", "DS", "HR", "HM", "HS", "MI", "MS", "SC",
}
PERIOD_TYPES = {"PD", "PT", "PZ", "PS", "PM"}
TEXT_TYPES = {"CF", "CV"}
LOB_TEXT_TYPES = {"CO", "JN", "XM"}
BINARY_TYPES = {"BF", "BV"}
LOB_TYPES = LOB_TEXT_TYPES | {"BO"}
CHUNKABLE_TYPES = {"I1", "I2", "I", "I8", "D", "N", "DA"}
CDC_TYPES = {"I1", "I2", "I", "I8", "D", "N", "DA", "TS", "SZ"}
TYPE_NAMES = {
    "I1": "BYTEINT", "I2": "SMALLINT", "I": "INTEGER", "I8": "BIGINT",
    "D": "DECIMAL", "N": "NUMBER", "F": "FLOAT", "DA": "DATE", "AT": "TIME",
    "TZ": "TIME WITH TIME ZONE", "TS": "TIMESTAMP", "SZ": "TIMESTAMP WITH TIME ZONE",
    "CF": "CHAR", "CV": "VARCHAR", "CO": "CLOB", "BF": "BYTE", "BV": "VARBYTE",
    "BO": "BLOB", "JN": "JSON", "XM": "XML", "YR": "INTERVAL YEAR",
    "YM": "INTERVAL YEAR TO MONTH", "MO": "INTERVAL MONTH", "DY": "INTERVAL DAY",
    "DH": "INTERVAL DAY TO HOUR", "DM": "INTERVAL DAY TO MINUTE",
    "DS": "INTERVAL DAY TO SECOND", "HR": "INTERVAL HOUR",
    "HM": "INTERVAL HOUR TO MINUTE", "HS": "INTERVAL HOUR TO SECOND",
    "MI": "INTERVAL MINUTE", "MS": "INTERVAL MINUTE TO SECOND",
    "SC": "INTERVAL SECOND", "PD": "PERIOD(DATE)", "PT": "PERIOD(TIME)",
    "PZ": "PERIOD(TIME WITH TIME ZONE)", "PS": "PERIOD(TIMESTAMP)",
    "PM": "PERIOD(TIMESTAMP WITH TIME ZONE)",
}
CHARSET_NAMES = {1: "LATIN", 2: "UNICODE", 3: "KANJISJIS", 4: "GRAPHIC", 5: "KANJI1"}


class ExtractError(Exception):
    """Fatal error for one table (the table is marked failed)."""


class ConfigError(Exception):
    """Configuration / environment error (exit code 2)."""


class ToolError(Exception):
    """A fexp/bteq invocation failed."""

    def __init__(self, message: str, session_limit: bool = False) -> None:
        super().__init__(message)
        self.session_limit = session_limit


# --------------------------------------------------------------------------- utils


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso(ts: dt.datetime) -> str:
    return ts.strftime("%Y-%m-%dT%H:%M:%SZ")


def safe_name(db: str, table: str) -> str:
    return re.sub(r"[^A-Za-z0-9_]", "_", f"{db}_{table}").lower()


def sql_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def sql_str(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def split_fields(line: str, delimiter: str = "|", escape: str = "\\") -> list[str]:
    """Split an escaped delimited record; returns raw (still escaped) field strings."""
    fields: list[str] = []
    buf: list[str] = []
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == escape and i + 1 < len(line):
            buf.append(line[i : i + 2])
            i += 2
            continue
        if ch == delimiter:
            fields.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
        i += 1
    fields.append("".join(buf))
    return fields


def decode_field(raw: str, null: str = "\\N", empty: str = "\\E") -> str | None:
    if raw == null:
        return None
    if empty and raw == empty:
        return ""
    out: list[str] = []
    i = 0
    while i < len(raw):
        if raw[i] == "\\" and i + 1 < len(raw):
            out.append(raw[i + 1])
            i += 2
        else:
            out.append(raw[i])
            i += 1
    return "".join(out)


def parse_marker(sql: str) -> dict[str, str]:
    m = MARKER_RE.search(sql)
    if not m:
        return {}
    return {
        k: v.strip('"')
        for k, v in re.findall(r'(\w+)=("[^"]*"|\S+)', m.group(1))
    }


_LOGON_RE = re.compile(r"(?im)(\.logon\s+[^,\s;]*)[^\n]*")


def mask_text(text: str, secret: str) -> str:
    """Mask the password (and common transformed forms) plus anything after the user on .LOGON lines."""
    text = _LOGON_RE.sub(lambda m: m.group(1) + "," + MASK, text)
    if not secret:
        return text
    variants = {secret, secret.upper(), secret.lower(), secret.replace("'", "''"), secret.replace('"', '""'),
                repr(secret)[1:-1]}
    for v in sorted(variants, key=len, reverse=True):
        if v:
            text = re.sub(re.escape(v), MASK, text, flags=re.I)
    return text


def count_records(data: bytes, escape: int = 0x5C) -> int:
    """Count LF-terminated records, ignoring LFs escaped by an odd run of backslashes."""
    count = 0
    run = 0
    for b in data:
        if b == 0x0A and run % 2 == 0:
            count += 1
        run = run + 1 if b == escape else 0
    return count


# Raw export layouts: (has record-length prefix, has 0x0A end-of-record byte)
LAYOUTS: tuple[tuple[bool, bool], ...] = (
    (False, True),
    (True, True),
    (True, False),
    (False, False),
)


def _parse_layout(data: bytes, rec_prefix: bool, eor: bool) -> list[bytes] | None:
    out: list[bytes] = []
    pos = 0
    n = len(data)
    while pos < n:
        if rec_prefix:
            if pos + 2 > n:
                return None
            rec_len = int.from_bytes(data[pos : pos + 2], "little")
            pos += 2
        if pos + 2 > n:
            return None
        vlen = int.from_bytes(data[pos : pos + 2], "little")
        pos += 2
        if rec_prefix and rec_len != vlen + 2:
            return None
        if pos + vlen > n:
            return None
        out.append(data[pos : pos + vlen])
        pos += vlen
        if eor:
            if pos >= n or data[pos] != 0x0A:
                return None
            pos += 1
    return out


def parse_raw_export(data: bytes, tool: str = "bteq") -> tuple[list[bytes], str]:
    """Decode a FastExport TEXT / BTEQ DATA export of one VARCHAR column.

    The tool's documented layout is tried first; the others are fallbacks.
    """
    if not data:
        return [], "empty"
    preferred = (True, True) if tool == "bteq" else (False, True)
    for rec_prefix, eor in (preferred, *(x for x in LAYOUTS if x != preferred)):
        records = _parse_layout(data, rec_prefix, eor)
        if records is not None:
            name = ("reclen+" if rec_prefix else "") + "varchar" + ("+eor" if eor else "")
            return records, name
    raise ExtractError("raw export file does not match any known record layout")


def field_count(record: bytes, delimiter: bytes, escape: bytes = b"\\") -> int:
    return re.sub(re.escape(escape) + b".", b"", record, flags=re.S).count(delimiter) + 1


def _stream_layout(fh, rec_prefix: bool, eor: bool, sink) -> int | None:
    """Read records of one layout from fh, handing each payload to sink; None if the layout does not fit."""
    n = 0
    while True:
        head = fh.read(4 if rec_prefix else 2)
        if not head:
            return n
        if len(head) < (4 if rec_prefix else 2):
            return None
        vlen = int.from_bytes(head[-2:], "little")
        if rec_prefix and int.from_bytes(head[:2], "little") != vlen + 2:
            return None
        payload = fh.read(vlen)
        if len(payload) < vlen:
            return None
        if eor and fh.read(1) != b"\n":
            return None
        sink(payload)
        n += 1


def stream_raw_export(raw: Path, out, tool: str, sink, reset) -> tuple[int, str]:
    """Streaming parse_raw_export: memory stays bounded by one record.

    out is the (binary, seekable) file the sink writes to; it is truncated and reset() is called before
    each layout attempt.
    """
    if not raw.exists() or raw.stat().st_size == 0:
        return 0, "empty"
    preferred = (True, True) if tool == "bteq" else (False, True)
    with raw.open("rb", buffering=1 << 20) as fh:
        for rec_prefix, eor in (preferred, *(x for x in LAYOUTS if x != preferred)):
            fh.seek(0)
            out.seek(0)
            out.truncate()
            reset()
            n = _stream_layout(fh, rec_prefix, eor, sink)
            if n is not None:
                return n, ("reclen+" if rec_prefix else "") + "varchar" + ("+eor" if eor else "")
    raise ExtractError("raw export file does not match any known record layout")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise
    with contextlib.suppress(OSError):
        dfd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)


def ini_text(cp: configparser.ConfigParser, header: str = "") -> str:
    import io

    buf = io.StringIO()
    cp.write(buf)
    return header + buf.getvalue()


def new_parser() -> configparser.ConfigParser:
    cp = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=None)
    cp.optionxform = str  # type: ignore[assignment,method-assign]
    return cp


def fmt_elapsed(seconds: float) -> str:
    s = int(round(seconds))
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


# ------------------------------------------------------------------------ settings


@dataclass
class Settings:
    config_path: Path
    root: Path
    host: str
    port: int
    logmech: str
    credentials_file: str
    fexp_path: str
    bteq_path: str
    session_charset: str
    logtable_database: str
    connect_check: bool
    output_dir: Path
    metadata_dir: Path
    log_dir: Path
    work_dir: Path
    source_tables_file: Path
    process_state_file: Path
    parallel: int
    max_sessions: int
    min_sessions: int
    chunk_threshold_rows: int
    chunk_rows: int
    max_chunks: int
    small_table_rows: int
    row_estimate: str
    char_trim: str
    lob_max_length: int
    max_row_length: int
    zip_on_complete: bool
    keep_raw_after_zip: bool
    retry_attempts: int
    retry_delay_seconds: float
    session_limit_errors: set[int]
    session_limit_patterns: list[str]
    bteq_fallback: bool
    job_timeout_seconds: float
    delimiter: str
    null_sentinel: str
    empty_sentinel: str
    escape_char: str
    big_decimal_quote: str
    big_decimal_threshold: int

    @property
    def lock_file(self) -> Path:
        return self.work_dir / ".process_state.lock"

    @property
    def audit_file(self) -> Path:
        return self.metadata_dir / "audit.log"


def _get(cp: configparser.ConfigParser, sec: str, key: str, default: str) -> str:
    if cp.has_option(sec, key):
        return cp.get(sec, key).strip()
    return default


def _int(cp: configparser.ConfigParser, sec: str, key: str, default: int) -> int:
    raw = _get(cp, sec, key, str(default))
    try:
        return int(raw)
    except ValueError as exc:
        raise ConfigError(f"[{sec}] {key} must be an integer, got {raw!r}") from exc


def _bool(cp: configparser.ConfigParser, sec: str, key: str, default: bool) -> bool:
    raw = _get(cp, sec, key, "true" if default else "false").lower()
    if raw in {"1", "true", "yes", "on"}:
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    raise ConfigError(f"[{sec}] {key} must be true/false, got {raw!r}")


def resolve_parallel(raw: str, max_sessions: int) -> int:
    raw = raw.strip().lower()
    if raw in {"", "auto"}:
        value = 0
    else:
        try:
            value = int(raw)
        except ValueError as exc:
            raise ConfigError(f"parallel must be an integer or 'auto', got {raw!r}") from exc
    if value <= 0:
        value = min(os.cpu_count() or 1, max_sessions)
    return max(1, value)


def load_settings(config_path: Path, parallel_override: str | None = None) -> Settings:
    if not config_path.is_file():
        raise ConfigError(f"config file not found: {config_path}")
    cp = new_parser()
    try:
        cp.read(config_path, encoding="utf-8")
    except configparser.Error as exc:
        raise ConfigError(f"cannot parse {config_path}: {exc}") from exc
    for sec in ("teradata", "extract"):
        if not cp.has_section(sec):
            raise ConfigError(f"{config_path}: missing [{sec}] section")
    base = _get(cp, "paths", "base_dir", "")
    root = Path(base).expanduser() if base else config_path.resolve().parent.parent
    if not root.is_absolute():
        root = (config_path.resolve().parent.parent / root).resolve()

    def path(key: str, default: str) -> Path:
        p = Path(_get(cp, "paths", key, default) or default).expanduser()
        return p if p.is_absolute() else root / p

    host = _get(cp, "teradata", "host", "")
    if not host:
        raise ConfigError("[teradata] host is required")
    fmt = _get(cp, "extract", "file_format", "pipe-delimited").lower()
    if fmt != "pipe-delimited":
        raise ConfigError(f"[extract] file_format {fmt!r} not supported (pipe-delimited only)")
    charset = _get(cp, "teradata", "session_charset", "ASCII").upper().replace("-", "")
    if charset not in {"ASCII", "UTF8"}:
        raise ConfigError("[teradata] session_charset must be ASCII or UTF8")
    max_sessions = _int(cp, "extract", "max_sessions", 4)
    min_sessions = _int(cp, "extract", "min_sessions", 1)
    if max_sessions < 1 or not 1 <= min_sessions <= max_sessions:
        raise ConfigError("[extract] need 1 <= min_sessions <= max_sessions")
    char_trim = _get(cp, "extract", "char_trim", "right").lower()
    if char_trim not in {"right", "both", "none"}:
        raise ConfigError("[extract] char_trim must be right, both or none")
    row_estimate = _get(cp, "extract", "row_estimate", "stats").lower()
    if row_estimate not in {"stats", "count"}:
        raise ConfigError("[extract] row_estimate must be stats or count")
    delimiter = _get(cp, "format", "delimiter", "|")
    escape_char = _get(cp, "format", "escape_char", "\\")
    if len(delimiter) != 1 or len(escape_char) != 1 or delimiter == escape_char:
        raise ConfigError("[format] delimiter and escape_char must be distinct single characters")
    null_sentinel = _get(cp, "format", "null_sentinel", "\\N")
    empty_sentinel = _get(cp, "format", "empty_sentinel", "\\E")
    if not null_sentinel or null_sentinel == empty_sentinel:
        raise ConfigError("[format] null_sentinel must be non-empty and differ from empty_sentinel")
    errors = {
        int(x) for x in re.split(r"[,\s]+", _get(cp, "extract", "session_limit_errors", "2633,3130")) if x
    }
    patterns = [
        p.strip().lower()
        for p in _get(cp, "extract", "session_limit_patterns", "").split(",")
        if p.strip()
    ]
    parallel_raw = parallel_override if parallel_override is not None else _get(cp, "extract", "parallel", "1")
    s = Settings(
        config_path=config_path.resolve(),
        root=root,
        host=host,
        port=_int(cp, "teradata", "port", 1025),
        logmech=_get(cp, "teradata", "logmech", ""),
        credentials_file=_get(cp, "teradata", "credentials_file", ""),
        fexp_path=os.environ.get("TDX_FEXP") or _get(cp, "teradata", "fexp_path", "fexp"),
        bteq_path=os.environ.get("TDX_BTEQ") or _get(cp, "teradata", "bteq_path", "bteq"),
        session_charset=charset,
        logtable_database=_get(cp, "teradata", "logtable_database", ""),
        connect_check=_bool(cp, "teradata", "connect_check", True),
        output_dir=path("output_dir", "data"),
        metadata_dir=path("metadata_dir", "metadata"),
        log_dir=path("log_dir", "logs"),
        work_dir=path("work_dir", "work"),
        source_tables_file=path("source_tables_file", "config/source_tables.ini"),
        process_state_file=path("process_state_file", "config/process_state.ini"),
        parallel=resolve_parallel(parallel_raw, max_sessions),
        max_sessions=max_sessions,
        min_sessions=min_sessions,
        chunk_threshold_rows=_int(cp, "extract", "chunk_threshold_rows", 10_000_000),
        chunk_rows=max(1, _int(cp, "extract", "chunk_rows", 5_000_000)),
        max_chunks=max(2, _int(cp, "extract", "max_chunks", 64)),
        small_table_rows=_int(cp, "extract", "small_table_rows", 100_000),
        row_estimate=row_estimate,
        char_trim=char_trim,
        lob_max_length=_int(cp, "extract", "lob_max_length", 32000),
        max_row_length=_int(cp, "extract", "max_row_length", 64000),
        zip_on_complete=_bool(cp, "extract", "zip_on_complete", True),
        keep_raw_after_zip=_bool(cp, "extract", "keep_raw_after_zip", False),
        retry_attempts=max(0, _int(cp, "extract", "retry_attempts", 3)),
        retry_delay_seconds=float(_get(cp, "extract", "retry_delay_seconds", "60") or 0),
        session_limit_errors=errors,
        session_limit_patterns=patterns,
        bteq_fallback=_bool(cp, "extract", "bteq_fallback", True),
        job_timeout_seconds=float(_get(cp, "extract", "job_timeout_seconds", "0") or 0),
        delimiter=delimiter,
        null_sentinel=null_sentinel,
        empty_sentinel=empty_sentinel,
        escape_char=escape_char,
        big_decimal_quote=_get(cp, "format", "big_decimal_quote", '"'),
        big_decimal_threshold=_int(cp, "format", "big_decimal_threshold", 18),
    )
    if s.lob_max_length < 1 or s.max_row_length < 1:
        raise ConfigError("[extract] lob_max_length and max_row_length must be positive")
    return s


@dataclass
class SourceTable:
    label: str
    database: str
    table: str
    cdc_column: str = ""
    chunk_column: str = ""
    where: str = ""

    @property
    def key(self) -> str:
        return f"{self.database}.{self.table}".upper()

    @property
    def base(self) -> str:
        return safe_name(self.database, self.table)

    @property
    def fqn(self) -> str:
        return f"{sql_ident(self.database)}.{sql_ident(self.table)}"


def check_where(where: str) -> str | None:
    """Reject statement separators and comments outside string literals in a [table] where filter."""
    outside = re.sub(r"'(?:[^']|'')*'", " ", where)
    if "'" in outside:
        return "unbalanced quote"
    for tok in (";", "--", "/*", "*/"):
        if tok in outside:
            return f"'{tok}' is not allowed"
    return None


def load_source_tables(path: Path) -> list[SourceTable]:
    if not path.is_file():
        raise ConfigError(f"source tables file not found: {path}")
    cp = new_parser()
    try:
        cp.read(path, encoding="utf-8")
    except configparser.Error as exc:
        raise ConfigError(f"cannot parse {path}: {exc}") from exc
    tables: list[SourceTable] = []
    seen: set[str] = set()
    for label in cp.sections():
        sec = cp[label]
        db = sec.get("database", "").strip()
        tb = sec.get("table", "").strip()
        if not db or not tb:
            raise ConfigError(f"{path} [{label}]: database and table are required")
        if not _bool(cp, label, "enabled", True):
            continue
        t = SourceTable(
            label=label,
            database=db,
            table=tb,
            cdc_column=sec.get("cdc_column", "").strip(),
            chunk_column=sec.get("chunk_column", "").strip(),
            where=sec.get("where", "").strip(),
        )
        if t.where and (why := check_where(t.where)):
            raise ConfigError(f"{path} [{label}]: where: {why} (one boolean condition only)")
        if t.key in seen:
            raise ConfigError(f"{path}: table {t.key} defined twice")
        seen.add(t.key)
        tables.append(t)
    return tables


# --------------------------------------------------------------------- credentials


@dataclass
class Credentials:
    user: str
    password: str = field(repr=False)
    source: str = ""


def load_credentials(settings: Settings) -> Credentials:
    user = os.environ.get("TD_USER", "")
    password = os.environ.get("TD_PASS", "")
    if user and password:
        return Credentials(user, password, "environment (TD_USER/TD_PASS)")
    if user or password:
        raise ConfigError("only one of TD_USER / TD_PASS is set; set both or neither")
    if not settings.credentials_file:
        raise ConfigError(
            "no credentials: set TD_USER and TD_PASS, or [teradata] credentials_file "
            "pointing to a chmod 0600 file"
        )
    cred_path = Path(settings.credentials_file).expanduser()
    if not cred_path.is_absolute():
        cred_path = settings.root / cred_path
    try:
        st = cred_path.stat()
    except FileNotFoundError as exc:
        raise ConfigError(f"credentials_file not found: {cred_path}") from exc
    if st.st_uid != os.getuid():
        raise ConfigError(f"credentials_file {cred_path} is not owned by the current user")
    if st.st_mode & 0o077:
        raise ConfigError(
            f"credentials_file {cred_path} has mode {st.st_mode & 0o777:04o}; "
            "it must not be accessible by group/other (chmod 600)"
        )
    cp = new_parser()
    try:
        cp.read(cred_path, encoding="utf-8")
    except configparser.Error as exc:
        raise ConfigError(f"cannot parse credentials_file {cred_path}: {exc}") from exc
    user = _get(cp, "credentials", "user", "")
    password = _get(cp, "credentials", "password", "")
    if not user or not password:
        raise ConfigError(f"credentials_file {cred_path}: [credentials] user and password required")
    return Credentials(user, password, f"file {cred_path}")


# --------------------------------------------------------------------------- state


class StateStore:
    """process_state.ini wrapper; every mutation is followed by an atomic save."""

    def __init__(self, path: Path, dry_run: bool = False) -> None:
        self.path = path
        self.dry_run = dry_run
        self.lock = threading.RLock()
        self.cp = new_parser()
        if path.exists():
            try:
                self.cp.read(path, encoding="utf-8")
            except configparser.Error as exc:
                raise ConfigError(f"cannot parse state file {path}: {exc}") from exc
        if not self.cp.has_section("_run"):
            self.cp.add_section("_run")
        for sec in self.cp.sections():
            if self.cp.get(sec, "status", fallback="") == "in_progress":
                self.cp.set(sec, "status", "pending")

    def get(self, sec: str, key: str, default: str = "") -> str:
        with self.lock:
            return self.cp.get(sec, key, fallback=default)

    def section(self, sec: str) -> dict[str, str]:
        with self.lock:
            return dict(self.cp[sec]) if self.cp.has_section(sec) else {}

    def update(self, sec: str, save: bool = True, **values: object) -> None:
        with self.lock:
            if not self.cp.has_section(sec):
                self.cp.add_section(sec)
            for k, v in values.items():
                if v is None:
                    self.cp.remove_option(sec, k)
                else:
                    self.cp.set(sec, k, str(v).replace("\n", " "))
            if save:
                self.save()

    def chunk_sections(self, key: str) -> list[str]:
        with self.lock:
            return [s for s in self.cp.sections() if s.startswith(key + "/part")]

    def clear_chunks(self, key: str) -> None:
        with self.lock:
            for s in self.chunk_sections(key):
                self.cp.remove_section(s)

    def reset_table(self, key: str, clear_watermark: bool = False) -> None:
        with self.lock:
            keep = {}
            if self.cp.has_section(key):
                old = self.cp[key]
                if not clear_watermark and old.get("watermark"):
                    keep["watermark"] = old["watermark"]
                self.cp.remove_section(key)
            self.clear_chunks(key)
            self.cp.add_section(key)
            self.cp.set(key, "status", "pending")
            for k, v in keep.items():
                self.cp.set(key, k, v)

    def table_keys(self) -> list[str]:
        with self.lock:
            return [s for s in self.cp.sections() if s != "_run" and "/part" not in s]

    def save(self) -> None:
        if self.dry_run:
            return
        with self.lock:
            atomic_write(self.path, ini_text(self.cp, STATE_HEADER + "\n"))


# ------------------------------------------------------------------- tool running


class SessionPool:
    """Bounds the total number of Teradata sessions used by concurrent jobs."""

    def __init__(self, capacity: int) -> None:
        self.capacity = capacity
        self.used = 0
        self.cond = threading.Condition()

    @contextlib.contextmanager
    def hold(self, n: int):
        n = max(1, min(n, self.capacity))
        with self.cond:
            while self.used + n > self.capacity:
                self.cond.wait()
            self.used += n
        try:
            yield n
        finally:
            with self.cond:
                self.used -= n
                self.cond.notify_all()


FAILURE_CODE_RE = re.compile(r"\b(?:Failure|Error)\s+(\d{3,5})\b")
FEXP_ROWS_RE = re.compile(r"(\d[\d,]*)\s+total records written", re.I)
BTEQ_ROWS_RE = re.compile(r"Query completed\.\s+(?:(\d[\d,]*)\s+rows?\s+found|(No)\s+rows\s+found)", re.I)


class ToolRunner:
    def __init__(self, settings: Settings, creds: Credentials, sessions: SessionPool) -> None:
        self.s = settings
        self.creds = creds
        self.sessions = sessions
        self.procs: set[subprocess.Popen] = set()
        self.procs_lock = threading.Lock()
        self.stopping = threading.Event()

    # script builders -------------------------------------------------------
    def _logon(self) -> list[str]:
        lines = [f".LOGMECH {self.s.logmech};"] if self.s.logmech else []
        lines.append(f".LOGON {self.s.host}/{self.creds.user},{self.creds.password};")
        return lines

    def bteq_script(self, requests: list[tuple[str, Path]]) -> str:
        lines = [f".SET SESSION CHARSET '{self.s.session_charset}';", *self._logon()]
        lines += [".SET ERROROUT STDOUT;", ".SET ERRORLEVEL UNKNOWN SEVERITY 8;"]
        for sql, out in requests:
            lines += [
                f".EXPORT DATA FILE = {out};",
                sql.rstrip().rstrip(";") + ";",
                ".IF ERRORCODE <> 0 THEN .QUIT 8;",
                ".EXPORT RESET;",
            ]
        lines += [".LOGOFF;", ".QUIT 0;"]
        return "\n".join(lines) + "\n"

    def fexp_script(self, sql: str, out: Path, sessions: int, job_id: str) -> str:
        lt = "tdx_lt_" + hashlib.sha1(job_id.encode()).hexdigest()[:12]
        if self.s.logtable_database:
            lt = f"{sql_ident(self.s.logtable_database)}.{lt}"
        lines = [f".LOGTABLE {lt};", *self._logon()]
        lines += [
            f".BEGIN EXPORT SESSIONS {sessions} TENACITY 0;",
            f".EXPORT OUTFILE {out} FORMAT TEXT MODE RECORD;",
            sql.rstrip().rstrip(";") + ";",
            ".END EXPORT;",
            ".LOGOFF;",
        ]
        return "\n".join(lines) + "\n"

    # execution -------------------------------------------------------------
    def is_session_limit(self, output: str) -> bool:
        if any(int(c) in self.s.session_limit_errors for c in FAILURE_CODE_RE.findall(output)):
            return True
        low = output.lower()
        return any(p in low for p in self.s.session_limit_patterns)

    def run(self, tool: str, name: str, script: str, sessions: int = 1) -> str:
        """Run fexp/bteq with the script on stdin; returns the (masked) output text."""
        if self.stopping.is_set():
            raise KeyboardInterrupt
        exe = self.s.fexp_path if tool == "fexp" else self.s.bteq_path
        cmd = [exe]
        if tool == "fexp" and self.s.session_charset == "UTF8":
            cmd += ["-c", "UTF8"]
        pw = self.creds.password
        script_copy = self.s.work_dir / f"{name}.{tool}"
        atomic_write(script_copy, mask_text(script, pw))
        log_path = self.s.log_dir / f"{name}.{tool}.log"
        timeout = self.s.job_timeout_seconds or None
        started = time.monotonic()
        with self.sessions.hold(sessions):
            LOG.debug("running %s for %s (%d session(s))", tool, name, sessions)
            try:
                proc = subprocess.Popen(
                    cmd,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    cwd=self.s.work_dir,
                    start_new_session=True,
                )
            except OSError as exc:
                raise ToolError(f"cannot start {exe}: {exc}") from exc
            with self.procs_lock:
                self.procs.add(proc)
            try:
                out_b, _ = proc.communicate(script.encode("utf-8"), timeout=timeout)
            except subprocess.TimeoutExpired:
                proc.kill()
                out_b, _ = proc.communicate()
                rc: int | None = None
            else:
                rc = proc.returncode
            finally:
                with self.procs_lock:
                    self.procs.discard(proc)
        output = mask_text(out_b.decode("utf-8", errors="replace"), pw)
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(
                f"===== {iso(utcnow())} {tool} sessions={sessions} rc={rc} "
                f"elapsed={time.monotonic() - started:.1f}s\n{output}\n"
            )
        if self.stopping.is_set():
            raise KeyboardInterrupt
        if rc is None:
            raise ToolError(f"{tool} timed out after {timeout:.0f}s ({log_path.name})")
        failed = rc != 0 or (tool == "bteq" and re.search(r"\*\*\* (?:Failure|Error) \d+", output))
        if failed:
            first = next(
                (ln.strip() for ln in output.splitlines() if re.search(r"Failure|Error", ln)),
                f"exit code {rc}",
            )
            raise ToolError(
                f"{tool} failed (rc={rc}): {first} (see {log_path.name})",
                session_limit=self.is_session_limit(output),
            )
        return output

    def kill_all(self) -> None:
        self.stopping.set()
        with self.procs_lock:
            for proc in list(self.procs):
                with contextlib.suppress(OSError):
                    os.killpg(proc.pid, 15)

    def query(self, name: str, requests: list[str]) -> list[list[list[str | None]]]:
        """Run marked SELECTs (each returning one VARCHAR) through one BTEQ logon."""
        raws = [self.s.work_dir / f"{name}.q{i + 1}.raw" for i in range(len(requests))]
        for r in raws:
            with contextlib.suppress(FileNotFoundError):
                r.unlink()
        script = self.bteq_script(list(zip(requests, raws)))
        attempt = 0
        while True:
            try:
                self.run("bteq", name, script)
                break
            except ToolError as exc:
                if exc.session_limit and attempt < self.s.retry_attempts:
                    attempt += 1
                    LOG.warning("%s: session limit, retry %d in %ss", name, attempt, self.s.retry_delay_seconds)
                    time.sleep(self.s.retry_delay_seconds)
                    continue
                raise
        results = []
        for r in raws:
            data = r.read_bytes() if r.exists() else b""
            records, _ = parse_raw_export(data, "bteq")
            rows = []
            for rec in records:
                text = rec.decode("utf-8", errors="strict")
                rows.append([decode_field(f, "\\N", "") for f in split_fields(text)])
            results.append(rows)
            with contextlib.suppress(FileNotFoundError):
                r.unlink()
        return results


# ------------------------------------------------------------------ type mapping


@dataclass
class Column:
    position: int
    name: str
    type_code: str
    length: int
    total_digits: int
    frac_digits: int
    nullable: bool
    char_type: int

    @property
    def charset(self) -> str:
        return CHARSET_NAMES.get(self.char_type, "") if self.type_code in TEXT_TYPES | {"CO"} else ""

    @property
    def source_type(self) -> str:
        c, p, s = self.type_code, self.total_digits, self.frac_digits
        name = TYPE_NAMES.get(c, f"UNKNOWN({c})")
        if c in {"D", "N"}:
            return f"{name}({p},{s})" if p > 0 and s >= 0 else f"{name}(*)"
        if c in {"CF", "CV", "BF", "BV", "CO", "BO"}:
            n = self.length // 2 if c in {"CF", "CV", "CO"} and self.char_type == 2 else self.length
            cs = f" CHARACTER SET {self.charset}" if self.charset else ""
            return f"{name}({n}){cs}"
        if c in {"TS", "SZ", "AT", "TZ"}:
            base = name.split(" ")[0]
            rest = name[len(base):]
            return f"{base}({max(s, 0)}){rest}"
        return name


@dataclass
class ColumnRule:
    col: Column
    output_encoding: str
    redshift_type: str
    expr: str = ""
    max_len: int = 0
    lob: bool = False
    empty_possible: bool = False
    notes: str = ""


def _esc_sql(s: Settings, x: str) -> str:
    e, d = sql_str(s.escape_char), sql_str(s.delimiter)
    out = f"OREPLACE({x}, {e}, {sql_str(s.escape_char * 2)})"
    out = f"OREPLACE({out}, {d}, {sql_str(s.escape_char + s.delimiter)})"
    out = f"OREPLACE({out}, '0D'XC, {e} || '0D'XC)"
    return f"OREPLACE({out}, '0A'XC, {e} || '0A'XC)"


def _text_value(s: Settings, col_sql: str, text_sql: str, length_fn: str) -> str:
    parts = [f"CASE WHEN {col_sql} IS NULL THEN {sql_str(s.null_sentinel)}"]
    if s.empty_sentinel:
        parts.append(f"WHEN {length_fn}({text_sql}) = 0 THEN {sql_str(s.empty_sentinel)}")
    parts.append(f"ELSE {_esc_sql(s, text_sql)} END")
    return " ".join(parts)


def _plain_value(s: Settings, col_sql: str, text_sql: str) -> str:
    return f"CASE WHEN {col_sql} IS NULL THEN {sql_str(s.null_sentinel)} ELSE {text_sql} END"


def _dt_format(frac: int, with_date: bool) -> str:
    f = f".S({frac})" if frac > 0 else ""
    return ("YYYY-MM-DDB" if with_date else "") + "HH:MI:SS" + f


def build_rule(col: Column, s: Settings) -> ColumnRule:
    c = col.type_code
    q = sql_ident(col.name)
    p, sc = col.total_digits, col.frac_digits
    if c in INT_TYPES:
        r = ColumnRule(col, "int_text", INT_TYPES[c], max_len=20)
        r.expr = _plain_value(s, q, f"TRIM(CAST({q} AS VARCHAR(25)))")
        return r
    if c in {"D", "N"}:
        bounded = 0 < p <= 38 and 0 <= sc <= p
        big = not bounded or p > s.big_decimal_threshold
        if bounded:
            fmt = f"-({max(p - sc, 1)})9" + (f".9({sc})" if sc else "")
            text = f"TRIM(CAST(CAST({q} AS FORMAT '{fmt}') AS VARCHAR({p + 3})))"
            rs_type = f"DECIMAL({p},{sc})"
            width = p + 3
        else:
            text = f"TRIM(CAST({q} AS VARCHAR(60)))"
            rs_type = "VARCHAR(64)"
            width = 60
        notes = "" if bounded else "unbounded NUMBER exported as text; verify formatting on the source"
        if big and s.big_decimal_quote:
            qq = sql_str(s.big_decimal_quote)
            text = f"{qq} || {text} || {qq}"
            width += 2
        r = ColumnRule(col, "decimal_quoted" if big else "decimal_text", rs_type, max_len=width, notes=notes)
        r.expr = _plain_value(s, q, text)
        return r
    if c == "F":
        r = ColumnRule(col, "float_text", "FLOAT8", max_len=25)
        r.expr = _plain_value(s, q, f"TRIM(CAST(CAST({q} AS FORMAT '-9.9(16)E-999') AS VARCHAR(30)))")
        return r
    if c == "DA":
        r = ColumnRule(col, "iso_date", "DATE", max_len=10)
        r.expr = _plain_value(s, q, f"CAST(CAST({q} AS FORMAT 'YYYY-MM-DD') AS CHAR(10))")
        return r
    if c in {"AT", "TZ"}:
        fr = max(sc, 0)
        src = q if c == "AT" else f"CAST(({q} AT TIME ZONE INTERVAL '00:00' HOUR TO MINUTE) AS TIME({fr}))"
        text = f"TRIM(CAST(CAST({src} AS FORMAT '{_dt_format(fr, False)}') AS VARCHAR(16)))"
        if c == "TZ":
            text += " || 'Z'"
        r = ColumnRule(col, "iso_time" if c == "AT" else "utc_iso_time", "TIME" if c == "AT" else "TIMETZ", max_len=17)
        r.expr = _plain_value(s, q, text)
        return r
    if c in {"TS", "SZ"}:
        fr = max(sc, 0)
        src = q if c == "TS" else f"CAST(({q} AT TIME ZONE INTERVAL '00:00' HOUR TO MINUTE) AS TIMESTAMP({fr}))"
        text = f"OREPLACE(TRIM(CAST(CAST({src} AS FORMAT '{_dt_format(fr, True)}') AS VARCHAR(27))), ' ', 'T')"
        if c == "SZ":
            text += " || 'Z'"
        r = ColumnRule(
            col,
            "iso_timestamp" if c == "TS" else "utc_iso_timestamp",
            "TIMESTAMP" if c == "TS" else "TIMESTAMPTZ",
            max_len=28,
        )
        r.expr = _plain_value(s, q, text)
        return r
    if c in INTERVAL_TYPES or c in PERIOD_TYPES:
        width = 40 if c in INTERVAL_TYPES else 80
        enc = "interval_text" if c in INTERVAL_TYPES else "period_text"
        r = ColumnRule(col, enc, f"VARCHAR({width})", max_len=width)
        r.expr = _plain_value(s, q, f"TRIM(CAST({q} AS VARCHAR({width})))")
        return r
    if c in TEXT_TYPES or c in LOB_TEXT_TYPES:
        unicode = col.char_type == 2 or c in {"JN", "XM"} and s.session_charset == "UTF8"
        if col.char_type not in (0, 1, 2) and c in TEXT_TYPES | {"CO"}:
            return ColumnRule(col, "unsupported", "", notes=f"character set {col.charset or col.char_type} not supported")
        if col.char_type == 2 and s.session_charset == "ASCII":
            return ColumnRule(
                col, "unsupported", "",
                notes="UNICODE column cannot be exported losslessly with session_charset = ASCII; use UTF8",
            )
        if c in LOB_TEXT_TYPES:
            n = s.lob_max_length
            text = (
                f"XMLSERIALIZE(CONTENT {q} AS VARCHAR({n}))" if c == "XM" else f"CAST({q} AS VARCHAR({n}))"
            )
            r = ColumnRule(col, "escaped_text", "VARCHAR(65535)", max_len=2 * n, lob=True, empty_possible=True)
            r.expr = _text_value(s, q, text, "CHARACTER_LENGTH")
            return r
        chars = col.length // 2 if col.char_type == 2 else col.length
        if c == "CF":
            text = {"right": f"TRIM(TRAILING FROM {q})", "both": f"TRIM(BOTH FROM {q})", "none": q}[s.char_trim]
            if s.char_trim == "none" and chars <= 4096 and not unicode:
                rs = f"CHAR({chars})"
            else:
                rs = f"VARCHAR({min(chars * (4 if unicode else 1), 65535)})"
        else:
            text = q
            rs = f"VARCHAR({min(max(chars, 1) * (4 if unicode else 1), 65535)})"
        r = ColumnRule(col, "escaped_text", rs, max_len=2 * chars, empty_possible=True)
        r.expr = _text_value(s, q, text, "CHARACTER_LENGTH")
        if c == "CF" and s.char_trim != "none":
            r.notes = f"CHAR padding trimmed ({s.char_trim})"
        return r
    if c in BINARY_TYPES or c == "BO":
        n = s.lob_max_length if c == "BO" else col.length
        src = f"CAST({q} AS VARBYTE({n}))" if c == "BO" else q
        r = ColumnRule(
            col, "hex", f"VARBYTE({min(max(n, 1), 1024000)})", max_len=2 * n, lob=c == "BO", empty_possible=True,
            notes="hex (base16) encoded bytes",
        )
        parts = [f"CASE WHEN {q} IS NULL THEN {sql_str(s.null_sentinel)}"]
        if s.empty_sentinel:
            parts.append(f"WHEN BYTES({src}) = 0 THEN {sql_str(s.empty_sentinel)}")
        parts.append(f"ELSE FROM_BYTES({src}, 'base16') END")
        r.expr = " ".join(parts)
        return r
    return ColumnRule(col, "unsupported", "", notes=f"Teradata type code {c!r} is not supported")


def record_sql(rules: list[ColumnRule], s: Settings) -> str:
    joined = f" || {sql_str(s.delimiter)} || ".join(f"({r.expr})" for r in rules)
    return f"CAST({joined} AS VARCHAR({s.max_row_length}))"


def wrap_fields(exprs: list[str], untrimmed: tuple[str, ...] = ()) -> str:
    """Single-VARCHAR result row for internal queries (NULL -> \\N, | escaped).

    Expressions in untrimmed (identifiers) keep leading/trailing spaces.
    """
    parts = [
        f"COALESCE(OREPLACE(OREPLACE("
        + (f"CAST({e} AS VARCHAR(256))" if e in untrimmed else f"TRIM(CAST({e} AS VARCHAR(256)))")
        + "), '\\', '\\\\'), '|', '\\|'), '\\N')"
        for e in exprs
    ]
    return " || '|' || ".join(parts)


def marker(kind: str, t: SourceTable, **extra: str) -> str:
    bits = [f"query={kind}", f"db={t.database}", f"table={t.table}"]
    for k, v in extra.items():
        if v:
            v = v.replace("*/", "")
            bits.append(f'{k}="{v}"' if (" " in v or "," in v) else f"{k}={v}")
    return "/* TDX " + " ".join(bits) + " */"


def where_sql(*preds: str) -> str:
    preds = tuple(p for p in preds if p)
    return (" WHERE " + " AND ".join(f"({p})" for p in preds)) if preds else ""


# --------------------------------------------------------------------- planning


@dataclass
class Chunk:
    index: int
    count: int
    where: str
    file_name: str
    est_rows: int

    @property
    def part(self) -> str:
        return f"part{self.index:03d}"

    @property
    def job_name(self) -> str:
        return Path(self.file_name).stem


@dataclass
class TableWork:
    src: SourceTable
    started: float = 0.0
    rules: list[ColumnRule] = field(default_factory=list)
    lob: bool = False
    chunks: list[Chunk] = field(default_factory=list)
    pending: set[int] = field(default_factory=set)
    errors: list[str] = field(default_factory=list)
    methods: set[str] = field(default_factory=set)
    cdc_from: str = ""
    cdc_to: str = ""
    no_new_rows: bool = False
    may_truncate: bool = False
    est_rows: int = 0


NUMERIC_RE = re.compile(r"^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$")


def cdc_expr(col: Column) -> str:
    q = sql_ident(col.name)
    if col.type_code == "SZ":
        return f"CAST(({q} AT TIME ZONE INTERVAL '00:00' HOUR TO MINUTE) AS TIMESTAMP(6))"
    return q


def cdc_literal(col: Column, value: str) -> str:
    if col.type_code in {"DA"}:
        return f"DATE {sql_str(value)}"
    if col.type_code in {"TS", "SZ"}:
        return f"TIMESTAMP {sql_str(value)}"
    if not NUMERIC_RE.match(value):
        raise ExtractError(f"invalid numeric watermark {value!r} for {col.name}")
    return value


def cdc_window_pred(col: Column, lo: str, hi: str) -> str:
    """CDC predicate; the initial (no watermark) extract also takes rows whose CDC value is NULL."""
    if not hi:
        return ""
    upper = f"{cdc_expr(col)} <= {cdc_literal(col, hi)}"
    if not lo:
        return f"{upper} OR {sql_ident(col.name)} IS NULL"
    return f"{cdc_expr(col)} > {cdc_literal(col, lo)} AND {upper}"


def cdc_max_sql(col: Column) -> str:
    e = cdc_expr(col)
    if col.type_code == "DA":
        return f"CAST(CAST(MAX({e}) AS FORMAT 'YYYY-MM-DD') AS CHAR(10))"
    if col.type_code in {"TS", "SZ"}:
        return f"CAST(CAST(CAST(MAX({e}) AS TIMESTAMP(6)) AS FORMAT 'YYYY-MM-DDBHH:MI:SS.S(6)') AS CHAR(26))"
    return f"MAX({e})"


def range_predicates(col: Column, lo: str, hi: str, n: int) -> list[str]:
    """n range predicates covering every value (NULLs and out-of-range values included)."""
    from decimal import Decimal

    q = sql_ident(col.name)
    if col.type_code == "DA":
        a, b = dt.date.fromisoformat(lo).toordinal(), dt.date.fromisoformat(hi).toordinal()
        n = max(1, min(n, b - a + 1))
        bounds = sorted({a + math.ceil(k * (b - a + 1) / n) for k in range(1, n)})
        lits = [f"DATE '{dt.date.fromordinal(x).isoformat()}'" for x in bounds]
    elif col.type_code in INT_TYPES or (col.type_code in {"D", "N"} and col.frac_digits == 0):
        a, b = int(Decimal(lo)), int(Decimal(hi))
        n = max(1, min(n, b - a + 1))
        bounds = sorted({a + math.ceil(k * (b - a + 1) / n) for k in range(1, n)})
        lits = [str(x) for x in bounds]
    else:
        a2, b2 = Decimal(lo), Decimal(hi)
        if a2 == b2:
            n = 1
        step = (b2 - a2) / n if n else Decimal(0)
        lits = sorted({str(a2 + step * k) for k in range(1, n)}, key=Decimal)
    if not lits:
        return [""]
    preds = [f"{q} < {lits[0]} OR {q} IS NULL"]
    preds += [f"{q} >= {lits[i - 1]} AND {q} < {lits[i]}" for i in range(1, len(lits))]
    preds.append(f"{q} >= {lits[-1]}")
    return preds


def write_meta(path: Path, w: TableWork, s: Settings, primary_index: list[str], strategy: str,
               chunk_col: str, est_source: str) -> None:
    cp = new_parser()
    t = w.src
    cp["table"] = {
        "database": t.database,
        "table": t.table,
        "extracted_at": iso(utcnow()),
        "column_count": str(len(w.rules)),
        "row_estimate": str(w.est_rows),
        "row_estimate_source": est_source,
        "primary_index": ",".join(primary_index),
        "chunk_strategy": strategy,
        "chunk_column": chunk_col,
        "chunk_count": str(len(w.chunks)),
        "cdc_column": t.cdc_column,
        "session_charset": s.session_charset,
        "file_format": "pipe-delimited",
        "delimiter": s.delimiter,
        "null_sentinel": s.null_sentinel,
        "empty_sentinel": s.empty_sentinel,
        "escape_char": s.escape_char,
        "escaped_characters": f"{s.escape_char} {s.delimiter} CR LF",
        "record_terminator": "LF",
        "timezone_policy": "UTC",
        "export_method": "bteq" if w.lob else "fexp/bteq by size",
    }
    for r in w.rules:
        c = r.col
        sec = {
            "name": c.name,
            "position": str(c.position),
            "source_type": c.source_type,
            "td_type_code": c.type_code,
            "nullable": "yes" if c.nullable else "no",
            "char_set": c.charset or "n/a",
            "output_encoding": r.output_encoding,
            "redshift_type": r.redshift_type or "n/a",
            "null_sentinel": s.null_sentinel,
            "empty_sentinel": (s.empty_sentinel or "(empty)") if r.empty_possible else "n/a",
            "empty_string_possible": "yes" if r.empty_possible else "no",
        }
        if c.type_code in {"SZ", "TZ"}:
            sec["source_timezone"] = "per-value offset, converted to UTC"
        if r.notes:
            sec["notes"] = r.notes
        cp[f"column.{c.position:03d}"] = sec
    atomic_write(path, ini_text(cp, f"# Generated by teradata_extract for {t.key}\n"))


def zip_table(files: list[Path], zip_path: Path) -> str:
    tmp = zip_path.with_name(zip_path.name + ".tmp")
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as zf:
        for f in files:
            zf.write(f, arcname=f.name)
    with zipfile.ZipFile(tmp) as zf:
        bad = zf.testzip()
        if bad is not None:
            raise ExtractError(f"zip integrity test failed for member {bad}")
        sizes = {i.filename: i.file_size for i in zf.infolist()}
    for f in files:
        if sizes.get(f.name) != f.stat().st_size:
            raise ExtractError(f"zip member size mismatch for {f.name}")
    os.replace(tmp, zip_path)
    return sha256_file(zip_path)


# ------------------------------------------------------------------- extraction


class Extractor:
    def __init__(self, s: Settings, creds: Credentials, state: StateStore, run_id: str) -> None:
        self.s = s
        self.creds = creds
        self.state = state
        self.run_id = run_id
        self.cycle_id = state.get("_run", "cycle_id")
        self.runner = ToolRunner(s, creds, SessionPool(s.max_sessions))
        self.audit_lock = threading.Lock()
        self.results: dict[str, str] = {}
        self.rows_total = 0
        self.dat_files = 0
        self.zip_files = 0
        self.failures: dict[str, str] = {}

    def _mask(self, msg: str) -> str:
        return mask_text(msg, self.creds.password)

    # ---------------------------------------------------------------- prepare
    def prepare(self, w: TableWork) -> None:
        t, s = w.src, self.s
        key = t.key
        prev = self.state.section(key)
        self.state.update(
            key,
            status="in_progress",
            attempts=int(prev.get("attempts", "0") or 0) + 1,
            started_at=iso(utcnow()),
            last_error=None,
        )
        reqs = [
            marker("columns", t) + " SELECT " + wrap_fields([
                "ColumnId", "ColumnName", "ColumnType", "ColumnLength",
                "DecimalTotalDigits", "DecimalFractionalDigits", "Nullable", "CharType",
            ], untrimmed=("ColumnName",)) + f" FROM DBC.ColumnsV WHERE DatabaseName = {sql_str(t.database)}"
            f" AND TableName = {sql_str(t.table)} ORDER BY ColumnId",
            marker("index", t) + " SELECT " + wrap_fields(
                ["IndexType", "UniqueFlag", "ColumnPosition", "ColumnName"], untrimmed=("ColumnName",)
            ) + f" FROM DBC.IndicesV WHERE DatabaseName = {sql_str(t.database)}"
            f" AND TableName = {sql_str(t.table)} ORDER BY IndexNumber, ColumnPosition",
        ]
        if s.row_estimate == "stats":
            reqs.append(
                marker("stats", t) + " SELECT " + wrap_fields(["MAX(RowCount)"])
                + f" FROM DBC.StatsV WHERE DatabaseName = {sql_str(t.database)}"
                f" AND TableName = {sql_str(t.table)}"
            )
        res = self.runner.query(f"{t.base}.meta", reqs)
        cols_rows, idx_rows = res[0], res[1]
        stats_rows = res[2] if len(res) > 2 else []
        if not cols_rows:
            raise ExtractError(f"no column metadata for {key} (table missing, a view, or no access)")
        cols = []
        for r in cols_rows:
            try:
                cols.append(Column(
                    position=len(cols) + 1,
                    name=r[1] or "",
                    type_code=(r[2] or "").strip().upper(),
                    length=int(r[3] or 0),
                    total_digits=int(r[4] or 0),
                    frac_digits=int(r[5] or 0),
                    nullable=(r[6] or "Y").strip().upper() == "Y",
                    char_type=int(r[7] or 0),
                ))
            except (ValueError, IndexError) as exc:
                raise ExtractError(f"unexpected DBC.ColumnsV row {r!r}") from exc
        w.rules = [build_rule(c, s) for c in cols]
        w.lob = any(r.lob for r in w.rules)
        by_name = {c.name.upper(): c for c in cols}
        pi = [r[3] for r in idx_rows if r and len(r) > 3 and r[0] in {"P", "Q"} and r[3]]
        pk = [r[3] for r in idx_rows if r and len(r) > 3 and r[0] == "K" and r[3]]
        meta_path = s.metadata_dir / f"{t.base}.meta.ini"

        unsupported = [r for r in w.rules if r.output_encoding == "unsupported"]
        if unsupported:
            write_meta(meta_path, w, s, pi, "none", "", "n/a")
            raise ExtractError(
                "unsupported column(s): "
                + "; ".join(f"{r.col.name} {r.col.source_type}: {r.notes}" for r in unsupported)
            )

        # CDC window
        cdc_pred = ""
        cdc_col: Column | None = None
        if t.cdc_column:
            cdc_col = by_name.get(t.cdc_column.upper())
            if cdc_col is None:
                raise ExtractError(f"cdc_column {t.cdc_column} not found in {key}")
            if cdc_col.type_code not in CDC_TYPES:
                raise ExtractError(f"cdc_column {t.cdc_column} type {cdc_col.source_type} not supported for CDC")
            w.cdc_from = prev.get("watermark", "")
            w.cdc_to = prev.get("pending_watermark", "")
            lower = f"{cdc_expr(cdc_col)} > {cdc_literal(cdc_col, w.cdc_from)}" if w.cdc_from else ""
            if not w.cdc_to:
                sql = (
                    marker("cdcmax", t, cdc_gt=w.cdc_from) + " SELECT " + wrap_fields([cdc_max_sql(cdc_col)])
                    + f" FROM {t.fqn}" + where_sql(lower, t.where)
                )
                rows = self.runner.query(f"{t.base}.cdc", [sql])[0]
                w.cdc_to = (rows[0][0] or "") if rows and rows[0] else ""
                if not w.cdc_to and not w.cdc_from:
                    LOG.warning("%s: %s has no non-NULL values; extracting the full table without a watermark",
                                key, t.cdc_column)
                elif not w.cdc_to:
                    w.no_new_rows = True
                    w.est_rows = 0
                    write_meta(meta_path, w, s, pi, "none", "", "cdc")
                    self.state.update(key, method="none", estimated_rows=0, row_estimate_source="cdc",
                                      chunk_strategy="none", chunk_count=0, chunks_done="")
                    return
                else:
                    self.state.update(key, pending_watermark=w.cdc_to)
            if cdc_col.nullable:
                LOG.info("%s: rows with NULL %s are taken only by the initial (no watermark) extract",
                         key, t.cdc_column)
            cdc_pred = cdc_window_pred(cdc_col, w.cdc_from, w.cdc_to)
        base_preds = (cdc_pred, t.where)
        cdc_marks = {"cdc_gt": w.cdc_from, "cdc_le": w.cdc_to}

        # Reuse an existing chunk plan when resuming
        existing = sorted(self.state.chunk_sections(key))
        if existing and prev.get("chunk_count") and int(prev["chunk_count"]) == len(existing):
            n = len(existing)
            done = {int(x) for x in prev.get("chunks_done", "").split(",") if x}
            w.est_rows = int(prev.get("estimated_rows", "0") or 0)
            zipped = prev.get("zip_file") == f"{t.base}_{self.cycle_id}.zip"
            for i, sec in enumerate(existing, start=1):
                cs = self.state.section(sec)
                w.chunks.append(Chunk(i, n, cs.get("where", ""), cs["file"], int(cs.get("est_rows", "0") or 0)))
                if i not in done or cs.get("status") != "done":
                    w.pending.add(i)
                elif not zipped and not (s.output_dir / cs["file"]).exists():
                    LOG.warning("%s: %s is missing, re-exporting chunk %d", key, cs["file"], i)
                    w.pending.add(i)
            strategy, chunk_col_name, est_source = (
                prev.get("chunk_strategy", "none"), prev.get("chunk_column", ""), prev.get("row_estimate_source", ""))
            self._prechecks(w, base_preds, cdc_marks)
            write_meta(meta_path, w, s, pi, strategy, chunk_col_name, est_source)
            return

        # Row estimate
        est: int | None = None
        est_source = "count"
        checks: list[str] = []
        if s.row_estimate == "stats" and not w.cdc_from and not t.where and stats_rows:
            v = stats_rows[0][0] if stats_rows[0] else None
            if v:
                est, est_source = int(Decimal_or_int(v)), "stats"
        if est is None:
            sql = (
                marker("count", t, **cdc_marks) + " SELECT " + wrap_fields(["CAST(COUNT(*) AS BIGINT)"])
                + f" FROM {t.fqn}" + where_sql(*base_preds)
            )
            rows = self.runner.query(f"{t.base}.count", [sql])[0]
            est = int(rows[0][0] or 0) if rows and rows[0] else 0
            checks.append("count")
        w.est_rows = est

        # Chunk plan
        strategy, chunk_col_name, preds = "none", "", [""]
        if est > s.chunk_threshold_rows:
            n = max(2, min(s.max_chunks, math.ceil(est / s.chunk_rows)))
            cand: Column | None = None
            if t.chunk_column:
                cand = by_name.get(t.chunk_column.upper())
                if cand is None:
                    raise ExtractError(f"chunk_column {t.chunk_column} not found in {key}")
            else:
                for keys in (pk, pi):
                    if len(keys) == 1 and by_name.get(keys[0].upper()) and \
                            by_name[keys[0].upper()].type_code in CHUNKABLE_TYPES:
                        cand = by_name[keys[0].upper()]
                        break
            if cand is not None and cand.type_code in CHUNKABLE_TYPES:
                q = sql_ident(cand.name)
                lo_hi = (
                    f"CAST(CAST(MIN({q}) AS FORMAT 'YYYY-MM-DD') AS CHAR(10))",
                    f"CAST(CAST(MAX({q}) AS FORMAT 'YYYY-MM-DD') AS CHAR(10))",
                ) if cand.type_code == "DA" else (f"MIN({q})", f"MAX({q})")
                sql = (
                    marker("minmax", t, col=cand.name, **cdc_marks) + " SELECT " + wrap_fields(list(lo_hi))
                    + f" FROM {t.fqn}" + where_sql(*base_preds)
                )
                rows = self.runner.query(f"{t.base}.minmax", [sql])[0]
                lo, hi = (rows[0][0], rows[0][1]) if rows and len(rows[0]) > 1 else (None, None)
                if lo is not None and hi is not None:
                    preds = range_predicates(cand, lo.strip(), hi.strip(), n)
                    strategy, chunk_col_name = ("range", cand.name) if len(preds) > 1 else ("none", "")
                    if len(preds) == 1:
                        preds = [""]
            else:
                hash_cols = [cand.name] if cand is not None else (pi or [cols[0].name])
                hc = ",".join(sql_ident(c) for c in hash_cols)
                preds = [f"HASHBUCKET(HASHROW({hc})) MOD {n} = {i}" for i in range(n)]
                strategy, chunk_col_name = "hash", ",".join(hash_cols)
        n = len(preds)
        self.state.clear_chunks(key)
        for i, p in enumerate(preds, start=1):
            fname = f"{t.base}.part{i:03d}.dat" if n > 1 else f"{t.base}.dat"
            ch = Chunk(i, n, p, fname, math.ceil(est / n) if n else 0)
            w.chunks.append(ch)
            w.pending.add(i)
            self.state.update(f"{key}/{ch.part}", save=False, status="pending", file=fname, where=p,
                              est_rows=ch.est_rows)
        self.state.update(
            key, estimated_rows=est, row_estimate_source=est_source, chunk_strategy=strategy,
            chunk_column=chunk_col_name, chunk_count=n, chunks_done="",
        )
        self._prechecks(w, base_preds, cdc_marks)
        write_meta(meta_path, w, s, pi, strategy, chunk_col_name, est_source)

    def _prechecks(self, w: TableWork, base_preds: tuple[str, str], cdc_marks: dict[str, str]) -> None:
        t, s = w.src, self.s
        reqs: list[str] = []
        lob_rules = [r for r in w.rules if r.lob]
        if lob_rules:
            exprs = []
            for r in lob_rules:
                q = sql_ident(r.col.name)
                exprs.append({
                    "BO": f"MAX(BYTES({q}))",
                    "XM": f"MAX(CHARACTER_LENGTH(XMLSERIALIZE(CONTENT {q} AS CLOB)))",
                    "JN": f"MAX(CHARACTER_LENGTH(CAST({q} AS CLOB)))",
                }.get(r.col.type_code, f"MAX(CHARACTER_LENGTH({q}))"))
            reqs.append(
                marker("lobcheck", t, cols=",".join(r.col.name for r in lob_rules), **cdc_marks)
                + " SELECT " + wrap_fields(exprs) + f" FROM {t.fqn}" + where_sql(*base_preds)
            )
        sentinel = max(len(s.null_sentinel), len(s.empty_sentinel))
        theoretical = sum(max(r.max_len, sentinel) for r in w.rules) + len(w.rules) - 1
        w.may_truncate = theoretical > s.max_row_length
        if theoretical > s.max_row_length:
            total = " + ".join(f"CHARACTER_LENGTH({r.expr})" for r in w.rules)
            reqs.append(
                marker("rowcheck", t, **cdc_marks) + " SELECT "
                + wrap_fields([f"MAX({total}) + {len(w.rules) - 1}"])
                + f" FROM {t.fqn}" + where_sql(*base_preds)
            )
        if not reqs:
            return
        res = self.runner.query(f"{t.base}.check", reqs)
        pos = 0
        if lob_rules:
            row = res[0][0] if res[0] else []
            for r, v in zip(lob_rules, row):
                if v and int(Decimal_or_int(v)) > s.lob_max_length:
                    raise ExtractError(
                        f"LOB value length {int(Decimal_or_int(v))} in {r.col.name} exceeds "
                        f"lob_max_length {s.lob_max_length}"
                    )
            pos = 1
        if theoretical > s.max_row_length:
            row = res[pos][0] if res[pos] else []
            v = row[0] if row else None
            if v and int(Decimal_or_int(v)) > s.max_row_length:
                raise ExtractError(
                    f"record length {int(Decimal_or_int(v))} exceeds max_row_length {s.max_row_length}"
                )

    # ----------------------------------------------------------------- export
    def export_chunk(self, w: TableWork, ch: Chunk) -> None:
        t, s = w.src, self.s
        sec = f"{t.key}/{ch.part}"
        dat = s.output_dir / ch.file_name
        raw = dat.with_name(dat.name + ".raw")
        marks = {"cdc_gt": w.cdc_from, "cdc_le": w.cdc_to}
        if ch.count > 1:
            marks["chunk"] = f"{ch.index}/{ch.count}"
        preds = (
            *(p for p in [self._cdc_pred(w)] if p),
            t.where,
            ch.where,
        )
        sql = (
            marker("export", t, **marks) + " SELECT " + record_sql(w.rules, s)
            + f" AS tdx_rec FROM {t.fqn}" + where_sql(*preds)
        )
        method = "bteq" if w.lob or ch.est_rows < s.small_table_rows else "fexp"
        sessions = 1 if method == "bteq" else max(s.min_sessions, s.max_sessions // max(1, s.parallel))
        self.state.update(sec, status="in_progress", method=method, sessions=sessions)
        attempt = 0
        fell_back = False
        while True:
            for p in (raw, dat):
                with contextlib.suppress(FileNotFoundError):
                    p.unlink()
            job_id = f"{ch.job_name}|{self.run_id}|{attempt}|{method}"
            try:
                if method == "fexp":
                    out = self.runner.run("fexp", ch.job_name, self.runner.fexp_script(sql, raw, sessions, job_id),
                                          sessions)
                else:
                    out = self.runner.run("bteq", ch.job_name, self.runner.bteq_script([(sql, raw)]), 1)
                break
            except ToolError as exc:
                if not exc.session_limit:
                    raise
                if attempt < s.retry_attempts:
                    attempt += 1
                    sessions = max(s.min_sessions, sessions // 2) if method == "fexp" else 1
                    LOG.warning("%s: session limit hit, retry %d/%d in %ss with %d session(s)",
                                ch.job_name, attempt, s.retry_attempts, s.retry_delay_seconds, sessions)
                    self.state.update(sec, sessions=sessions)
                    time.sleep(s.retry_delay_seconds)
                    continue
                if method == "fexp" and s.bteq_fallback and not fell_back:
                    LOG.warning("%s: FastExport retries exhausted, falling back to BTEQ EXPORT", ch.job_name)
                    method, sessions, fell_back = "bteq", 1, True
                    self.state.update(sec, method=method, sessions=1)
                    continue
                raise
        want = len(w.rules)
        delim, esc = s.delimiter.encode(), s.escape_char.encode()
        utf8 = s.session_charset == "UTF8"
        tmp = dat.with_name(dat.name + ".tmp")
        seen = 0
        error = ""

        def reset() -> None:
            nonlocal seen, error
            seen, error = 0, ""

        def sink(rec: bytes) -> None:
            nonlocal seen, error
            seen += 1
            if error:
                return
            if (nf := field_count(rec, delim, esc)) != want:
                error = f"{ch.job_name}: record {seen} has {nf} fields, expected {want}"
            elif w.may_truncate and len(rec.decode("utf-8", "replace") if utf8 else rec) >= s.max_row_length:
                error = (f"{ch.job_name}: record {seen} reached max_row_length {s.max_row_length} "
                         "(possible truncation); raise max_row_length")
            else:
                fh.write(rec)
                fh.write(b"\n")

        try:
            with tmp.open("w+b", buffering=1 << 20) as fh:
                n_rows, layout = stream_raw_export(raw, fh, method, sink, reset)
                if error:
                    raise ExtractError(error)
                fh.flush()
                os.fsync(fh.fileno())
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise
        reported = self._reported_rows(method, out)
        if reported is not None and reported != n_rows:
            tmp.unlink(missing_ok=True)
            raise ExtractError(f"{ch.job_name}: {method} reported {reported} rows but {n_rows} were parsed")
        os.replace(tmp, dat)
        raw.unlink(missing_ok=True)
        w.methods.add(method)
        self.state.update(
            sec, status="done", rows=n_rows, bytes=dat.stat().st_size, sha256=sha256_file(dat),
            method=method, layout=layout, finished_at=iso(utcnow()),
        )
        with self.state.lock:
            done = {int(x) for x in self.state.get(t.key, "chunks_done").split(",") if x}
            done.add(ch.index)
            self.state.update(t.key, chunks_done=",".join(str(x) for x in sorted(done)))
        LOG.info("%s: %d rows via %s", ch.job_name, n_rows, method)

    def _cdc_pred(self, w: TableWork) -> str:
        if not w.src.cdc_column or not w.cdc_to:
            return ""
        col = next(r.col for r in w.rules if r.col.name.upper() == w.src.cdc_column.upper())
        return cdc_window_pred(col, w.cdc_from, w.cdc_to)

    @staticmethod
    def _reported_rows(method: str, out: str) -> int | None:
        if method == "fexp":
            m = FEXP_ROWS_RE.findall(out)
            return int(m[-1].replace(",", "")) if m else None
        m2 = BTEQ_ROWS_RE.findall(out)
        if not m2:
            return None
        n, no = m2[-1]
        return 0 if no else int(n.replace(",", ""))

    # --------------------------------------------------------------- finalize
    def finalize(self, w: TableWork) -> None:
        t, s = w.src, self.s
        key = t.key
        elapsed = time.monotonic() - w.started
        st = self.state.section(key)
        chunk_secs = sorted(self.state.chunk_sections(key))
        if w.errors:
            err = self._mask("; ".join(w.errors))[:2000]
            self.state.update(key, status="failed", last_error=err, finished_at=iso(utcnow()),
                              elapsed_seconds=f"{elapsed:.1f}")
            self.failures[key] = err
            done_n = len([c for c in chunk_secs if self.state.get(c, "status") == "done"])
            self._audit(key, "failed", 0, 0, f"{done_n}/{len(chunk_secs)}", st.get("method", ""), elapsed,
                        w, err)
            self.results[key] = "failed"
            LOG.error("%s FAILED: %s", key, err)
            return
        files: list[Path] = []
        rows = 0
        sums = []
        for c in chunk_secs:
            cs = self.state.section(c)
            files.append(s.output_dir / cs["file"])
            rows += int(cs.get("rows", "0") or 0)
            sums.append(cs.get("sha256", ""))
        methods = {self.state.get(c, "method") for c in chunk_secs}
        method = "none" if not methods else (methods.pop() if len(methods) == 1 else "mixed")
        upd: dict[str, object] = {
            "rows_exported": rows,
            "files": ",".join(f.name for f in files),
            "checksum_sha256": hashlib.sha256("\n".join(sums).encode()).hexdigest() if sums else "",
            "method": method,
        }
        if files and s.zip_on_complete:
            zip_path = s.output_dir / f"{t.base}_{self.cycle_id}.zip"
            if self._zip_still_valid(st, zip_path, files):
                zip_sha = st["zip_sha256"]
            else:
                missing = [f.name for f in files if not f.exists()]
                if missing:
                    raise ExtractError(f"data files missing before zip: {', '.join(missing)}")
                zip_sha = zip_table(files, zip_path)
                self.state.update(key, zip_file=zip_path.name, zip_sha256=zip_sha)
            upd["zip_file"] = zip_path.name
            upd["zip_sha256"] = zip_sha
            self.zip_files += 1
            if not s.keep_raw_after_zip:
                for f in files:
                    f.unlink(missing_ok=True)
        self.dat_files += len(files)
        if t.cdc_column:
            if w.cdc_to:
                upd["watermark"] = w.cdc_to
            upd["pending_watermark"] = None
        upd.update(status="done", finished_at=iso(utcnow()), elapsed_seconds=f"{elapsed:.1f}", last_error=None)
        self.state.update(key, **upd)
        self.rows_total += rows
        self.results[key] = "done"
        self._audit(key, "done", rows, len(files), f"{len(chunk_secs)}/{len(chunk_secs)}", method, elapsed, w,
                    "no new CDC rows" if w.no_new_rows else "ok")
        LOG.info("%s done: %d rows, %d file(s)", key, rows, len(files))

    @staticmethod
    def _zip_still_valid(st: dict[str, str], zip_path: Path, files: list[Path]) -> bool:
        """True when a previous attempt already wrote and recorded this cycle's verified archive."""
        if st.get("zip_file") != zip_path.name or not st.get("zip_sha256") or not zip_path.exists():
            return False
        if sha256_file(zip_path) != st["zip_sha256"]:
            return False
        with zipfile.ZipFile(zip_path) as zf:
            if zf.testzip() is not None:
                return False
            names = set(zf.namelist())
        return all(f.name in names for f in files)

    def _audit(self, key: str, status: str, rows: int, files: int, chunks: str, method: str,
               elapsed: float, w: TableWork | None, msg: str) -> None:
        wm = ""
        if w is not None and w.src.cdc_column:
            wm = f"{w.cdc_from or '-'}->{(w.cdc_to if status == 'done' else w.cdc_from) or '-'}"
        line = (
            f"{iso(utcnow())} | {self.run_id} | {key} | {status} | rows={rows} | files={files} | "
            f"chunks={chunks} | method={method or '-'} | elapsed={elapsed:.1f}s | watermark={wm or '-'} | "
            f"{self._mask(msg).replace(chr(10), ' ')}\n"
        )
        with self.audit_lock:
            self.s.audit_file.parent.mkdir(parents=True, exist_ok=True)
            with self.s.audit_file.open("a", encoding="utf-8") as fh:
                fh.write(line)

    def audit_skipped(self, key: str) -> None:
        self._audit(key, "skipped", int(self.state.get(key, "rows_exported", "0") or 0), 0, "-",
                    self.state.get(key, "method"), 0.0, None, "already done in this cycle")

    # -------------------------------------------------------------- scheduler
    def run(self, queue: list[SourceTable]) -> None:
        works = {t.key: TableWork(t) for t in queue}
        prep_q = list(works.values())
        chunk_q: list[tuple[TableWork, Chunk]] = []
        outstanding: dict[str, int] = {}
        futures: dict[Future, tuple[str, TableWork, Chunk | None]] = {}

        def fail(w: TableWork, exc: BaseException) -> None:
            msg = self._mask(str(exc)) or exc.__class__.__name__
            w.errors.append(msg)

        with ThreadPoolExecutor(max_workers=self.s.parallel, thread_name_prefix="tdx") as pool:
            try:
                while prep_q or chunk_q or futures:
                    while len(futures) < self.s.parallel and (chunk_q or prep_q):
                        if chunk_q:
                            w, ch = chunk_q.pop(0)
                            futures[pool.submit(self.export_chunk, w, ch)] = ("chunk", w, ch)
                        else:
                            w = prep_q.pop(0)
                            w.started = time.monotonic()
                            futures[pool.submit(self.prepare, w)] = ("prep", w, None)
                    done, _ = wait(list(futures), return_when=FIRST_COMPLETED)
                    for fut in done:
                        kind, w, ch = futures.pop(fut)
                        exc = fut.exception()
                        key = w.src.key
                        if kind == "prep":
                            if exc is not None:
                                fail(w, exc)
                            todo = sorted(w.pending) if exc is None else []
                            if exc is None and not todo:
                                self._safe_finalize(w)
                                continue
                            if exc is not None:
                                self._safe_finalize(w)
                                continue
                            outstanding[key] = len(todo)
                            chunk_q.extend((w, w.chunks[i - 1]) for i in todo)
                        else:
                            assert ch is not None
                            if exc is not None:
                                fail(w, exc)
                                self.state.update(f"{key}/{ch.part}", status="failed",
                                                  last_error=self._mask(str(exc))[:1000])
                            outstanding[key] -= 1
                            if outstanding[key] == 0:
                                self._safe_finalize(w)
            except KeyboardInterrupt:
                self.runner.kill_all()
                pool.shutdown(wait=True, cancel_futures=True)
                self.state.save()
                raise

    def _safe_finalize(self, w: TableWork) -> None:
        try:
            self.finalize(w)
        except Exception as exc:  # noqa: BLE001 - table-level failure, keep the run going
            w.errors.append(self._mask(str(exc)))
            self.finalize(w)


def Decimal_or_int(v: str) -> int:
    from decimal import Decimal, InvalidOperation

    try:
        return int(Decimal(v.strip()))
    except (InvalidOperation, ValueError) as exc:
        raise ExtractError(f"unexpected numeric value {v!r}") from exc


# ------------------------------------------------------------------------- CLI


def new_cycle_id(s: Settings, state: StateStore, now: dt.datetime) -> str:
    """Timestamp cycle id, suffixed when that id was already used (no archive is ever overwritten)."""
    base = now.strftime("%Y%m%dT%H%M%SZ")
    cand, n = base, 1
    while cand == state.get("_run", "cycle_id") or any(s.output_dir.glob(f"*_{cand}.zip")):
        n += 1
        cand = f"{base}-{n}"
    return cand


def build_parser() -> argparse.ArgumentParser:
    root = Path(__file__).resolve().parent.parent
    p = argparse.ArgumentParser(
        prog="teradata_extract.sh",
        description="Extract Teradata 16.20 tables to pipe-delimited files with FastExport/BTEQ.",
    )
    p.add_argument("--config", type=Path, default=root / "config" / "main_config.ini")
    p.add_argument("--tables", default="", help="comma-separated DB.TABLE list to restrict this run")
    p.add_argument("--parallel", default=None, help="override [extract] parallel (N or auto)")
    p.add_argument("--new-cycle", action="store_true", help="reset all tables to pending, keep watermarks")
    p.add_argument("--reset-table", action="append", default=[], metavar="DB.TABLE")
    p.add_argument("--reset-watermark", action="append", default=[], metavar="DB.TABLE")
    p.add_argument("--dry-run", action="store_true", help="validate and print the work queue only")
    p.add_argument("--status", action="store_true", help="print the state summary and exit")
    p.add_argument("-v", "--verbose", action="store_true")
    return p


def setup_logging(s: Settings | None, run_id: str, verbose: bool) -> None:
    LOG.setLevel(logging.DEBUG)
    LOG.handlers.clear()
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(threadName)s %(message)s")
    con = logging.StreamHandler(sys.stderr)
    con.setLevel(logging.DEBUG if verbose else logging.INFO)
    con.setFormatter(fmt)
    LOG.addHandler(con)
    if s is not None:
        fh = logging.FileHandler(s.log_dir / f"extract_{run_id}.log", encoding="utf-8")
        fh.setLevel(logging.DEBUG)
        fh.setFormatter(fmt)
        LOG.addHandler(fh)


def print_status(state: StateStore, sources: list[SourceTable]) -> None:
    print(f"State file : {state.path}")
    print(f"Cycle id   : {state.get('_run', 'cycle_id') or '-'}")
    print(f"Last run   : {state.get('_run', 'last_run_id') or '-'}")
    print(f"{'TABLE':<40} {'STATUS':<12} {'CHUNKS':<9} {'ROWS':>14}  WATERMARK / ERROR")
    for t in sources:
        st = state.section(t.key)
        done = len([x for x in st.get("chunks_done", "").split(",") if x])
        chunks = f"{done}/{st.get('chunk_count', '-')}"
        extra = st.get("last_error", "") if st.get("status") == "failed" else st.get("watermark", "")
        print(f"{t.key:<40} {st.get('status', 'pending'):<12} {chunks:<9} "
              f"{int(st.get('rows_exported', '0') or 0):>14,}  {extra}")


def summary(ex: Extractor | None, run_id: str, queued: int, skipped: int, started: float,
            results: dict[str, str], failures: dict[str, str]) -> str:
    done = sum(1 for v in results.values() if v == "done")
    failed = sum(1 for v in results.values() if v == "failed")
    pending = queued - done - failed
    lines = [
        "=" * 20 + " TERADATA EXTRACT SUMMARY " + "=" * 20,
        f"Run id        : {run_id}",
        f"Tables        : done={done} failed={failed} pending={pending} "
        f"(queued={queued}, skipped already done={skipped})",
        f"Rows exported : {ex.rows_total if ex else 0:,}",
        f"Files written : {ex.dat_files if ex else 0} (.dat) / {ex.zip_files if ex else 0} (.zip)",
        f"Elapsed       : {fmt_elapsed(time.monotonic() - started)}",
    ]
    for k, v in failures.items():
        lines.append(f"FAILED        : {k} - {v}")
    lines.append("=" * 66)
    return "\n".join(lines)


def _sigterm(signum, frame):  # noqa: ARG001
    raise KeyboardInterrupt


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    started = time.monotonic()
    now = utcnow()
    run_id = f"{now.strftime('%Y%m%dT%H%M%SZ')}-{os.getpid()}"
    try:
        s = load_settings(args.config, args.parallel)
        for d in (s.output_dir, s.metadata_dir, s.log_dir, s.work_dir, s.process_state_file.parent):
            d.mkdir(parents=True, exist_ok=True)
        setup_logging(None if args.status or args.dry_run else s, run_id, args.verbose)
        sources = load_source_tables(s.source_tables_file)
        by_key = {t.key: t for t in sources}
        wanted = [x.strip().upper() for x in args.tables.split(",") if x.strip()]
        unknown = [x for x in wanted + [r.upper() for r in args.reset_table + args.reset_watermark]
                   if x not in by_key]
        if unknown:
            raise ConfigError(f"table(s) not defined in {s.source_tables_file.name}: {', '.join(unknown)}")
        lock_fh = None
        if not args.status:
            lock_fh = s.lock_file.open("a+")
            try:
                fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as exc:
                raise ConfigError(f"another teradata_extract run holds {s.lock_file}") from exc
        state = StateStore(s.process_state_file, dry_run=args.dry_run)
        changed = False
        if args.new_cycle:
            for key in state.table_keys():
                state.reset_table(key)
                state.update(key, save=False, pending_watermark=None)
            state.update("_run", save=False, cycle_id=new_cycle_id(s, state, now))
            changed = True
        for k in args.reset_table:
            state.reset_table(k.upper())
            changed = True
        for k in args.reset_watermark:
            state.reset_table(k.upper(), clear_watermark=True)
            changed = True
        if not state.get("_run", "cycle_id"):
            state.update("_run", save=False, cycle_id=new_cycle_id(s, state, now))
            changed = True
        if changed and not args.status:
            state.save()
        elif changed and args.status and not args.dry_run:
            state.save()
        if args.status:
            print_status(state, sources)
            return EXIT_OK

        creds = load_credentials(s)
        for name, exe in (("fexp", s.fexp_path), ("bteq", s.bteq_path)):
            if shutil.which(exe) is None:
                raise ConfigError(f"{name} executable not found: {exe}")
        selected = [by_key[k] for k in wanted] if wanted else sources
        queue = [t for t in selected if state.get(t.key, "status") != "done"]
        skipped = [t for t in selected if state.get(t.key, "status") == "done"]
        if args.dry_run:
            print(f"Credentials : {creds.source} (user {creds.user})")
            print(f"Tools       : fexp={shutil.which(s.fexp_path)} bteq={shutil.which(s.bteq_path)}")
            print(f"Parallel    : {s.parallel} job(s), max_sessions={s.max_sessions}")
            print(f"Cycle id    : {state.get('_run', 'cycle_id')}")
            print(f"Work queue  : {len(queue)} table(s), {len(skipped)} already done")
            for t in queue:
                st = state.section(t.key)
                print(f"  {t.key:<40} status={st.get('status', 'pending'):<8} "
                      f"cdc={t.cdc_column or '-'} watermark={st.get('watermark', '-') or '-'}")
            return EXIT_OK
        if s.connect_check:
            try:
                socket.create_connection((s.host, s.port), timeout=10).close()
            except OSError as exc:
                raise ConfigError(f"cannot reach {s.host}:{s.port}: {exc}") from exc
    except ConfigError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return EXIT_CONFIG

    LOG.info("run %s: %d table(s) queued, %d already done, parallel=%d, credentials from %s",
             run_id, len(queue), len(skipped), s.parallel, creds.source)
    state.update("_run", last_run_id=run_id, last_run_started=iso(now), last_run_finished=None)
    ex = Extractor(s, creds, state, run_id)
    for t in skipped:
        ex.audit_skipped(t.key)
    old = signal.signal(signal.SIGTERM, _sigterm)
    rc = EXIT_OK
    try:
        ex.run(queue)
    except KeyboardInterrupt:
        LOG.error("interrupted; state saved, rerun to resume")
        rc = EXIT_INTERRUPTED
    finally:
        signal.signal(signal.SIGTERM, old)
        state.update("_run", last_run_finished=iso(utcnow()))
    print(summary(ex, run_id, len(queue), len(skipped), started, ex.results, ex.failures))
    if rc == EXIT_OK and ex.failures:
        rc = EXIT_FAILED
    if lock_fh is not None:
        lock_fh.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
