"""Test helpers: isolated utility roots, CLI runner and on-disk output readers (stdlib only)."""
import configparser
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent
FAKES_DIR = TESTS_DIR / "fakes"
FIXTURES_DIR = TESTS_DIR / "fixtures"
ENTRYPOINT = REPO_ROOT / "teradata_extract.sh"
ENGINE = REPO_ROOT / "src" / "extract.py"

TD_USER = "tdx_test_user"
TD_PASS = "Zq9-Secr3t-Pw!x"

DEFAULT_TABLES = [
    ("mixed", "TDX_DB", "MIXED", {}),
    ("big", "TDX_DB", "BIG", {}),
    ("cdc", "TDX_DB", "CDC", {"cdc_column": "UPDATED_TS"}),
]

DEFAULT_CONFIG = {
    "teradata": {
        "host": "tdfake.example.com",
        "port": "1025",
        "logmech": "",
        "credentials_file": "",
        "fexp_path": "fexp",
        "bteq_path": "bteq",
        "session_charset": "ASCII",
        "logtable_database": "",
        "connect_check": "false",
    },
    "paths": {
        "base_dir": "",
        "output_dir": "data",
        "metadata_dir": "metadata",
        "log_dir": "logs",
        "work_dir": "work",
        "source_tables_file": "config/source_tables.ini",
        "process_state_file": "config/process_state.ini",
    },
    "extract": {
        "file_format": "pipe-delimited",
        "parallel": "1",
        "max_sessions": "4",
        "min_sessions": "1",
        "chunk_threshold_rows": "10",
        "chunk_rows": "7",
        "max_chunks": "64",
        "small_table_rows": "5",
        "row_estimate": "stats",
        "char_trim": "right",
        "lob_max_length": "1000",
        "max_row_length": "64000",
        "zip_on_complete": "true",
        "keep_raw_after_zip": "false",
        "retry_attempts": "2",
        "retry_delay_seconds": "0",
        "session_limit_errors": "2633,3130",
        "session_limit_patterns": "Too many load/unload tasks,session limit,No more sessions",
        "bteq_fallback": "true",
        "job_timeout_seconds": "0",
        "log_tool_output": "masked",
    },
    "format": {
        "delimiter": "|",
        "null_sentinel": "\\N",
        "empty_sentinel": "\\E",
        "escape_char": "\\",
        "big_decimal_quote": '"',
        "big_decimal_threshold": "18",
    },
}


def read_ini(path):
    cp = configparser.ConfigParser(interpolation=None)
    cp.optionxform = str
    with open(path, encoding="utf-8") as fh:
        cp.read_file(fh)
    return cp


def write_ini(path, sections):
    cp = configparser.ConfigParser(interpolation=None)
    cp.optionxform = str
    for name, values in sections.items():
        cp[name] = {k: str(v) for k, v in values.items()}
    with open(path, "w", encoding="utf-8") as fh:
        cp.write(fh)


def split_records(data):
    """Split .dat text into records: LF ends a record unless escaped by a preceding backslash."""
    if isinstance(data, bytes):
        data = data.decode("utf-8")
    records, cur, i = [], [], 0
    while i < len(data):
        ch = data[i]
        if ch == "\\" and i + 1 < len(data):
            cur.append(data[i:i + 2])
            i += 2
            continue
        if ch == "\n":
            records.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    if cur:
        records.append("".join(cur))
    return records


def fixture_lines(fixture, key):
    for name, spec in fixture["tables"].items():
        if name.upper() == key.upper():
            return [r["line"] for r in spec.get("rows", [])]
    raise KeyError(key)


