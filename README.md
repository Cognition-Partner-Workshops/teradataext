# teradataext

A small extraction utility for **Teradata Database 16.20** on UNIX/Linux. It uses
FastExport (`fexp`) for bulk data and BTEQ (`bteq`) for metadata, small tables and LOB
tables, and writes pipe-delimited files that load into Amazon Redshift (or similar).
It needs only Python 3.12 (standard library) and Teradata Tools and Utilities 16.20.

- Interface contract (config keys, CLI, file names, state format, type mapping, exit
  codes): [docs/DESIGN.md](docs/DESIGN.md)
- Operator guide: [config/utility_user_guide.txt](config/utility_user_guide.txt)

## Features

- FastExport for bulk exports, BTEQ EXPORT for small tables/chunks and LOB tables, plus
  a BTEQ fallback when FastExport keeps hitting session limits.
- Automatic chunking of large tables: range chunks on a numeric/DATE single-column PK/PI
  (NULLs go to chunk 1), otherwise `HASHBUCKET(HASHROW(PI)) MOD n`. You can override the
  chunk column per table.
- Parallel jobs within a Teradata session budget (`parallel`, `max_sessions`).
- Retry on session-limit errors, halving the session count on each retry.
- Resumable: state is saved atomically after every chunk. Tables and chunks already done
  are skipped on rerun.
- CDC / incremental extraction with a watermark column. The upper bound is captured
  first, and the watermark is committed only after the table finishes successfully.
- Never lossy: a table fails rather than truncate LOBs or long records, export
  unsupported types, or export non-LATIN data in an ASCII session.
- A metadata file per table with Teradata and Redshift types, an append-only audit log,
  zip with integrity test, and an executive summary at exit.
- Passwords never touch disk. Credentials come from `TD_USER`/`TD_PASS` or a 0600 file,
  and scripts and logs are masked.

## Layout

```
teradata_extract.sh               entrypoint
src/extract.py                    engine (single module, stdlib only)
config/
  main_config.ini                 main configuration (user-maintained)
  source_tables.ini               tables to extract (user-maintained)
  process_state.ini               extraction state (MACHINE-MANAGED; sample shipped)
  credentials.ini.example         credentials file template
  utility_user_guide.txt          operator guide
docs/DESIGN.md                    interface contract
tests/                            unittest suite + fake fexp/bteq (tests/fakes)
metadata/                         <db>_<table>.meta.ini, audit.log        (created at run)
data/                             <db>_<table>[.partNNN].dat, *.zip       (created at run)
logs/                             run log, per-job tool output (masked)   (created at run)
work/                             generated scripts (masked), lock file   (created at run)
```

## Quick start

```sh
# 1. prerequisites: python3.12, fexp and bteq (TTU 16.20) on PATH
python3.12 --version && which fexp bteq

# 2. configure
vi config/main_config.ini          # [teradata] host, logtable_database, ...
vi config/source_tables.ini        # tables to extract
rm config/process_state.ini        # remove the shipped SAMPLE state before the first run

# 3. credentials (preferred: environment variables)
export TD_USER=etl_user
read -s TD_PASS && export TD_PASS
# export TDX_PYTHON=/path/to/python3.12   # if python3.12 is not the default

# 4. validate without connecting, then run
./teradata_extract.sh --dry-run
./teradata_extract.sh
```

To use a credentials file instead of environment variables, copy
`config/credentials.ini.example` somewhere outside the repository, `chmod 600` it and set
`[teradata] credentials_file`.

## Usage examples

```sh
# full run of all enabled tables in source_tables.ini
./teradata_extract.sh

# only some tables (case-insensitive DATABASE.TABLE)
./teradata_extract.sh --tables sales.orders,sales.customer

# parallel jobs = min(CPUs, max_sessions)
./teradata_extract.sh --parallel auto

# validate config, credentials and tools; print the work queue; no connection
./teradata_extract.sh --dry-run

# show the state summary; no connection
./teradata_extract.sh --status

# resume after a failure (exit 1) or interruption (exit 130): just rerun.
# Done tables and done chunks are skipped; in_progress items are redone.
./teradata_extract.sh

# start a new CDC cycle: all tables back to pending, watermarks kept
# (CDC tables export only rows changed since the last committed watermark)
./teradata_extract.sh --new-cycle

# re-extract one table from scratch (watermark kept) ...
./teradata_extract.sh --reset-table SALES.ORDERS --tables SALES.ORDERS
# ... or also clear its CDC watermark (next export is a full extract)
./teradata_extract.sh --reset-watermark SALES.CUSTOMER --tables SALES.CUSTOMER
```

