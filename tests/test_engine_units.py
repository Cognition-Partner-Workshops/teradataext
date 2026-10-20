"""White-box unit tests of src/extract.py helpers (stdlib only)."""
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from helpers import ENGINE, TdxEnv, read_ini

if ENGINE.exists():
    _spec = importlib.util.spec_from_file_location("tdx_extract", ENGINE)
    tdx = importlib.util.module_from_spec(_spec)
    sys.modules["tdx_extract"] = tdx
    _spec.loader.exec_module(tdx)


def _bteq_rec(payload):
    return (len(payload) + 2).to_bytes(2, "little") + len(payload).to_bytes(2, "little") + payload + b"\n"


def _fexp_rec(payload):
    return len(payload).to_bytes(2, "little") + payload + b"\n"


@unittest.skipUnless(ENGINE.exists(), "src/extract.py not present yet")
class TestHelpers(unittest.TestCase):
    def test_field_count_custom_escape(self):
        self.assertEqual(tdx.field_count(b"a!|b|second", b"|", b"!"), 2)
        self.assertEqual(tdx.field_count(b"a\\|b|second", b"|"), 2)

    def test_check_where(self):
        self.assertIsNone(tdx.check_where("STATUS <> 'X;--/*' AND ID > 5"))
        self.assertIsNone(tdx.check_where("NAME = 'O''Brien'"))
        for bad in ("1=1; DELETE FROM T", "1=1 -- x", "1=1 /* x */", "NAME = 'open"):
            self.assertIsNotNone(tdx.check_where(bad), bad)

    def test_mask_text_variants_and_logon(self):
        out = tdx.mask_text(".LOGON host/user,Secr3t\nerr SECR3T and secr3t", "Secr3t")
        self.assertNotIn("ecr3t", out.lower())
        self.assertIn(".LOGON host/user,", out)
        self.assertIn(".logon h/u,", tdx.mask_text(".logon h/u,other-pw-form", "Secr3t").lower())
        self.assertNotIn("other-pw-form", tdx.mask_text(".logon h/u,other-pw-form", "Secr3t"))

    def test_mask_text_fragments(self):
        out = tdx.mask_text("bad logon: 'LongSecret' ... 'Secret9'", "LongSecret99")
        self.assertNotIn("LongSecret", out)
        self.assertNotIn("Secret9", out)

    def _stream(self, data, tool):
        with tempfile.TemporaryDirectory() as d:
            raw = Path(d) / "x.raw"
            raw.write_bytes(data)
            out = io.BytesIO()
            recs = []
            n, layout = tdx.stream_raw_export(raw, out, tool, recs.append, recs.clear)
            return n, layout, recs

    def test_stream_raw_export_layouts(self):
        rows = [b"\\N", b"a|b", b""]
        n, layout, recs = self._stream(b"".join(_bteq_rec(r) for r in rows), "bteq")
        self.assertEqual((n, layout, recs), (3, "reclen+varchar+eor", rows))
        n, layout, recs = self._stream(b"".join(_fexp_rec(r) for r in rows), "fexp")
        self.assertEqual((n, layout, recs), (3, "varchar+eor", rows))
        self.assertEqual(self._stream(b"", "fexp")[:2], (0, "empty"))

    def test_stream_raw_export_rejects_garbage(self):
        with self.assertRaises(tdx.ExtractError):
            self._stream(b"\xff\xff\x01", "fexp")

    def test_cdc_window_pred_initial_includes_nulls(self):
        col = tdx.Column(position=1, name="UPD", type_code="I", length=4, total_digits=0, frac_digits=0,
                         nullable=True, char_type=0)
        self.assertIn('"UPD" IS NULL', tdx.cdc_window_pred(col, "", "10"))
        self.assertNotIn("IS NULL", tdx.cdc_window_pred(col, "5", "10"))
        self.assertEqual(tdx.cdc_window_pred(col, "", ""), "")

    def test_wrap_fields_keeps_identifier_spaces(self):
        sql = tdx.wrap_fields(["ColumnId", "ColumnName"], untrimmed=("ColumnName",))
        self.assertIn("TRIM(CAST(ColumnId", sql)
        self.assertNotIn("TRIM(CAST(ColumnName", sql)

    def test_new_cycle_id_never_reuses_archive_name(self):
        import datetime as dt
        now = dt.datetime(2026, 1, 2, 3, 4, 5, tzinfo=dt.timezone.utc)
        with tempfile.TemporaryDirectory() as d:
            s = SimpleNamespace(output_dir=Path(d))
            state = SimpleNamespace(get=lambda sec, key, default="": "20260102T030405Z")
            self.assertEqual(tdx.new_cycle_id(s, state, now), "20260102T030405Z-2")
            (Path(d) / "t_20260102T030405Z-2.zip").write_bytes(b"")
            self.assertEqual(tdx.new_cycle_id(s, state, now), "20260102T030405Z-3")


@unittest.skipUnless(ENGINE.exists(), "src/extract.py not present yet")
class TestResumeAfterZip(unittest.TestCase):
    def test_interrupted_cleanup_resumes_from_recorded_zip(self):
        env = TdxEnv()
        self.addCleanup(env.cleanup)
        rc, out, err = env.run()
        self.assertEqual(rc, 0, out + err)
        key = "TDX_DB.BIG"
        state = env.state()
        zip_name, zip_sha = state[key]["zip_file"], state[key]["zip_sha256"]
        # Simulate a crash after the zip was recorded and raw files deleted, before status=done
        text = env.state_path.read_text(encoding="utf-8")
        head = "".join(ln for ln in text.splitlines(True) if ln.startswith("#"))
        cp = read_ini(env.state_path)
        cp[key]["status"] = "in_progress"
        buf = io.StringIO()
        cp.write(buf)
        env.state_path.write_text(head + buf.getvalue(), encoding="utf-8")
        env.reset_fake_log()
        rc, out, err = env.run("--tables", key)
        self.assertEqual(rc, 0, out + err)
        state = env.state()
        self.assertEqual(state[key]["status"], "done")
        self.assertEqual((state[key]["zip_file"], state[key]["zip_sha256"]), (zip_name, zip_sha))
        self.assertEqual(env.requests(query="export"), [])


if __name__ == "__main__":
    unittest.main()