class TdxEnv:
    """An isolated utility root (``<tmp>/root``) plus fake-tool data (``<tmp>/fake``)."""

    def __init__(self, tables=None, config=None, fixture="basic.json", credentials="env"):
        self._tmp = tempfile.TemporaryDirectory(prefix="tdx_test_")
        self.tmp = Path(self._tmp.name)
        self.root = self.tmp / "root"
        self.fake = self.tmp / "fake"
        for d in (self.root / "config", self.fake):
            d.mkdir(parents=True)
        self.config_path = self.root / "config" / "main_config.ini"
        self.tables_path = self.root / "config" / "source_tables.ini"
        self.state_path = self.root / "config" / "process_state.ini"
        self.fixture_path = self.fake / "fixture.json"
        self.fake_log = self.fake / "calls.jsonl"
        shutil.copyfile(FIXTURES_DIR / fixture, self.fixture_path)
        self.config = json.loads(json.dumps(DEFAULT_CONFIG))
        for section, values in (config or {}).items():
            self.config.setdefault(section, {}).update({k: str(v) for k, v in values.items()})
        self.tables = list(DEFAULT_TABLES if tables is None else tables)
        self.credentials = credentials
        self.write_config()
        self.write_tables()

    def cleanup(self):
        self._tmp.cleanup()

    # ----- configuration -------------------------------------------------
    def write_config(self):
        write_ini(self.config_path, self.config)

    def set_config(self, section, key, value):
        self.config.setdefault(section, {})[key] = str(value)
        self.write_config()

    def write_tables(self):
        sections = {}
        for label, db, table, extra in self.tables:
            sections[label] = dict({"database": db, "table": table}, **extra)
        write_ini(self.tables_path, sections)

    def write_credentials_file(self, mode=0o600, user=TD_USER, password=TD_PASS):
        path = self.fake / "td_credentials.ini"
        write_ini(path, {"credentials": {"user": user, "password": password}})
        os.chmod(path, mode)
        self.set_config("teradata", "credentials_file", str(path))
        return path

    # ----- fixture -------------------------------------------------------
    def fixture(self):
        with open(self.fixture_path, encoding="utf-8") as fh:
            return json.load(fh)

    def save_fixture(self, data):
        with open(self.fixture_path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=1)

    def update_table(self, key, **values):
        data = self.fixture()
        data["tables"][key].update(values)
        self.save_fixture(data)

    def add_failure(self, **failure):
        data = self.fixture()
        data.setdefault("failures", []).append(failure)
        self.save_fixture(data)

    def clear_failures(self):
        data = self.fixture()
        data["failures"] = []
        self.save_fixture(data)

    # ----- running -------------------------------------------------------
    def env(self, credentials=None):
        env = {k: v for k, v in os.environ.items() if k not in ("TD_USER", "TD_PASS")}
        env.update({
            "TDX_FEXP": str(FAKES_DIR / "fexp"),
            "TDX_BTEQ": str(FAKES_DIR / "bteq"),
            "TDX_FAKE_FIXTURE": str(self.fixture_path),
            "TDX_FAKE_LOG": str(self.fake_log),
            "TDX_PYTHON": env.get("TDX_PYTHON") or sys.executable,
        })
        if (credentials or self.credentials) == "env":
            env["TD_USER"] = TD_USER
            env["TD_PASS"] = TD_PASS
        return env

    def run(self, *args, credentials=None, extra_env=None, timeout=180):
        env = self.env(credentials)
        env.update(extra_env or {})
        cmd = [str(ENTRYPOINT), "--config", str(self.config_path)] + [str(a) for a in args]
        proc = subprocess.run(cmd, env=env, cwd=str(self.tmp), capture_output=True, text=True, timeout=timeout)
        return proc.returncode, proc.stdout, proc.stderr

    # ----- fake call log -------------------------------------------------
    def fake_calls(self):
        if not self.fake_log.exists():
            return []
        with open(self.fake_log, encoding="utf-8") as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def reset_fake_log(self):
        if self.fake_log.exists():
            self.fake_log.unlink()

    def requests(self, query=None, table=None):
        """Marked requests received by the fakes: list of (tool, marker dict)."""
        sys.path.insert(0, str(FAKES_DIR))
        import _tdxfake
        out = []
        for call in self.fake_calls():
            for req in _tdxfake.parse_events(call["script"]):
                m = req["marker"]
                if query and m.get("query") != query:
                    continue
                if table and ("%s.%s" % (m.get("db", ""), m.get("table", ""))).upper() != table.upper():
                    continue
                out.append((call["tool"], m))
        return out

    # ----- outputs -------------------------------------------------------
    def state(self):
        return read_ini(self.state_path)

    def meta(self, db, table):
        return read_ini(self.root / "metadata" / ("%s_%s.meta.ini" % (db.lower(), table.lower())))

    def audit_lines(self):
        path = self.root / "metadata" / "audit.log"
        if not path.exists():
            return []
        return [ln for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip()]

    def data_dir(self):
        return self.root / "data"

    def zip_path(self, key):
        zip_file = self.state()[key].get("zip_file", "")
        return self.data_dir() / zip_file if zip_file else None

    def zip_records(self, key):
        """All records of all .dat members of the table's zip, per member name."""
        with zipfile.ZipFile(self.zip_path(key)) as zf:
            return {n: split_records(zf.read(n)) for n in zf.namelist() if n.endswith(".dat")}

    def files_containing(self, needle):
        hits = []
        data = needle.encode("utf-8")
        for path in self.root.rglob("*"):
            if path.is_file():
                try:
                    content = path.read_bytes()
                except OSError:
                    continue
                if data in content:
                    hits.append(path)
                elif path.suffix == ".zip":
                    with zipfile.ZipFile(path) as zf:
                        if any(data in zf.read(n) for n in zf.namelist()):
                            hits.append(path)
        return hits