Exit codes: `0` all queued tables done, `1` at least one table failed, `2` configuration /
credential / tool / lock error (nothing extracted), `130` interrupted (state saved,
resumable).

## Output

For each table:

- `data/<db>_<table>[.partNNN].dat`: pipe-delimited records terminated by LF, ASCII or UTF-8
  (`session_charset`). Large tables produce one file per chunk (`.part001`, ...).
- `data/<db>_<table>_<cycle_id>.zip`: the table's files, zipped and integrity-tested. The
  raw `.dat` files are deleted afterwards unless `keep_raw_after_zip = true`.
- `metadata/<db>_<table>.meta.ini`: table and column metadata, including the output
  encoding and Redshift type of each column.
- `metadata/audit.log`: one line per table per run.

Encoding rules: NULL is `\N`. A zero-length string is `\E`. Inside text values, `\`, `|`,
CR and LF are escaped with a preceding `\`. Decimals with precision > 18 are quoted with
`"`.

Example (`ORDER_ID INTEGER | NAME VARCHAR | NOTE VARCHAR | AMOUNT DECIMAL(20,2)`):

```
1001|ACME Corp|Rush \| fragile|"123456789012345678.25"
1002|\N|\E|"15.00"
1003|Smith \\ Sons|\N|\N
```

In row 1001, NOTE is `Rush | fragile`. In row 1002, NAME is NULL and NOTE is an empty
string. In row 1003, NAME is `Smith \ Sons`.

For Redshift, use `COPY ... DELIMITER '|' ESCAPE NULL AS '\\N'`. With `ESCAPE`, `\E` would
load as the letter `E` and quoted big decimals do not load into `DECIMAL`. So for direct
loads, set `empty_sentinel =` and `big_decimal_quote =` (both empty). The alternative is
the VARCHAR-staging approach described in section 20 of the
[user guide](config/utility_user_guide.txt). Validate the load on the target cluster.

## Type mapping (summary)

| Teradata | Output | Redshift |
|---|---|---|
| BYTEINT, SMALLINT / INTEGER / BIGINT | plain integer | SMALLINT / INTEGER / BIGINT |
| DECIMAL / NUMBER p<=18 | plain decimal | DECIMAL(p,s) |
| DECIMAL / NUMBER p>18, unbounded NUMBER | `"`-quoted decimal | DECIMAL(p,s) (p<=38) else VARCHAR |
| FLOAT / REAL / DOUBLE | 17 significant digits, `E+nnn` | FLOAT8 |
| DATE / TIME / TIMESTAMP | `YYYY-MM-DD` / `HH:MI:SS[.f]` / `YYYY-MM-DDTHH:MI:SS[.f]` | DATE / TIME / TIMESTAMP |
| TIME / TIMESTAMP WITH TIME ZONE | converted to UTC, trailing `Z` | TIMETZ / TIMESTAMPTZ |
| INTERVAL, PERIOD | CAST to VARCHAR | VARCHAR(n) |
| CHAR / VARCHAR | escaped text (CHAR trimmed per `char_trim`) | CHAR(n) / VARCHAR(n), x4 for UNICODE |
| CLOB / JSON / XML | escaped text up to `lob_max_length` | VARCHAR(65535) |
| BYTE / VARBYTE / BLOB | hexadecimal | VARBYTE(n) |
| UDT, ARRAY, other | table fails (never lossy) | |

The full table is in [docs/DESIGN.md](docs/DESIGN.md) section 8.

## Testing

```sh
python3.12 -m unittest discover -s tests -v
```

The tests use only the standard library and do not need a Teradata system. `tests/fakes/fexp`
and `tests/fakes/bteq` are executable Python stand-ins. They are selected with the
`TDX_FEXP` / `TDX_BTEQ` environment variables and driven by a JSON fixture named in
`TDX_FAKE_FIXTURE`. They read the generated script from stdin, answer each marked
request, write raw export files in the real tool layouts, and can simulate failures such
as `Failure 2633`.

## Limitations

- **Not yet validated against a live Teradata 16.20 system.** All testing so far uses the
  fake `fexp`/`bteq` tools.
- The raw FastExport / BTEQ export layouts are auto-detected (with or without the
  record-length prefix and end-of-record byte). Confirm this on your TTU version.
- Error codes and message texts for session limits vary by release and workload rules.
  Check `session_limit_errors` / `session_limit_patterns` against your site's message
  catalog and real tool output.
- The Redshift loading recommendations must be validated on the target cluster.
- CDC captures inserts and updates through the CDC column. It does not capture deletes.
- Only the `pipe-delimited` file format is supported.
