# teradataext design contract

This is the interface contract between `teradata_extract.sh`, the `lib/` engine, the sample
configuration, the documentation and the test suite. Anything not covered here is an
implementation detail of `lib/`.

Target: Teradata Database 16.20, Teradata Tools and Utilities (`fexp`, `bteq`) on a
UNIX/Linux host (Linux, AIX, Solaris). **No Python**: bash 4.2+, any POSIX awk and POSIX
utilities only (section 13). The behaviour is that of the former Python 3.12 engine
(`src/extract.py`, removed; see git history), apart from the archive format (tar.gz).

## 1. Directory layout (utility root = directory containing `teradata_extract.sh`)

```
teradata_extract.sh          entrypoint
lib/*.sh, lib/*.awk          engine (bash + POSIX awk, section 13)
config/main_config.ini       user-maintained
config/source_tables.ini     user-maintained
config/process_state.ini     MACHINE-MANAGED (created on first run)
config/utility_user_guide.txt
metadata/<db>_<table>.meta.ini
metadata/audit.log
data/<db>_<table>[.partNNN].dat     (raw, removed after archiving unless keep_raw_after_zip=true)
data/<db>_<table>_<cycle_id>.tar.gz
logs/extract_<run_id>.log           run log
logs/<db>_<table>[.partNNN].<fexp|bteq>.log   per-job tool output (password masked)
work/<db>_<table>[.partNNN].<fexp|bteq>       generated scripts, LOGON line masked
work/.process_state.lock/           mkdir() single-instance guard (holds `pid`; stale if that pid is gone)
```

`<db>_<table>` uses the names as written in `source_tables.ini`, lower-cased, with any
character outside `[A-Za-z0-9_]` replaced by `_`. `NNN` is the 1-based chunk number,
zero-padded to 3 digits (`.part001`). Unchunked tables have no `.partNNN`.

Relative paths in `main_config.ini` resolve against `[paths] base_dir`; when `base_dir` is
empty it defaults to the parent directory of the directory that holds `main_config.ini`
(i.e. the utility root for `config/main_config.ini`).

## 2. Command line

`teradata_extract.sh [options]` (the engine is sourced from `lib/`).

| Option | Meaning |
|---|---|
| `--config PATH` | main config file (default `<root>/config/main_config.ini`) |
| `--tables db.t[,db.t...]` | restrict this run to these tables (case-insensitive) |
| `--parallel N` | override `[extract] parallel` |
| `--new-cycle` | start a new extraction cycle: every table back to `pending`, chunk lists cleared, CDC watermarks kept |
| `--reset-table db.t` | reset one table to `pending` (chunks cleared, watermark kept); repeatable |
| `--reset-watermark db.t` | additionally clear the CDC watermark (next run is a full extract); repeatable |
| `--dry-run` | validate config + credentials + tools, print the work queue, do not connect |
| `--status` | print the state summary and exit, do not connect |
| `-v/--verbose` | DEBUG logging to the console |

Exit codes: `0` all queued tables done; `1` at least one table failed; `2` configuration,
credential, tool or lock error (nothing extracted); `130` interrupted (state saved, resumable).

Environment variables: `TD_USER`, `TD_PASS` (credentials), `TDX_AWK` (awk binary, default
`awk`; tests run every awk variant through it), `TDX_FEXP` / `TDX_BTEQ` (override `fexp_path` /
`bteq_path`; used by tests to point at fake binaries).

## 3. `config/main_config.ini`

INI (configparser-compatible subset: `key = value`, no interpolation); full-line comments only (`#` or `;`), no inline comments.

