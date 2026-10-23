# Fake `fexp` / `bteq`

Bash + POSIX awk stand-ins for Teradata FastExport and BTEQ (DESIGN.md sections 7 and 12).
The engine is pointed at them with `TDX_FEXP=tests/fakes/fexp` and `TDX_BTEQ=tests/fakes/bteq`.
Both are thin `#!/usr/bin/env bash` wrappers around `_tdxfake.sh` (process handling, locking,
binary output) and `_tdxfake.awk` (script scanning, fixture lookup, answers). They need bash 4.2+
and any POSIX awk (`$TDX_AWK`, default `awk`; may contain arguments, e.g. `busybox awk`). All text
is handled with `LC_ALL=C`; binary bytes are written with `printf` octal escapes.

## Behaviour

1. The whole script is read from stdin. If `TDX_FAKE_LOG` is set, one entry is appended per
   invocation (format below). It contains the complete script, including the real `.LOGON`,
   so tests can prove the password arrived via stdin. Keep the log outside the utility root.
2. No `.LOGON host/user,password` line -> error message, exit `12`.
3. The script is scanned in order for `.EXPORT OUTFILE <path>` (fexp), `.EXPORT DATA FILE = <path>` /
   `FILE=<path>` (bteq; both tools accept either form), `.EXPORT RESET`, and request markers
   `/* TDX key=value ... */` (values may be `"double quoted"`). Each marker is answered in order and
   written to the most recent export file. The first write to a path truncates it; later requests
   to the same path append.
4. The table `db.table` from the marker is looked up case-insensitively in `$TDX_FAKE_FIXTURE`.
   If it is unknown, the tool prints `*** Failure 3807 Object 'DB.TABLE' does not exist.`
5. On a failure, the tool prints `*** Failure <code> <message>.` and exits `12` (fexp) / `8` (bteq)
   without writing that request's file.

Every result row is a single string: fields are joined with `|`, NULL is `\N`, and `\`, `|`, CR and
LF are escaped with a preceding `\`. Layouts (uint16 little-endian):

* fexp (`FORMAT TEXT`): `varchar_len, payload, 0x0A`; prints
  `**** 12:00:00 UTY8722 <N> total records written to output file.` per request.
* bteq (`.EXPORT DATA`): `record_len (= varchar_len + 2), varchar_len, payload, 0x0A`; prints
  `*** Query completed. <N> rows found. 1 column returned.` or `*** Query completed. No rows found.`

| query | answer |
|---|---|
| `columns` | one row per `column` line |
| `index` | one row per `index` line |
| `stats` | `stats_rows` (`\N` when null) |
| `count` | `count` (default: number of `row` lines) |
| `minmax` | `minmax <col>`; col from marker `col=`/`column=`/`chunk_column=`, else the first `MIN(<col>)` in the SQL, else the only entry; `\N\|\N` if absent |
| `lobcheck` | marker `cols="A,B"` -> `lob_max A\|lob_max B` (`\N` when missing) |
| `rowcheck` | `row_max` (default: longest row line) |
| `cdcmax` | `cdc_max`; `\N` when null, or when `cdc_gt` is given and `cdc_max <= cdc_gt` |
| `export` | row lines as-is (already DESIGN.md section 8 encoded), filtered by `cdc_gt < cdc <= cdc_le` (string compare; rows without `cdc` are dropped when a bound is given) and `chunk=i/n` (keep 0-based row index `% n == i-1`) |

## Fixture format (`$TDX_FAKE_FIXTURE`, e.g. `tests/fixtures/basic.fixture`)

A line-oriented text file with TAB-separated fields. Blank lines and lines starting with `#` are
ignored. Inside a field, `%25` `%09` `%0A` `%0D` stand for `%`, TAB, LF and CR, and every other byte
is literal. A field that is exactly `\N` is NULL. Table lines start with the table key (matched
case-insensitively):

```
<DB.TABLE>  table                                      declares the table (optional if it has other lines)
<DB.TABLE>  column  <id> <name> <type> <len> <digits> <fraction> <nullable> <char_type>
<DB.TABLE>  index   <index_type> <unique_flag> <column_position> <column_name>
<DB.TABLE>  stats_rows <n|\N>     count <n>     row_max <n>     cdc_max <value|\N>
<DB.TABLE>  minmax  <COLUMN> <min> <max>
<DB.TABLE>  lob_max <COLUMN> <n>
<DB.TABLE>  row     <line> [<cdc value>]                rows in order; <line> is the exported record
failure  table=<DB.TABLE>  [tool=fexp|bteq]  [query=<kind>|*]  [chunk=<i>|<i>/<n>]  [times=<n>]  [code=<n>]  [message=<text>]
```

Columns, indexes, minmax and lob_max entries keep their file order. Failure keys are optional
except `table`:
* `tool`: omitted means both tools.
* `query`: defaults to `export`; `*` matches any kind.
* `chunk`: omitted matches any chunk.
* `times`: defaults to `1`; `-1` means always.
* `code`: defaults to `2633`.
* `message`: defaults to `Too many load/unload tasks running now`.

Each failure line fails the first `times` matching requests. The counters persist across processes
in `<fixture>.state` (lines `<failure index> <times used>`). That file is updated under a `mkdir`
lock (`<fixture>.state.lock/`; a lock left by a dead process is broken). Delete the state file to
reset the counters.

Editing from tests (`tests/lib/env.sh`):
* `tt_fixture_set TDX_DB.CDC cdc_max "2024-04-15 00:00:00.000000"` replaces a value; `\N` sets NULL.
* `tt_fixture_add_failure table=TDX_DB.BIG query=export chunk=2 times=1 code=3707 "message=..."` adds a failure.
* `tt_fixture_clear_failures` removes all failures.
Because the format is plain text, `grep`, `sed` or `printf >>` work too.

`basic.fixture` has:
* `TDX_DB.MIXED`: mixed types, escaping edge cases, unchunked.
* `TDX_DB.BIG`: 25 rows, numeric PI, chunked with a low `chunk_threshold_rows`.
* `TDX_DB.CDC`: CDC on `UPDATED_TS`, `cdc_max` 2024-03-01, two newer rows.
* `TDX_DB.LOB_BIG`: CLOB with `lob_max` 50000, which exceeds the test `lob_max_length`.

`types.fixture` has every supported type code (ASCII/Unicode, hash and date-range chunking, LOBs).

## Call log format (`$TDX_FAKE_LOG`)

Each invocation appends one entry, under a `mkdir` lock (`$TDX_FAKE_LOG.lock/`):

```
@call tool=<fexp|bteq> pid=<pid> time=<epoch seconds> argc=<n> lines=<n> final_newline=<yes|no>
@argv <argument>              (argc lines)
><script line>                (lines lines: the stdin script, verbatim, each prefixed with '>')
@end
```

The script is rebuilt by joining the `>` lines (prefix removed) with LF, plus a final LF when
`final_newline=yes`. `tt_fake_scripts DIR` in `tests/lib/env.sh` does this for every entry.
`tt_requests [QUERY] [DB.TABLE]` lists the marked requests the fakes received.
