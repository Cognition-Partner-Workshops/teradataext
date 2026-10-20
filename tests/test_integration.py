"""Black-box integration tests of teradata_extract.sh driven by the fake fexp/bteq binaries.

Only the CLI and the on-disk outputs defined in docs/DESIGN.md are used.
"""
import hashlib
import unittest
import zipfile

from helpers import ENGINE, TD_PASS, TdxEnv, fixture_lines

MIXED, BIG, CDC, LOB = "TDX_DB.MIXED", "TDX_DB.BIG", "TDX_DB.CDC", "TDX_DB.LOB_BIG"
WM1 = "2024-03-01 00:00:00.000000"
WM2 = "2024-04-15 00:00:00.000000"


def chunk_list(value):
    return sorted(int(x) for x in value.split(",") if x.strip())


@unittest.skipUnless(ENGINE.exists(), "src/extract.py not present yet")
class IntegrationBase(unittest.TestCase):
    tables = None
    config = None

    def setUp(self):
        self.env = TdxEnv(tables=self.tables, config=self.config)
        self.addCleanup(self.env.cleanup)

    def run_ok(self, *args):
        rc, out, err = self.env.run(*args)
        self.assertEqual(rc, 0, "stdout:\n%s\nstderr:\n%s" % (out, err))
        return out

    def export_requests(self, table):
        return [m for _, m in self.env.requests(query="export", table=table)]

    def all_records(self, key):
        recs = []
        for member in self.env.zip_records(key).values():
            recs += member
        return recs


class TestFullRun(IntegrationBase):
    def test_full_run_success(self):
        out = self.run_ok()
        env = self.env
        self.assertIn("TERADATA EXTRACT SUMMARY", out)
        self.assertRegex(out, r"Tables\s*:\s*done=3 failed=0 pending=0")
        state = env.state()
        fixture = env.fixture()
        cycle = state["_run"]["cycle_id"]
        self.assertTrue(cycle)
        expected_rows = {MIXED: 4, BIG: 25, CDC: 3}
        for key, rows in expected_rows.items():
            sec = state[key]
            self.assertEqual(sec["status"], "done", key)
            self.assertEqual(int(sec["rows_exported"]), rows, key)
            self.assertRegex(sec.get("checksum_sha256", ""), r"^[0-9a-f]{64}$")
            stem = key.lower().replace(".", "_")
            self.assertEqual(sec["zip_file"], "%s_%s.zip" % (stem, cycle))
            zpath = env.zip_path(key)
            self.assertTrue(zpath.exists(), zpath)
            self.assertEqual(sec.get("zip_sha256"), hashlib.sha256(zpath.read_bytes()).hexdigest())
            with zipfile.ZipFile(zpath) as zf:
                self.assertIsNone(zf.testzip())
                names = zf.namelist()
            for f in sec["files"].split(","):
                self.assertIn(f.strip(), names)
            self.assertEqual(len(self.all_records(key)), rows)
        self.assertEqual(list(env.data_dir().glob("*.dat")), [])
        self.assertEqual(list(env.data_dir().glob("*.raw")), [])
        # MIXED is unchunked: one member with exactly the fixture lines
        mixed_members = env.zip_records(MIXED)
        self.assertEqual(list(mixed_members), ["tdx_db_mixed.dat"])
        self.assertEqual(mixed_members["tdx_db_mixed.dat"], fixture_lines(fixture, MIXED))
        with zipfile.ZipFile(env.zip_path(MIXED)) as zf:
            raw = zf.read("tdx_db_mixed.dat").decode("utf-8")
        self.assertEqual(raw, "\n".join(fixture_lines(fixture, MIXED)) + "\n")
        self.assertEqual(state[MIXED]["chunk_strategy"], "none")
        self.assertEqual(state[MIXED]["method"], "bteq")

    def test_meta_files(self):
        self.run_ok()
        for key in (MIXED, BIG, CDC):
            db, table = key.split(".")
            self.assertTrue(self.env.meta(db, table).has_section("table"))
        meta = self.env.meta("TDX_DB", "MIXED")
        self.assertEqual(meta["table"]["column_count"], "8")
        self.assertEqual(meta["table"]["timezone_policy"], "UTC")
        cols = [s for s in meta.sections() if s.startswith("column.")]
        self.assertEqual(cols, ["column.%03d" % i for i in range(1, 9)])
        expected = {
            "ID": ("int_text", "INTEGER"),
            "AMT": ("decimal_text", "DECIMAL(10,2)"),
            "BIG_AMT": ("decimal_quoted", "DECIMAL(38,4)"),
            "NAME": ("escaped_text", "VARCHAR(50)"),
            "BIZ_DATE": ("iso_date", "DATE"),
            "CREATED_TS": ("iso_timestamp", "TIMESTAMP"),
            "EVENT_TSZ": ("utc_iso_timestamp", "TIMESTAMPTZ"),
            "PAYLOAD": ("hex", "VARBYTE(16)"),
        }
        by_name = {meta[s]["name"]: meta[s] for s in cols}
        for name, (enc, rs) in expected.items():
            self.assertEqual(by_name[name]["output_encoding"], enc, name)
            self.assertEqual(by_name[name]["redshift_type"], rs, name)
        self.assertEqual(by_name["ID"]["position"], "1")
        self.assertIn("source_timezone", by_name["EVENT_TSZ"])

    def test_audit_and_state_header(self):
        self.run_ok()
        text = self.env.state_path.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("# THIS FILE IS MANAGED BY teradata_extract - DO NOT EDIT."), text[:200])
        lines = self.env.audit_lines()
        self.assertEqual(len(lines), 3)
        run_id = self.env.state()["_run"]["last_run_id"]
        for key, rows in ((MIXED, 4), (BIG, 25), (CDC, 3)):
            line = next(ln for ln in lines if " | %s | " % key in ln)
            fields = [f.strip() for f in line.split(" | ")]
            self.assertEqual(fields[1], run_id)
            self.assertEqual(fields[3], "done")
            self.assertEqual(fields[4], "rows=%d" % rows)

    def test_done_tables_skipped_on_rerun(self):
        self.run_ok()
        self.env.reset_fake_log()
        out = self.run_ok()
        self.assertEqual(self.env.requests(query="export"), [])
        self.assertRegex(out, r"skipped already done=3")

    def test_password_never_written(self):
        self.run_ok()
        self.assertEqual(self.env.files_containing(TD_PASS), [])
        scripts = list((self.env.root / "work").glob("*.*"))
        self.assertTrue(scripts)
        self.assertTrue(any("********" in p.read_text(errors="replace") for p in scripts if p.is_file()))
        self.assertTrue(any(TD_PASS in c["script"] for c in self.env.fake_calls()),
                        "password must reach the tools via stdin")

    def test_dry_run_and_status_make_no_calls(self):
        rc, out, err = self.env.run("--dry-run")
        self.assertEqual(rc, 0, out + err)
        rc, out, err = self.env.run("--status")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.env.fake_calls(), [])

    def test_tables_filter(self):
        self.run_ok("--tables", "tdx_db.mixed")
        state = self.env.state()
        self.assertEqual(state[MIXED]["status"], "done")
        self.assertEqual(self.export_requests(BIG), [])