```ini
[teradata]
host = tdprod.example.com      ; TDPID used in .LOGON
port = 1025                    ; used for the TCP pre-check only
logmech =                      ; optional, e.g. TD2 / LDAP (emitted as .LOGMECH)
credentials_file =             ; optional path to a chmod 0600 file (see section 6)
fexp_path = fexp
bteq_path = bteq
session_charset = ASCII        ; ASCII or UTF8
logtable_database =            ; database for FastExport .LOGTABLE (default: the user's default db)
connect_check = true           ; TCP connect to host:port before starting

[paths]
base_dir =
output_dir = data
metadata_dir = metadata
log_dir = logs
work_dir = work
source_tables_file = config/source_tables.ini
process_state_file = config/process_state.ini

[extract]
file_format = pipe-delimited   ; only supported value
parallel = 1                   ; <=0 or "auto" -> min(nproc, max_sessions)
max_sessions = 4               ; total Teradata sessions budget across concurrent jobs
min_sessions = 1
chunk_threshold_rows = 10000000
chunk_rows = 5000000
max_chunks = 64
small_table_rows = 100000      ; jobs estimated below this use BTEQ EXPORT instead of FastExport
row_estimate = stats           ; stats (DBC.StatsV, fallback COUNT(*)) | count
char_trim = right              ; right | both | none   (CHAR columns only)
lob_max_length = 32000         ; max characters (CLOB/JSON/XML) or bytes (BLOB) exported per value
max_row_length = 63999         ; max exported record length (characters)
zip_on_complete = true
keep_raw_after_zip = false
retry_attempts = 3
retry_delay_seconds = 60
session_limit_errors = 2633,3130
session_limit_patterns = Too many load/unload tasks,session limit,No more sessions
bteq_fallback = true           ; after FastExport session-limit retries are exhausted, try BTEQ EXPORT
job_timeout_seconds = 0        ; 0 = no timeout
log_tool_output = masked       ; masked | errors | none: tool output kept in job logs

[format]
delimiter = |
null_sentinel = \N
empty_sentinel = \E
escape_char = \
big_decimal_quote = "
big_decimal_threshold = 18
```

## 4. `config/source_tables.ini`

Two section forms; section names are free labels.

```ini
; table list section: database + table list only (braces optional, commas, may wrap
; onto indented lines). Listed tables: automatic chunking, no filter, full extract.
[sales]
database = SALES
table = {REGION, ORDERS, CUSTOMER}

; one-table section: one table name plus optional settings
[customer]
database = SALES
table = CUSTOMER
cdc_column = UPDATED_TS     ; optional
chunk_column =              ; optional override of the automatic chunk column
where =                     ; optional static filter, ANDed into every export
enabled = true              ; optional
```

- `table` is a list when it contains a comma or a newline, or is wrapped in `{...}`;
  otherwise it is a single table name (the original one-table form, unchanged).
- A list section with any key other than `database`/`table`, unbalanced braces, an empty
  list item, a table in two list sections, or two one-table sections for the same table
  (even disabled ones) is a configuration error (exit 2).
- A table both listed and given a one-table section: `database`/`table` come from the list
  (the list takes priority), `cdc_column`/`chunk_column`/`where`/`enabled` from the
  one-table section, and a WARNING is logged.
- Work order follows the file: list members at the list section's position, other tables at
  their own section's position.

The table key used everywhere else is `DATABASE.TABLE` upper-cased.

## 5. `config/process_state.ini` (machine-managed)

Written atomically (temp file in the same directory, then `mv`, which is an atomic rename on
the same file system) after every chunk/table transition, under a `mkdir` lock. First lines:

```
# THIS FILE IS MANAGED BY teradata_extract - DO NOT EDIT.
# Use --reset-table / --reset-watermark / --new-cycle to change extraction state.
```

Sections:

```ini
[_run]
cycle_id = 20261020T013200Z
last_run_id = 20261020T013200Z-12345
last_run_started = 2026-10-20T01:32:00Z
last_run_finished = ...

[SALES.ORDERS]
status = pending | in_progress | done | failed
attempts = 1
method = fexp | bteq | mixed
estimated_rows = 25
row_estimate_source = stats | count
chunk_strategy = none | range | hash
chunk_column = ORDER_ID
chunk_count = 4
chunks_done = 1,2,4            ; 1-based chunk numbers already done
rows_exported = 25
files = sales_orders.part001.dat,...
checksum_sha256 = <sha256 over the per-chunk sha256 hex strings joined by "\n", in chunk order>
zip_file = sales_orders_20261020T013200Z.tar.gz
zip_sha256 = ...
watermark = 2024-03-01 00:00:00.000000   ; last committed CDC high-water mark
pending_watermark = ...                  ; upper bound captured for the in-flight cycle
started_at / finished_at / elapsed_seconds
last_error = ...

[SALES.ORDERS/part001]
status = pending | in_progress | done | failed
rows = 7
file = sales_orders.part001.dat
bytes = 1234
sha256 = ...
method = fexp | bteq
sessions = 4
where = <chunk predicate>
```

