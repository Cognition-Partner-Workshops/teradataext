"""Direct tests of the fake fexp/bteq binaries (no engine required)."""
import json
import os
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

from helpers import FAKES_DIR, FIXTURES_DIR, TD_PASS

LOGON = ".LOGON tdfake/user,%s;\n" % TD_PASS


def parse_text(data):
    recs, i = [], 0
    while i < len(data):
        (n,) = struct.unpack_from("<H", data, i)
        recs.append(data[i + 2:i + 2 + n].decode("utf-8"))
        assert data[i + 2 + n:i + 3 + n] == b"\n"
        i += 3 + n
    return recs


def parse_bteq(data):
    recs, i = [], 0
    while i < len(data):
        rec_len, n = struct.unpack_from("<HH", data, i)
        assert rec_len == n + 2
        recs.append(data[i + 4:i + 4 + n].decode("utf-8"))
        assert data[i + 4 + n:i + 5 + n] == b"\n"
        i += 5 + n
    return recs


class FakeTestBase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="tdx_fake_")
        self.tmp = Path(self._tmp.name)
        self.fixture = self.tmp / "fixture.json"
        shutil.copyfile(FIXTURES_DIR / "basic.json", self.fixture)
        self.log = self.tmp / "calls.jsonl"

    def tearDown(self):
        self._tmp.cleanup()

    def edit_fixture(self, fn):
        data = json.loads(self.fixture.read_text())
        fn(data)
        self.fixture.write_text(json.dumps(data))

    def run_tool(self, tool, script):
        env = dict(os.environ, TDX_FAKE_FIXTURE=str(self.fixture), TDX_FAKE_LOG=str(self.log))
        p = subprocess.run([str(FAKES_DIR / tool)], input=script.encode("utf-8"), env=env,
                           capture_output=True, timeout=60)
        return p.returncode, p.stdout.decode("utf-8")

    def bteq(self, *requests):
        lines = [".SET SESSION CHARSET 'ASCII';", LOGON.strip(), ".SET ERROROUT STDOUT;"]
        outs = []
        for i, marker in enumerate(requests):
            out = self.tmp / ("out%d.raw" % i)
            outs.append(out)
            lines += [".EXPORT DATA FILE = %s;" % out, "/* TDX %s */ SELECT 1;" % marker,
                      ".IF ERRORCODE <> 0 THEN .QUIT ERRORCODE;", ".EXPORT RESET;"]
        lines += [".LOGOFF;", ".QUIT 0;"]
        rc, out = self.run_tool("bteq", "\n".join(lines) + "\n")
        return rc, out, outs

    def fexp(self, marker, out=None):
        out = out or self.tmp / "fexp.raw"
        script = (".LOGTABLE TDX_DB.tdx_lt_abc;\n" + LOGON + ".BEGIN EXPORT SESSIONS 4 TENACITY 0;\n"
                  ".EXPORT OUTFILE %s FORMAT TEXT MODE RECORD;\n/* TDX %s */ SELECT x FROM t;\n"
                  ".END EXPORT;\n.LOGOFF;\n" % (out, marker))
        rc, text = self.run_tool("fexp", script)
        return rc, text, out


class TestFakeBasics(FakeTestBase):
    def test_executable(self):
        for tool in ("fexp", "bteq"):
            self.assertTrue(os.access(FAKES_DIR / tool, os.X_OK), tool)
            self.assertTrue((FAKES_DIR / tool).read_text().startswith("#!/usr/bin/env python3"))

    def test_missing_logon(self):
        for tool in ("fexp", "bteq"):
            rc, out = self.run_tool(tool, "/* TDX query=count db=TDX_DB table=BIG */ SELECT 1;\n")
            self.assertEqual(rc, 12, tool)
            self.assertIn("LOGON", out)

    def test_script_logged_with_password(self):
        self.bteq("query=count db=TDX_DB table=BIG")
        entries = [json.loads(ln) for ln in self.log.read_text().splitlines()]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["tool"], "bteq")
        self.assertIn(TD_PASS, entries[0]["script"])

    def test_unknown_table(self):
        rc, out, _ = self.bteq("query=count db=TDX_DB table=NOPE")
        self.assertEqual(rc, 8)
        self.assertIn("*** Failure 3807 Object 'TDX_DB.NOPE' does not exist.", out)
        rc, out, _ = self.fexp("query=export db=TDX_DB table=NOPE")
        self.assertEqual(rc, 12)
        self.assertIn("Failure 3807", out)