class TestKeepRaw(IntegrationBase):
    config = {"extract": {"keep_raw_after_zip": "true"}}

    def test_keep_raw_after_zip(self):
        self.run_ok()
        dats = sorted(p.name for p in self.env.data_dir().glob("*.dat"))
        self.assertIn("tdx_db_mixed.dat", dats)
        self.assertTrue(any(n.startswith("tdx_db_big.part") for n in dats))
        self.assertTrue(list(self.env.data_dir().glob("*.zip")))


class TestChunking(IntegrationBase):
    tables = [("big", "TDX_DB", "BIG", {})]

    def test_chunked_union_equals_fixture(self):
        self.run_ok()
        sec = self.env.state()[BIG]
        n = int(sec["chunk_count"])
        self.assertGreater(n, 1)
        self.assertNotEqual(sec["chunk_strategy"], "none")
        self.assertEqual(chunk_list(sec["chunks_done"]), list(range(1, n + 1)))
        members = self.env.zip_records(BIG)
        self.assertEqual(sorted(members), ["tdx_db_big.part%03d.dat" % i for i in range(1, n + 1)])
        union = [r for recs in members.values() for r in recs]
        self.assertEqual(sorted(union), sorted(fixture_lines(self.env.fixture(), BIG)))
        state = self.env.state()
        for i in range(1, n + 1):
            part = state["%s/part%03d" % (BIG, i)]
            self.assertEqual(part["status"], "done")
            self.assertRegex(part["sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(sum(int(state["%s/part%03d" % (BIG, i)]["rows"]) for i in range(1, n + 1)), 25)

    def test_resume_reruns_only_failed_chunk(self):
        self.env.add_failure(table=BIG, query="export", chunk=2, times=1, code=3707,
                             message="Syntax error, expected something")
        rc, out, err = self.env.run()
        self.assertEqual(rc, 1, out + err)
        sec = self.env.state()[BIG]
        n = int(sec["chunk_count"])
        self.assertEqual(sec["status"], "failed")
        self.assertTrue(sec.get("last_error"))
        self.assertEqual(chunk_list(sec["chunks_done"]), [i for i in range(1, n + 1) if i != 2])
        self.assertIn("FAILED", out)
        self.env.reset_fake_log()
        self.run_ok()
        reqs = self.export_requests(BIG)
        self.assertEqual(len(reqs), 1, reqs)
        self.assertEqual(reqs[0]["chunk"].split("/")[0], "2")
        sec = self.env.state()[BIG]
        self.assertEqual(sec["status"], "done")
        self.assertEqual(chunk_list(sec["chunks_done"]), list(range(1, n + 1)))
        self.assertEqual(int(sec["rows_exported"]), 25)
        self.assertEqual(sorted(self.all_records(BIG)), sorted(fixture_lines(self.env.fixture(), BIG)))

    def test_session_limit_retry(self):
        self.env.add_failure(table=BIG, query="export", chunk=1, times=1, code=2633,
                             message="Too many load/unload tasks running now")
        self.run_ok()
        reqs = [m for m in self.export_requests(BIG) if m["chunk"].split("/")[0] == "1"]
        self.assertEqual(len(reqs), 2)
        self.assertEqual(self.env.state()[BIG]["status"], "done")

    def test_bteq_fallback_after_retries(self):
        self.env.add_failure(table=BIG, tool="fexp", query="export", chunk=1, times=-1, code=2633,
                             message="Too many load/unload tasks running now")
        self.run_ok()
        state = self.env.state()
        self.assertEqual(state[BIG]["status"], "done")
        self.assertEqual(state[BIG + "/part001"]["method"], "bteq")
        calls = [(tool, m) for tool, m in self.env.requests(query="export", table=BIG)
                 if m["chunk"].split("/")[0] == "1"]
        self.assertEqual([t for t, _ in calls], ["fexp"] * 3 + ["bteq"])  # 1 + retry_attempts(2), then fallback
        self.assertEqual(int(state[BIG]["rows_exported"]), 25)


class TestCdc(IntegrationBase):
    tables = [("cdc", "TDX_DB", "CDC", {"cdc_column": "UPDATED_TS"})]

    def records(self):
        return sorted(self.all_records(CDC))

    def test_incremental_cycles(self):
        lines = fixture_lines(self.env.fixture(), CDC)
        self.run_ok()
        sec = self.env.state()[CDC]
        self.assertEqual(sec["watermark"], WM1)
        self.assertEqual(int(sec["rows_exported"]), 3)
        self.assertEqual(self.records(), sorted(lines[:3]))
        self.env.update_table(CDC, cdc_max=WM2)
        self.env.reset_fake_log()
        self.run_ok("--new-cycle")
        sec = self.env.state()[CDC]
        self.assertEqual(sec["status"], "done")
        self.assertEqual(sec["watermark"], WM2)
        self.assertEqual(int(sec["rows_exported"]), 2)
        self.assertEqual(self.records(), sorted(lines[3:]))
        reqs = self.export_requests(CDC)
        self.assertTrue(reqs and all(m.get("cdc_gt") == WM1 and m.get("cdc_le") == WM2 for m in reqs), reqs)

    def test_no_new_rows_keeps_watermark(self):
        self.run_ok()
        self.assertEqual(self.env.state()[CDC]["watermark"], WM1)
        self.env.update_table(CDC, cdc_max=None)
        self.run_ok("--new-cycle")
        sec = self.env.state()[CDC]
        self.assertEqual(sec["status"], "done")
        self.assertEqual(int(sec["rows_exported"]), 0)
        self.assertEqual(sec["watermark"], WM1)


class TestLob(IntegrationBase):
    tables = [("mixed", "TDX_DB", "MIXED", {}), ("lob", "TDX_DB", "LOB_BIG", {}), ("big", "TDX_DB", "BIG", {})]

    def test_lob_over_limit_fails_table(self):
        rc, out, err = self.env.run()
        self.assertEqual(rc, 1, out + err)
        state = self.env.state()
        self.assertEqual(state[LOB]["status"], "failed")
        self.assertIn("lob_max_length", state[LOB]["last_error"])
        self.assertEqual(state[MIXED]["status"], "done")
        self.assertEqual(state[BIG]["status"], "done")
        self.assertRegex(out, r"done=2 failed=1")
        self.assertIn("FAILED", out)
        self.assertIn(LOB, out)
        self.assertEqual(self.export_requests(LOB), [])
        self.assertTrue(any(" | %s | failed | " % LOB in ln for ln in self.env.audit_lines()))


class TestCredentials(IntegrationBase):
    tables = [("mixed", "TDX_DB", "MIXED", {})]

    def test_no_credentials(self):
        rc, out, err = self.env.run(credentials="none")
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(self.env.fake_calls(), [])

    def test_only_user_set(self):
        rc, out, err = self.env.run(credentials="none", extra_env={"TD_USER": "someone"})
        self.assertEqual(rc, 2, out + err)

    def test_credentials_file_too_open(self):
        self.env.write_credentials_file(mode=0o644)
        rc, out, err = self.env.run(credentials="none")
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(self.env.fake_calls(), [])

    def test_credentials_file_0600(self):
        self.env.write_credentials_file(mode=0o600)
        rc, out, err = self.env.run(credentials="none")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.env.state()[MIXED]["status"], "done")
        self.assertEqual(self.env.files_containing(TD_PASS), [])
        self.assertTrue(all(TD_PASS in c["script"] for c in self.env.fake_calls()))


if __name__ == "__main__":
    unittest.main()
