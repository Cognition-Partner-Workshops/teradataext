# teradataext

A small extraction utility for **Teradata Database 16.20** on UNIX/Linux (Linux, AIX,
Solaris). It uses FastExport (`fexp`) for bulk data and BTEQ (`bteq`) for metadata, small
tables and LOB tables, and writes pipe-delimited files that load into Amazon Redshift (or
similar). It is written in bash 4.2+ and POSIX awk and needs only standard UNIX tools
plus Teradata Tools and Utilities 16.20.

It replaces the former Python 3.12 engine (`src/extract.py`, still available in the git
history) with the same behaviour, except that per-table archives are now `.tar.gz`
instead of `.zip`.

- Interface contract (config keys, CLI, file names, state format, type mapping, exit
  codes): [docs/DESIGN.md](docs/DESIGN.md)
- Operator guide: [config/utility_user_guide.txt](config/utility_user_guide.txt)

## Features

- FastExport for bulk exports, BTEQ EXPORT for small tables/chunks and LOB tables, plus
  a BTEQ fallback when FastExport keeps hitting session limits.
- Automatic chunking of large tables: range chunks on a numeric/DATE single-column PK/PI
  (NULLs go to chunk 1), otherwise `HASHBUCKET(HASHROW(PI)) MOD n`. You can override the
  chunk column per table.
- `source_tables.ini`: list all tables of a database in one section
  (`table = {REGION, ORDERS, ...}`), with optional one-table sections for CDC, chunk
  column and `where` filter.
- Parallel jobs within a Teradata session budget (`parallel`, `max_sessions`).
- Retry on session-limit errors, halving the session count on each retry.
- Resumable: state is saved atomically after every chunk. Tables and chunks already done
  are skipped on rerun.
- CDC / incremental extraction with a watermark column. The upper bound is captured
  first, and the watermark is committed only after the table finishes successfully.
- Never lossy: a table fails rather than truncate LOBs or long records, export
  unsupported types, or export non-LATIN data in an ASCII session.
- A metadata file per table with Teradata and Redshift types, an append-only audit log,
  a `.tar.gz` archive per table with integrity test, and an executive summary at exit.
- Passwords never touch disk. Credentials come from `TD_USER`/`TD_PASS` or a 0600 file,
  and scripts and logs are masked.

## Layout

```
teradata_extract.sh               entrypoint
lib/                              engine: *.sh (bash 4.2+) and *.awk (POSIX awk)
config/
  main_config.ini                 main configuration (user-maintained)
  source_tables.ini               tables to extract (user-maintained)
  process_state.ini               extraction state (MACHINE-MANAGED, created on first run)
  process_state.ini.example       sample of the state format
  credentials.ini.example         credentials file template
  utility_user_guide.txt          operator guide
docs/DESIGN.md                    interface contract
tests/                            bash test suite (run_tests.sh) + fake fexp/bteq (tests/fakes)
metadata/                         <db>_<table>.meta.ini, audit.log        (created at run)
data/                             <db>_<table>[.partNNN].dat, *.tar.gz    (created at run)
logs/                             run log, per-job tool output (masked)   (created at run)
work/                             generated scripts (masked), lock dir    (created at run)
```

## Prerequisites