class TestFakeQueries(FakeTestBase):
    def test_metadata_queries_bteq_layout(self):
        rc, out, outs = self.bteq(
            "query=columns db=tdx_db table=mixed",
            "query=index db=TDX_DB table=MIXED",
            "query=stats db=TDX_DB table=BIG",
            "query=stats db=TDX_DB table=MIXED",
            "query=count db=TDX_DB table=BIG",
            "query=minmax db=TDX_DB table=BIG col=ID",
            "query=minmax db=TDX_DB table=BIG col=VAL",
            'query=lobcheck db=TDX_DB table=LOB_BIG cols="NOTES,ID"',
            "query=rowcheck db=TDX_DB table=BIG",
        )
        self.assertEqual(rc, 0, out)
        recs = [parse_bteq(p.read_bytes()) for p in outs]
        self.assertEqual(len(recs[0]), 8)
        self.assertEqual(recs[0][0], "1|ID|I|4|\\N|\\N|N|0")
        self.assertEqual(recs[0][1], "2|AMT|D|8|10|2|Y|0")
        self.assertEqual(recs[1], ["P|Y|1|ID"])
        self.assertEqual(recs[2], ["25"])
        self.assertEqual(recs[3], ["\\N"])
        self.assertEqual(recs[4], ["25"])
        self.assertEqual(recs[5], ["1|25"])
        self.assertEqual(recs[6], ["\\N|\\N"])
        self.assertEqual(recs[7], ["50000|\\N"])
        self.assertEqual(recs[8], ["20"])
        self.assertEqual(out.count("*** Query completed. 1 rows found. 1 column returned."), 8)
        self.assertIn("*** Query completed. 8 rows found. 1 column returned.", out)

    def test_minmax_column_from_sql(self):
        out = self.tmp / "mm.raw"
        script = (LOGON + ".EXPORT DATA FILE=%s;\n/* TDX query=minmax db=TDX_DB table=BIG */ "
                  "SELECT MIN(ID), MAX(ID) FROM TDX_DB.BIG;\n" % out)
        rc, text = self.run_tool("bteq", script)
        self.assertEqual(rc, 0, text)
        self.assertEqual(parse_bteq(out.read_bytes()), ["1|25"])

    def test_field_escaping(self):
        self.edit_fixture(lambda d: d["tables"]["TDX_DB.BIG"].update(columns=[[1, "A|B\\C\nD", "CV", 5, None, None, "Y", 1]]))
        rc, out, outs = self.bteq("query=columns db=TDX_DB table=BIG")
        self.assertEqual(rc, 0, out)
        self.assertEqual(parse_bteq(outs[0].read_bytes()), ["1|A\\|B\\\\C\\\nD|CV|5|\\N|\\N|Y|1"])

    def test_cdcmax(self):
        rc, out, outs = self.bteq(
            "query=cdcmax db=TDX_DB table=CDC",
            'query=cdcmax db=TDX_DB table=CDC cdc_gt="2024-02-01 00:00:00.000000"',
            'query=cdcmax db=TDX_DB table=CDC cdc_gt="2024-03-01 00:00:00.000000"',
            "query=cdcmax db=TDX_DB table=BIG",
        )
        self.assertEqual(rc, 0, out)
        recs = [parse_bteq(p.read_bytes()) for p in outs]
        self.assertEqual(recs, [["2024-03-01 00:00:00.000000"], ["2024-03-01 00:00:00.000000"], ["\\N"], ["\\N"]])

    def test_fexp_export_text_layout(self):
        rc, out, path = self.fexp("query=export db=TDX_DB table=MIXED")
        self.assertEqual(rc, 0, out)
        fixture = json.loads(self.fixture.read_text())
        self.assertEqual(parse_text(path.read_bytes()), [r["line"] for r in fixture["tables"]["TDX_DB.MIXED"]["rows"]])
        self.assertIn("**** 12:00:00 UTY8722 4 total records written to output file.", out)

    def test_bteq_export_and_no_rows(self):
        rc, out, outs = self.bteq("query=export db=TDX_DB table=BIG chunk=1/4",
                                  'query=export db=TDX_DB table=CDC cdc_gt="2024-05-01 00:00:00.000000"')
        self.assertEqual(rc, 0, out)
        self.assertEqual(parse_bteq(outs[0].read_bytes()), ["%d|value %02d" % (i, i) for i in (1, 5, 9, 13, 17, 21, 25)])
        self.assertEqual(outs[1].read_bytes(), b"")
        self.assertIn("*** Query completed. 7 rows found. 1 column returned.", out)
        self.assertIn("*** Query completed. No rows found.", out)

    def test_chunks_partition_rows(self):
        got = []
        for i in range(1, 4):
            rc, out, path = self.fexp("query=export db=TDX_DB table=BIG chunk=%d/3" % i, self.tmp / ("c%d" % i))
            self.assertEqual(rc, 0, out)
            got += parse_text(path.read_bytes())
        self.assertEqual(sorted(got), sorted("%d|value %02d" % (i, i) for i in range(1, 26)))

    def test_cdc_window(self):
        rc, out, path = self.fexp('query=export db=TDX_DB table=CDC cdc_gt="2024-01-01 00:00:00.000000" '
                                  'cdc_le="2024-04-01 00:00:00.000000"')
        self.assertEqual(rc, 0, out)
        self.assertEqual([r.split("|")[1] for r in parse_text(path.read_bytes())], ["feb", "mar", "apr"])