At startup any `in_progress` table/chunk is treated as `pending` (previous run died).
The work queue = enabled tables from `source_tables.ini` (optionally filtered by `--tables`)
whose status is not `done`.

## 6. Credentials

1. `TD_USER` and `TD_PASS` both set -> used.
2. else `[teradata] credentials_file` set -> file must exist, be owned by the current user and
   have no group/other permission bits (`mode & 0o077 == 0`, e.g. 0600/0400). Content:
   ```ini
   [credentials]
   user = etl_user
   password = ...
   ```
3. otherwise exit 2 with a clear message. Only one of TD_USER/TD_PASS set -> exit 2.

The password is never written to disk: generated scripts are piped to `fexp`/`bteq` on stdin
with the real `.LOGON`; the copies saved under `work/` and all captured tool output have the
password replaced with `********`.

## 7. Generated scripts and the request marker

Every SQL request starts with a marker comment so logs are self-describing and the fake
binaries can identify the request:

```
/* TDX query=<kind> db=<DB> table=<TABLE> [chunk=<i>/<n>] [cdc_gt="<v>"] [cdc_le="<v>"] */
```

`kind` is one of `columns, index, stats, count, minmax, lobcheck, rowcheck, cdcmax, export`.
Values never contain `*/`; values with spaces are double-quoted.