- bash >= 4.2
- a POSIX awk: gawk, mawk, nawk / onetrue awk, or busybox awk, selected with `TDX_AWK`
  (arguments allowed, e.g. `TDX_AWK="busybox awk"`). When it is unset, Solaris uses
  `/usr/xpg4/bin/awk` if it exists, otherwise `awk` from PATH. mawk or gawk is
  recommended, see [Performance](#performance).
- `od`, `gzip`, `tar`, `mkfifo`
- one SHA-256 tool, the first found of `sha256sum`, `shasum -a 256`,
  `openssl dgst -sha256`, `digest -a sha256` (Solaris)
- Teradata Tools and Utilities 16.20: `fexp` and `bteq` on PATH (or `fexp_path` /
  `bteq_path`)
- `bc` (POSIX), only for range chunks on DECIMAL/NUMBER keys with a scale or integer keys
  longer than 18 digits; without it such a table fails with a clear error

Supported systems: Linux, AIX, Solaris. At startup the entrypoint always checks bash
>= 4.2, the awk and `od`. Unless `--status` or `--help` is given, it also checks `gzip`,
`tar`, `mkfifo`, a SHA-256 tool and `fexp`/`bteq`. A missing item means exit code 2.
Details: section 2 of the [user guide](config/utility_user_guide.txt).

## Quick start

```sh
# 1. prerequisites (see above)
bash --version && which awk od gzip tar fexp bteq

# 2. configure
vi config/main_config.ini          # [teradata] host, logtable_database, ...
vi config/source_tables.ini        # tables to extract

# 3. credentials (preferred: environment variables)
export TD_USER=etl_user
read -s TD_PASS && export TD_PASS
# export TDX_AWK=/usr/bin/mawk            # optional: faster awk (see Performance)

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
credential / tool / lock error (nothing extracted), `130` interrupted by SIGINT/SIGTERM
(running fexp/bteq jobs are stopped, state saved, resumable).

Environment variables: `TD_USER` / `TD_PASS` (credentials), `TDX_AWK` (awk command,
arguments allowed), `TDX_FEXP` / `TDX_BTEQ` (override `fexp_path` / `bteq_path`).

Only one instance runs at a time per work directory. The lock is the directory
`work/.process_state.lock/`, which holds the pid of the running instance. A lock left by a
killed run is removed automatically when that pid no longer exists. To clear it by hand,
check that no instance is running (`ps -p $(cat work/.process_state.lock/pid)`), then
`rm -rf work/.process_state.lock`. Per-run temporary files go in `work/.tdx-run-<pid>/`,
which is removed at exit.

## Output

For each table:

- `data/<db>_<table>[.partNNN].dat`: pipe-delimited records terminated by LF, ASCII or UTF-8
  (`session_charset`). Large tables produce one file per chunk (`.part001`, ...).
- `data/<db>_<table>_<cycle_id>.tar.gz`: the table's files, archived with
  `tar cf - ... | gzip -c` and integrity-tested (`gzip -t`, and the member list from
  `gzip -dc | tar tf -` must equal the expected `.dat` names) before the rename to
  `.tar.gz`; its SHA-256 is recorded in the state file. The raw `.dat` files are deleted
  afterwards unless `keep_raw_after_zip = true`. The config keys `zip_on_complete` /
  `keep_raw_after_zip` and the state keys `zip_file` / `zip_sha256` keep their names but
  refer to the `.tar.gz`. The summary line reads `Files written : N (.dat) / M (.tar.gz)`.
  Unpack portably (also with AIX/Solaris tar):
  `gzip -dc sales_orders_<cycle_id>.tar.gz | tar xf -`.
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

## Performance

Raw fexp/bteq export files are decoded into `.dat` files with `od` + awk
(`lib/rawdecode.awk`). Decoding runs after the export of each job (table or chunk), per
chunk, and each job decodes independently. Measured decoder throughput for a 48 MB /
200,000-record raw file:

| awk | throughput |
|---|---|
| mawk | ~4 MB/s |
| gawk | ~3.3 MB/s |
| onetrue awk (typical AIX/Solaris nawk-class) | ~1.2 MB/s |
| busybox awk | ~0.6 MB/s |
| former engine, for comparison | ~230 MB/s |

Use mawk or gawk where available (`export TDX_AWK=/usr/bin/mawk`), and for big tables run
more parallel jobs (`parallel`, smaller `chunk_rows`) so that chunks decode in parallel.
See section 13 of the [user guide](config/utility_user_guide.txt).

## Testing

```sh
tests/run_tests.sh               # with the default awk
tests/run_tests.sh --awk mawk    # with a given awk (gawk, mawk, original-awk, busybox awk)
```

The tests are plain bash and do not need a Teradata system. `tests/fakes/fexp` and
`tests/fakes/bteq` are bash + awk stand-ins selected with the `TDX_FEXP` / `TDX_BTEQ`
environment variables and driven by plain-text fixtures (see
[tests/fakes/README.md](tests/fakes/README.md)). They read the generated script from
stdin, answer each marked request, write raw export files in the real tool layouts, and
can simulate failures such as `Failure 2633`. `tests/golden/<scenario>/` holds normalized
outputs captured from the former engine; the golden tests rerun the same scenarios and
compare the outputs byte for byte after the same normalization.

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
- A NUL (0x00) byte inside a record fails the job: portable awks cannot write NUL bytes,
  and the utility never drops data silently.
- Raw decoding is much slower than in the former engine (see [Performance](#performance)).
- Range chunks on DECIMAL/NUMBER keys with a scale or integer keys longer than 18 digits
  need `bc`. Boundaries of keys with a scale are computed with 10 decimal places beyond that scale, so the literals
  may differ textually from the former engine. Every value (NULL and out-of-range
  included) is still covered.