class TestFakeFailures(FakeTestBase):
    def test_failure_times_across_processes(self):
        self.edit_fixture(lambda d: d.update(failures=[{"table": "tdx_db.big", "tool": "fexp", "query": "export",
                                                        "times": 2, "code": 2633,
                                                        "message": "Too many load/unload tasks running now"}]))
        out_path = self.tmp / "f.raw"
        for _ in range(2):
            rc, out, _ = self.fexp("query=export db=TDX_DB table=BIG", out_path)
            self.assertEqual(rc, 12)
            self.assertIn("*** Failure 2633 Too many load/unload tasks running now.", out)
            self.assertFalse(out_path.exists())
        # bteq is not affected by a fexp-only failure
        rc, out, _ = self.bteq("query=export db=TDX_DB table=BIG")
        self.assertEqual(rc, 0, out)
        rc, out, _ = self.fexp("query=export db=TDX_DB table=BIG", out_path)
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(parse_text(out_path.read_bytes())), 25)
        self.assertTrue(Path(str(self.fixture) + ".state").exists())

    def test_failure_chunk_and_bteq_exit_code(self):
        self.edit_fixture(lambda d: d.update(failures=[{"table": "TDX_DB.BIG", "query": "export", "chunk": 2,
                                                        "times": 1, "code": 3707, "message": "Syntax error"}]))
        rc, out, _ = self.bteq("query=export db=TDX_DB table=BIG chunk=1/3")
        self.assertEqual(rc, 0, out)
        rc, out, _ = self.bteq("query=export db=TDX_DB table=BIG chunk=2/3")
        self.assertEqual(rc, 8)
        self.assertIn("*** Failure 3707 Syntax error.", out)
        rc, out, _ = self.bteq("query=export db=TDX_DB table=BIG chunk=2/3")
        self.assertEqual(rc, 0, out)

    def test_metadata_queries_unaffected_by_export_failure(self):
        self.edit_fixture(lambda d: d.update(failures=[{"table": "TDX_DB.BIG", "times": -1, "code": 2633,
                                                        "message": "Too many load/unload tasks running now"}]))
        rc, out, _ = self.bteq("query=count db=TDX_DB table=BIG")
        self.assertEqual(rc, 0, out)
        for _ in range(3):
            rc, out, _ = self.bteq("query=export db=TDX_DB table=BIG")
            self.assertEqual(rc, 8)


if __name__ == "__main__":
    unittest.main()
