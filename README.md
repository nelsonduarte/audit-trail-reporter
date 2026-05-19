# audit-trail-reporter

A real-world demo program built in the [Capa](https://github.com/nelsonduarte/capa-language)
language. Reads a JSONL transaction log, classifies each
transaction by risk, aggregates by day, and emits a CSV
summary plus a JSON detail report.

**Why this exists.** Capa is a capability-typed language. Toy
examples ("print hello") do not exercise enough surface to
convince a compliance team that the capability story holds at
real-program scale. This project is a single program that
touches every part of Capa: built-in capabilities (`Fs`,
`Stdio`, `Env`, `Clock`), three of the seed Capa libraries
(`capa_cli`, `capa_datetime`, `capa_log`), user-defined
capabilities (`Logger`), sum types with payloads, pattern
matching, the `?` operator, the manifest emitter.

## The business problem

A compliance team needs daily audit reports off a stream of
financial transactions. Each line of the input is a
transaction; the program classifies risk, aggregates per day
and per risk category, and emits machine-readable outputs that
feed into the auditor's morning review.

Risk policy (hard-coded in `reporter.capa` so this demo is
self-contained):

| Trigger                                 | Category  |
|-----------------------------------------|-----------|
| Destination starts with `acc-WATCHLIST` | Critical  |
| Amount >= 10000                         | Critical  |
| Amount >= 1000                          | High      |
| Amount >= 100                           | Medium    |
| otherwise                               | Low       |

The watchlist rule wins over the amount rule so the flagged
reason on the report says **why** the row was flagged, not just
that it crossed a threshold.

## Run it

Prerequisites: the Capa toolchain installed
(`pip install capa-language` or a clone of the
[Capa repo](https://github.com/nelsonduarte/capa-language)).

From the repo root:

```bash
capa --run reporter.capa -- data/transactions.jsonl
```

That is the whole command. The `./libraries/` directory is
picked up automatically (Capa's default fallback when no
`CAPA_PATH` is set), and anything after `--` is forwarded to
the program as `env.args()`.

You should see:

```
[INFO] reading data/transactions.jsonl
[INFO] parsed 10 transactions
[WARN] flagged tx-2026-004: amount 15000.0 >= 10000.0
[WARN] flagged tx-2026-005: destination 'acc-WATCHLIST-01' on watchlist
[WARN] flagged tx-2026-009: destination 'acc-WATCHLIST-02' on watchlist
[WARN] flagged tx-2026-010: destination 'acc-WATCHLIST-01' on watchlist
[INFO] wrote out/report-2026-05-19.csv
[INFO] wrote out/report-2026-05-19.json
[WARN] 4 flagged transaction(s) need review
audit-trail-reporter: success
```

(The `2026-05-19` part of the filename comes from the system
clock at run time.)

### Options

```
Usage: audit-trail-reporter [FLAGS] [OPTIONS] INPUT

Arguments:
  INPUT                 path to a JSONL file of transactions

Flags:
  -v, --verbose         enable DEBUG-level logging

Options:
  -o, --output-dir STR  directory for report files (default: cwd)
      --min-amount STR  drop transactions below this amount (default: 0)
  -d, --date STR        restrict to a single YYYY-MM-DD day (default: all)
```

Examples:

```bash
# Verbose run with DEBUG logging.
capa --run reporter.capa -- data/transactions.jsonl --verbose

# Single-day report.
capa --run reporter.capa -- data/transactions.jsonl --date 2026-05-19

# Only material transactions.
capa --run reporter.capa -- data/transactions.jsonl --min-amount 1000

# Output to a specific directory (must exist).
mkdir reports
capa --run reporter.capa -- data/transactions.jsonl --output-dir reports
```

## The audit story

This is what makes the demo *Capa*-specific. Run:

```bash
capa --manifest reporter.capa
```

The manifest emits the authority each function holds. The
relevant lines:

```
make_stdio_logger    [Stdio]
read_transactions    [Fs]
run                  [Logger, Fs]
main                 [Stdio, Fs, Env, Clock]
classify             []           (pure)
aggregate            []           (pure)
parse_transaction    []           (pure)
report_to_json       []           (pure)
```

Every classifier, parser, and aggregator declares **no
capabilities**. They cannot reach for the filesystem; they
cannot read the clock; they cannot mint a string and print it.
This is enforced by the Capa analyzer, not by convention. A
diff that adds a stray `stdio.println` inside `classify` would
fail to compile because `classify` does not take `stdio: Stdio`
in its signature.

The result: an auditor reading the manifest can be sure that
*only* `read_transactions`, `run`, and `main` ever touch I/O.
The business logic is provably pure.

The user-defined `Logger` capability provides a second layer:
`run` declares `[Logger, Fs]`, **not** `[Stdio, Fs]`. The
`Stdio` is handed over to `make_stdio_logger` once in `main`
and never again. The audit shows that `run` could not bypass
the logger to write directly to stdout even if it wanted to.

## What this program exercises in Capa

Capa features touched, in roughly the order they show up:

- **User-defined capabilities** (`Logger`, via `capa_log`) and
  cap-bearing structs (`StdioLogger` holding `stdio: Stdio`).
- **Built-in capabilities**: `Fs` for reading + writing,
  `Stdio` for error output, `Env` for CLI args, `Clock` for
  the report timestamp.
- **Sum types with payloads** (`ReportError = JsonError(String)
  | IoFailed(String) | BadArgs(String)`) and payload-less sums
  (`RiskCategory = Critical | High | Medium | Low`).
- **The `?` operator** for error propagation, used throughout
  `read_transactions` and `parse_transaction`.
- **Pattern matching** including nested variants
  (`Err(HelpRequested) -> ...`).
- **UPPERCASE constants** (`DEBUG`, `INFO`, `WARN`, `ERROR`,
  `WATCHLIST_PREFIX`) that previously crashed the transpiler;
  this program is a regression demo for that fix.
- **String interpolation** (`"line ${line_no}: ..."`) and the
  full `Map`/`List`/`Option`/`Result` method surface.
- **Three seed libraries**, vendored into `libraries/`:
  - [`capa_cli`](libraries/capa_cli/): argument parsing
  - [`capa_datetime`](libraries/capa_datetime/): timestamp
    parsing + date formatting
  - [`capa_log`](libraries/capa_log/): levelled logging

## Repo layout

```
.
├── reporter.capa              the program
├── data/transactions.jsonl    sample input (10 transactions, 2 days)
├── libraries/                 vendored Capa seed libraries
│   ├── capa_cli/
│   ├── capa_datetime/
│   └── capa_log/
├── LICENSE                    MIT
└── README.md
```

## Limitations

This is a demo, not a production deployment. v1 deliberately
ships small:

- **Watchlist is hard-coded** to `acc-WATCHLIST*`. A real
  deployment would either load the watchlist from a file
  (one more `Fs` read) or call out to a regulator's HTTP
  endpoint (the `capa_http` seed library handles that
  shape; it is not vendored here to keep the demo
  self-contained and offline).
- **Output directory must exist**. Capa's `Fs` capability
  exposes `read` and `write` but not `mkdir`; if you pass
  `--output-dir reports/`, create `reports/` manually first.
  The default is the current directory, which already exists.
- **No streaming**. The whole input file is read into memory
  and parsed line-by-line. For a million-line log this would
  be replaced by a line-iterator on the `Fs` cap (planned in
  a future Capa release).
- **No CSV escaping**. Categories and amounts never contain
  commas in the demo policy; a generic CSV writer would
  quote-escape these.

## License

MIT. See [LICENSE](./LICENSE).
