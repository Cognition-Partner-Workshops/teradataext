# Fake `fexp` / `bteq`

Stdlib-only Python stand-ins for Teradata FastExport and BTEQ (DESIGN.md sections 7 and 12).
The engine is pointed at them with `TDX_FEXP=tests/fakes/fexp` and `TDX_BTEQ=tests/fakes/bteq`.
Both share `_tdxfake.py` and run under any Python 3.8+ (`#!/usr/bin/env python3`).

## Behaviour

1. The whole script is read from stdin. If `TDX_FAKE_LOG` is set, one JSON line
   `{"tool", "pid", "time", "argv", "script"}` is appended per invocation (the script includes the
   real `.LOGON`, so tests can prove the password arrived via stdin). Keep this log outside the
   utility root.
2. No `.LOGON host/user,password` line -> error message, exit `12`.
3. The script is scanned in order for `.EXPORT OUTFILE <path>` (fexp), `.EXPORT DATA FILE = <path>` /
   `FILE=<path>` (bteq; either form is accepted by both tools), `.EXPORT RESET`, and request markers
   `/* TDX key=value ... */` (values may be `"double quoted"`). Each marker is answered in order and
   written to the most recent export file (first write truncates, later requests to the same path append).
4. The table `db.table` from the marker is looked up case-insensitively in `$TDX_FAKE_FIXTURE`.
   Unknown -> `*** Failure 3807 Object 'DB.TABLE' does not exist.`
5. On a failure the tool prints `*** Failure <code> <message>.` and exits `12` (fexp) / `8` (bteq)
   without writing that request's file.

Every result row is a single string, fields joined with `|`, NULL as `\N`, and `\`, `|`, CR, LF
escaped with a preceding `\`. Layouts (uint16 little-endian):

* fexp (`FORMAT TEXT`): `varchar_len, payload, 0x0A`; prints
  `**** 12:00:00 UTY8722 <N> total records written to output file.` per request.
* bteq (`.EXPORT DATA`): `record_len (= varchar_len + 2), varchar_len, payload, 0x0A`; prints
  `*** Query completed. <N> rows found. 1 column returned.` or `*** Query completed. No rows found.`

| query | answer |
|---|---|
| `columns` | one row per `columns` entry |
| `index` | one row per `indexes` entry |
| `stats` | `stats_rows` (`\N` when null) |
| `count` | `count` (default: number of `rows`) |
| `minmax` | `minmax[<col>]`; col from marker `col=`/`column=`/`chunk_column=`, else the first `MIN(<col>)` in the SQL, else the only entry; `\N\|\N` if absent |
| `lobcheck` | marker `cols="A,B"` -> `lob_max[A]\|lob_max[B]` (`\N` when missing) |
| `rowcheck` | `row_max` (default: longest `line`) |
| `cdcmax` | `cdc_max`; `\N` when null, or when `cdc_gt` is given and `cdc_max <= cdc_gt` |
| `export` | `rows[].line` as-is (already DESIGN.md section 8 encoded), filtered by `cdc_gt < cdc <= cdc_le` (string compare; rows without `cdc` are dropped when a bound is given) and `chunk=i/n` (keep 0-based row index `% n == i-1`) |

## Fixture schema (`$TDX_FAKE_FIXTURE`)

```json
{
  "tables": {
    "DB.TABLE": {
      "columns": [[1, "ID", "I", 4, null, null, "N", 0]],
      "indexes": [["P", "Y", 1, "ID"]],
      "stats_rows": 25,
      "count": 25,
      "minmax": {"ID": ["1", "25"]},
      "lob_max": {"NOTES": 120},
      "row_max": 500,
      "cdc_max": "2024-03-01 00:00:00.000000",
      "rows": [{"line": "1|abc|\\N", "cdc": "2024-01-01 00:00:00.000000"}]
    }
  },
  "failures": [
    {"table": "DB.TABLE", "tool": "fexp", "query": "export", "chunk": 2, "times": 1,
     "code": 2633, "message": "Too many load/unload tasks running now"}
  ]
}
```

* `columns`: `[column_id, name, DBC type code, length, total_digits, fractional_digits, nullable, char_type]`.
* `indexes`: `[index_type, unique_flag, column_position, column_name]`.
* `stats_rows` / `cdc_max` may be `null`.
* `failures` (all keys optional except `table`): `tool` (omit = both), `query` (default `export`,
  `*` = any kind), `chunk` (1-based `i` or `"i/n"`; omit = any), `times` (default `1`; `-1` = always),
  `code` (default `2633`), `message`. Each entry fails the first `times` matching requests. Counters
  persist in `<fixture>.state` (JSON, `flock`-protected), so they work across processes; delete it
  to reset.

`tests/fixtures/basic.json` has `TDX_DB.MIXED` (mixed types, escaping edge cases, unchunked),
`TDX_DB.BIG` (25 rows, numeric PI, chunked with a low `chunk_threshold_rows`), `TDX_DB.CDC`
(CDC on `UPDATED_TS`, `cdc_max` 2024-03-01, two newer rows) and `TDX_DB.LOB_BIG`
(CLOB `lob_max` 50000, exceeds the test `lob_max_length`).