Every query returns a **single VARCHAR column** per row; fields inside it are joined with
`|`, NULL is `\N`, and `\`, `|`, CR, LF inside values are prefixed with `\`. Integer metadata
(`ColumnId`, `ColumnLength`, digits, `ColumnPosition`, `RowCount`) is
`CAST(CAST(x AS BIGINT) AS FORMAT '-(19)9')`, and min/max/cdcmax of integer and bounded
decimal columns use the same explicit FORMAT as the export (below): Teradata converts a number
to text with the column's FORMAT, which may group digits (`1,025`). Each field is
`CAST(... AS VARCHAR(256))`, escaped with `OREPLACE`, then `CAST(... AS VARCHAR(512))`.

SQL width rules (Teradata documentation): `OREPLACE` with literal search/replace arguments
returns `VARCHAR(8000) CHARACTER SET UNICODE` and fails (error 9134) when a result would be
longer. A `||` result is as wide as the sum of its arguments, and Teradata rejects one wider
than 64000 LATIN / 32000 UNICODE characters (Failure 3798). So every `OREPLACE` result is
bounded by a `CAST` (or translated back with `TRANSLATE(... USING UNICODE_TO_LATIN)` for
LATIN columns) before it is concatenated.

| kind | result fields (per row) |
|---|---|
| columns | column_id, column_name, column_type (DBC code e.g. `I`, `CV`, `D`, `TS`, `SZ`), column_length, decimal_total_digits, decimal_fractional_digits, nullable (`Y`/`N`), char_type (1=LATIN, 2=UNICODE, ...) |
| index | index_type (`K`,`P`,`Q`,...), unique_flag, column_position, column_name |
| stats | row_count (or `\N`) |
| count | row_count |
| minmax | min, max (numbers plain, dates `YYYY-MM-DD`) |
| lobcheck | one field per checked column (max length, `\N` if all NULL), in column order |
| rowcheck | max exported record length |
| cdcmax | max cdc value (`\N` when there are no new rows); integers plain, DATE `YYYY-MM-DD`, TIMESTAMP `YYYY-MM-DD HH:MI:SS.ffffff` |
| export | the encoded data record (section 8) |

BTEQ script shape:
```
.SET SESSION CHARSET 'ASCII';
.LOGON host/user,password;
.SET ERROROUT STDOUT;
.EXPORT DATA FILE = <abs path>;
/* TDX ... */ SELECT ...;
.IF ERRORCODE <> 0 THEN .QUIT ERRORCODE;
.EXPORT RESET;
.LOGOFF;
.QUIT 0;
```

FastExport script shape:
```
.LOGTABLE <logdb>.tdx_lt_<hash>;
.LOGON host/user,password;
.BEGIN EXPORT SESSIONS <n> TENACITY 0;
.EXPORT OUTFILE <abs path> FORMAT TEXT MODE RECORD;
/* TDX ... */ SELECT ...;
.END EXPORT;
.LOGOFF;
```

### Raw export layouts (decoded by lib/rawdecode.awk into the final .dat file)

All lengths are unsigned 16-bit integers in the host's byte order: little-endian on Linux x86,
big-endian on AIX and Solaris SPARC. The decoder tries the host's order first, then the other.

* FastExport `FORMAT TEXT` with one VARCHAR column: `varchar_len, payload, 0x0A` per record.
* BTEQ `.EXPORT DATA`: `record_len (= varchar_len + 2), varchar_len, payload, 0x0A` per record.

The engine auto-detects the layout (with or without the record-length prefix, with or
without the 0x0A end-of-record byte) by checking that the whole file parses consistently, and
fails the job if no layout fits. The raw file is `<final>.raw`, removed after conversion.

Row counts: records parsed from the raw file are authoritative. When the tool output contains
`<N> total records written` (FastExport) or `Query completed. <N> rows found` /
`Query completed. One row found` / `Query completed. No rows found` (BTEQ) the numbers must match, otherwise the job fails.

Errors: a job fails when the tool exits non-zero. It is a **session-limit failure** when the
output contains `Failure <code>` / `Error <code>` with a code in `session_limit_errors`, or any
of `session_limit_patterns` (case-insensitive). Session-limit failures are retried after
`retry_delay_seconds` with `sessions = max(min_sessions, sessions // 2)` up to
`retry_attempts` times, then (FastExport only, `bteq_fallback = true`) once via BTEQ EXPORT.
Other failures are not retried within the run.

## 8. Data file format (`.dat`)

ASCII (or UTF-8 when `session_charset = UTF8`) text, one record per row, `|` delimited,
records terminated by LF. Inside text values `\`, `|`, CR and LF are escaped by a preceding
`\` (Redshift `COPY ... ESCAPE` compatible), so a raw LF preceded by an odd number of `\` is
data, not a record end. NULL = `\N`. Zero-length string/binary value = `\E`.

| Teradata type (DBC code) | output_encoding | Rule | redshift_type |
|---|---|---|---|
| BYTEINT (I1), SMALLINT (I2) | int_text | plain integer | SMALLINT |
| INTEGER (I) | int_text | | INTEGER |
| BIGINT (I8) | int_text | | BIGINT |
| DECIMAL/NUMERIC (D) p<=18 | decimal_text | plain, `.` decimal point | DECIMAL(p,s) |
| DECIMAL p>18, NUMBER (N) p>18 or unbounded | decimal_quoted | `"` + text + `"` | DECIMAL(p,s) (p<=38) else VARCHAR |
| NUMBER (N) p<=18 | decimal_text | | DECIMAL(p,s) |
| FLOAT/REAL/DOUBLE (F) | float_text | 17 significant digits, `E+nnn` exponent | FLOAT8 |
| DATE (DA) | iso_date | `YYYY-MM-DD` | DATE |
| TIME (AT) | iso_time | `HH:MI:SS[.f]` | TIME |
| TIME WITH TIME ZONE (TZ) | utc_iso_time | converted to UTC, `HH:MI:SS[.f]Z` | TIMETZ |
| TIMESTAMP (TS) | iso_timestamp | `YYYY-MM-DDTHH:MI:SS[.f]` | TIMESTAMP |
| TIMESTAMP WITH TIME ZONE (SZ) | utc_iso_timestamp | converted to UTC, `...Z`; meta records `source_timezone = per-value offset, converted to UTC` | TIMESTAMPTZ |
| INTERVAL (YR,YM,MO,DY,DH,DM,DS,HR,HM,HS,MI,MS,SC) | interval_text | CAST to VARCHAR, trimmed | VARCHAR(n) |
| PERIOD (PD,PT,PZ,PS,PM) | period_text | CAST to VARCHAR | VARCHAR(n) |
| CHAR (CF) | escaped_text | trimmed per `char_trim`, escaped | CHAR(n)/VARCHAR(n*4) for UNICODE |
| VARCHAR (CV) | escaped_text | escaped | VARCHAR(n) (x4 for UNICODE, max 65535) |
| CLOB (CO), JSON (JN), XML (XM) | escaped_text | CAST/XMLSERIALIZE to VARCHAR(lob_max_length) after a MAX length pre-check, escaped | VARCHAR(65535) |
| BYTE (BF), VARBYTE (BV), BLOB (BO) | hex | `FROM_BYTES(...,'base16')`, BLOB after a length pre-check | VARBYTE(n) |
| anything else (UDT, ARRAY, ...) | unsupported | table fails (never lossy) | |

Never lossy: a table fails (status `failed`, `last_error` set) instead of truncating when a
LOB value exceeds `lob_max_length`, a record would exceed `max_row_length`, a column type is
unsupported, or a non-LATIN character column is exported with `session_charset = ASCII`.
LOB tables always use BTEQ EXPORT.

Export record SQL: each column expression is `CAST(... AS VARCHAR(w) CHARACTER SET cs)`, where
`w` is the column's longest possible output (or sentinel), capped at the record limit + 1; the
columns are joined with the delimiter and the record is cast to `VARCHAR(limit + 1) CHARACTER SET
cs`. `cs` is UNICODE for tables with UNICODE/JSON/XML columns, else LATIN, and the delimiter is
then `TRANSLATE('|' USING UNICODE_TO_LATIN)`: literals and functions such as `FROM_BYTES` may
return UNICODE, and one UNICODE operand makes the whole record UNICODE (32000 maximum). Text columns
count `2 * length` (every character escaped), at most 8000 (the `OREPLACE` limit); a text
value longer than 8000 characters after escaping fails the table with Teradata error 9134.
LATIN text is translated back to LATIN after `OREPLACE`; JSON/XML stay UNICODE, so a table
with a JSON/XML column has the 32000 UNICODE record maximum. If the column widths add up to
more than the record VARCHAR maximum (64000 LATIN / 32000 UNICODE), the table fails before
any export with "table too wide to export". TIMESTAMP values get their `T` separator from
`SUBSTR`, not `OREPLACE`. Integers are exported with their type's default FORMAT
(`-(3)9`, `-(5)9`, `-(10)9`, `-(19)9`) and bounded decimals with `-(p-s)9.9(s)`, never the
column's own FORMAT. An unbounded NUMBER is cast without a FORMAT.

## 9. `metadata/<db>_<table>.meta.ini`

```ini
[table]
database, table, extracted_at, column_count, row_estimate, row_estimate_source,
primary_index, chunk_strategy, chunk_column, chunk_count, cdc_column, session_charset,
file_format, delimiter, null_sentinel, empty_sentinel, escape_char, record_terminator,
timezone_policy = UTC

[column.001]      ; one per column, in ordinal order
name, position, source_type (e.g. DECIMAL(38,2)), td_type_code, nullable, char_set,
output_encoding, redshift_type, null_sentinel (\N), empty_sentinel (\E or n/a),
empty_string_possible (yes/no), source_timezone (TZ types only), notes
```

## 10. `metadata/audit.log`

Append-only, one line per table per run:
`<utc iso ts> | <run_id> | <DB.TABLE> | <done|failed|skipped> | rows=<n> | files=<n> | chunks=<done>/<total> | method=<m> | elapsed=<s>s | watermark=<from>-><to> | <message>`

## 11. Executive summary (stdout at exit)

```
==================== TERADATA EXTRACT SUMMARY ====================
Run id        : ...
Tables        : done=3 failed=1 pending=0 (queued=4, skipped already done=2)
Rows exported : 1,234,567
Files written : 9 (.dat) / 3 (.tar.gz)
Elapsed       : 00:12:34
FAILED        : SALES.BIG_LOB - LOB value length 40000 exceeds lob_max_length 32000
==================================================================
```

## 12. Tests

`tests/run_tests.sh` (bash; no Python, no bats). It runs every `tests/test_*.sh` file; a test is a
shell function `test_*`, assertions come from `tests/lib/assert.sh`. `TDX_AWK` selects the awk
under test (`tests/run_tests.sh --awk mawk` etc.). `tests/fakes/fexp` and `tests/fakes/bteq` are
bash + awk stand-ins with the behaviour described in `tests/fakes/README.md` (same request
protocol, raw layouts, row-count lines and failure simulation as before; fixtures are plain text,
not JSON). `tests/golden/<scenario>/` holds normalized outputs captured from the former Python
engine (timestamps, run/cycle ids, temp paths, `tdx_lt_<hash>`, archive name/sha replaced by
placeholders; archives stored as their sorted member list). The golden tests run the same
scenarios and compare outputs byte for byte after the same normalization.

## 13. bash engine

| File | Responsibility |
|---|---|
| `teradata_extract.sh` | checks bash >= 4.2, awk, `od`, `gzip`, `tar`, a SHA-256 tool, `fexp`/`bteq` (not for `--status`/`--dry-run` beyond PATH lookup); creates dirs; sources `lib/*.sh`; runs `tdx_main "$@"` |
| `lib/common.sh` | logging (run log + console), errors/exit codes, quoting helpers, UTC time, signal traps |
| `lib/config.sh` + `lib/ini.awk` | INI parsing into bash associative arrays, settings validation, source tables |
| `lib/creds.sh` | TD_USER/TD_PASS or credentials file (owner + mode via `ls -ln`) |
| `lib/state.sh` | process_state.ini read/update/atomic write, `mkdir` lock |
| `lib/runner.sh` + `lib/mask.awk` | script generation, tool execution (password on stdin via `printf` builtin), masking, `log_tool_output`, error classification, timeout watchdog |
| `lib/types.sh` | DBC metadata -> column rules / SQL expressions, meta files |
| `lib/plan.sh` | row estimate, chunk planning, CDC predicates |
| `lib/extract.sh` | scheduler: background jobs, session pool, retries, fallback |
| `lib/finalize.sh` | .dat publish, tar.gz archive + integrity check, audit, summary |
| `lib/main.sh` | CLI parsing, startup checks, job scheduler, interrupt handling |
| `lib/rawdecode.awk` | raw export decoder fed by `od -An -v -tu1` (run with `LC_ALL=C`) |

Portability rules: no GNU-only options (`sed -i`, `grep -P`, `date -d`, `stat`, `readlink -f`,
`timeout`, `flock`, `od -w`, `tar -z`, `mktemp` options beyond `-d`). awk code must run on
gawk, mawk, onetrue awk (original-awk), busybox awk and old SVR4-style nawk (tested with
Heirloom nawk). For the old awks: no regex literal starting with `=` (`/=` is read as the
divide-assign operator; use a string such as `"=.*"`), no `delete array` (empty arrays with
`split("", array)`), and a local array must be created (e.g. with `split`) before `in` is used
on it.

Archive: `tar cf - <members> | gzip -c > <name>.tar.gz.tmp`, then `gzip -t`, the member list
(`gzip -dc | tar tf -`) must equal the expected `.dat` names, then rename to `.tar.gz`; its
SHA-256 is stored in `zip_sha256` before raw files are deleted.

SHA-256: the first available of `sha256sum`, `shasum -a 256`, `openssl dgst -sha256`,
`digest -a sha256` (Solaris); none -> exit 2 at startup.

Raw decoding: a NUL byte inside a record fails the job (portable awks cannot write NUL). Every
other byte passes through unchanged. Record length is counted in UTF-8 characters when
`session_charset = UTF8`, else in bytes, as before.

Range chunks: integer and DATE keys use the former formula exactly (shell 64-bit arithmetic;
DATE via day numbers). DECIMAL keys with a scale, and integer keys beyond 18 digits, get their
boundaries from POSIX `bc` (needed only then; without it the table fails with a clear error).
Boundaries of keys with a scale are computed with 10 decimal places beyond that scale, so their literals may differ
textually from the Python engine; coverage of every value (NULL and out-of-range included) is
unchanged.

Other bash-engine notes: the FastExport log table name is `tdx_lt_` + the first 12 hex digits of
the SHA-256 (was SHA-1) of the job id. `TDX_AWK` may contain arguments (e.g. `busybox awk`).
On Solaris `/usr/xpg4/bin/awk` is used when `TDX_AWK` is unset. `lib/main.sh` holds the CLI,
startup and the job scheduler (each prepare/export job is a background subshell; jobs exchange
state only through the locked working copy of process_state.ini under `work/.tdx-run-<pid>/`).
