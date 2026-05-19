# audit-trail-reporter

An AML (Anti-Money Laundering) compliance toolkit written in the
[Capa](https://github.com/nelsonduarte/capa-language) language.
Reads a JSONL transaction log, runs four detection rules
(threshold, watchlist, structuring, velocity), aggregates per
day and per account, and emits four reports (CSV aggregates,
CSV account summary, full JSON detail, human-readable
`alerts.txt`).

**Why this exists.** Capa is a capability-typed language. Toy
examples do not exercise enough surface to convince a
compliance team that the capability story holds at real-program
scale. This project is a multi-module program that touches
every part of Capa: built-in capabilities (`Fs`, `Stdio`, `Env`,
`Clock`), capability *attenuation* (read-only `Fs` for inputs,
write-only `Fs` for outputs), three of the seed Capa libraries
(`capa_cli`, `capa_datetime`, `capa_log`), user-defined
capabilities (`Logger`), sum types with payloads, pattern
matching, the `?` operator, the manifest emitter.

## The business problem

A compliance team needs daily audit reports off a stream of
financial transactions. Each line of the input is a transaction;
four detection rules run against the list, every flag is tied
back to a named rule, and the outputs go to a fixed directory
for the auditor's morning review.

### Detection rules (v0.2)

| Rule          | Fires when                                                                                              | Risk     |
|---------------|---------------------------------------------------------------------------------------------------------|----------|
| `threshold`   | Amount >= 10000                                                                                          | Critical |
| `threshold`   | Amount >= 1000                                                                                           | High     |
| `watchlist`   | Destination account matches a prefix from the watchlist file (or built-in default)                       | Critical |
| `structuring` | >= 3 transactions from the same source on the same day, each under 10000, totalling >= 10000             | Critical |
| `velocity`    | Source account peaks at >= 5 transactions in a day while the second-busiest day had <= 2                 | High     |

A transaction may be hit by several rules; the final
`risk` is the strongest verdict and `findings[]` lists every
rule that fired with its own reason. A transaction that no rule
flagged is classified by amount alone (Low if < 100, Medium
otherwise) and contributes to volume aggregates but not to the
alerts file.

## Repo layout

```
.
├── reporter.capa              entry point, CLI, attenuated Fs split
├── domain.capa                shared types (Transaction, Finding, ...)
├── parsing.capa               JSONL -> Transaction
├── rules.capa                 the four rule functions (pure)
├── engine.capa                run rules + merge findings
├── aggregation.capa           daily + per-account rollups
├── sinks/
│   ├── csv_sink.capa          aggregates + accounts CSV
│   ├── json_sink.capa         full JSON detail
│   └── alerts_sink.capa       human-readable alerts.txt
├── data/
│   ├── transactions.jsonl     37-transaction sample, 7 days
│   └── watchlist.txt          prefix watchlist (# comments OK)
├── libraries/                 vendored Capa seed libraries
│   ├── capa_cli/
│   ├── capa_datetime/
│   └── capa_log/
├── LICENSE                    MIT
└── README.md
```

## Run it

Prerequisites: a Capa toolchain that includes the multi-module
loader fix and the `--` arg pass-through (Capa >= 0.8.4, commit
`4c4511b` or newer).

From the repo root:

```bash
capa --run reporter.capa -- data/transactions.jsonl --watchlist data/watchlist.txt
```

Expected output:

```
[INFO] reading data/transactions.jsonl
[INFO] parsed 37 transactions
[INFO] loaded 3 watchlist prefix(es) from data/watchlist.txt
[WARN] [threshold] tx-2026-010: amount 3200.0 >= 1000.0
[WARN] [structuring] tx-2026-010: structuring: 4 txs from 'acc-7777' on 2026-05-15 totalling 12600.0, each under threshold
... (15 flagged transactions total)
[INFO] wrote ./aggregates-2026-05-19.csv
[INFO] wrote ./accounts-2026-05-19.csv
[INFO] wrote ./report-2026-05-19.json
[INFO] wrote ./alerts-2026-05-19.txt
[WARN] 15 flagged transaction(s) need review
audit-trail-reporter: success
```

### Options

```
Usage: audit-trail-reporter [FLAGS] [OPTIONS] INPUT

Arguments:
  INPUT                 path to a JSONL transaction log
                        (must live under data/, see Audit section)

Flags:
  -v, --verbose         enable DEBUG-level logging

Options:
  -w, --watchlist STR   path to watchlist file (one prefix per line)
  -o, --output-dir STR  directory for report files (default: cwd)
      --min-amount STR  drop transactions below this amount (default: 0)
  -d, --date STR        restrict to a single YYYY-MM-DD day (default: all)
```

Example invocations:

```bash
# Built-in default watchlist (matches "acc-WATCHLIST*").
capa --run reporter.capa -- data/transactions.jsonl

# Verbose run.
capa --run reporter.capa -- data/transactions.jsonl --verbose

# Single-day report.
capa --run reporter.capa -- data/transactions.jsonl --date 2026-05-17

# Material transactions only (>= 1000).
capa --run reporter.capa -- data/transactions.jsonl --min-amount 1000

# Write reports to a dedicated directory (must exist).
mkdir reports
capa --run reporter.capa -- data/transactions.jsonl --output-dir reports
```

## The audit story

Run `capa --manifest reporter.capa` and the surface looks like:

```
USER-DEFINED CAPABILITIES: Logger (impl StdioLogger)

TOP-LEVEL FUNCTION CAPABILITIES:
  threshold_rule              pure
  watchlist_rule              pure
  structuring_rule            pure
  velocity_rule               pure
  classify_all                pure
  merge_into_classified       pure
  apply_filters               pure
  daily_aggregates            pure
  account_summaries           pure
  render_aggregates_csv       pure
  render_accounts_csv         pure
  render_report_json          pure
  render_alerts               pure
  read_transactions           [Fs]
  load_watchlist              [Fs]
  write_csv                   [Fs]
  write_json                  [Fs]
  write_alerts                [Fs]
  run                         [Logger, Fs, Fs]
  main                        [Stdio, Fs, Env, Clock]
```

Every rule and every aggregator is **pure**. They cannot read
the filesystem, mint a string and print it, or call out to a
clock. A diff that added a stray `stdio.println` inside
`structuring_rule` would fail to compile because the rule's
signature does not take `stdio: Stdio`.

The user-defined `Logger` capability adds a second layer: `run`
declares `[Logger, Fs, Fs]`, **not** `[Stdio, Fs, Fs]`. The
`Stdio` is handed over to `make_stdio_logger` once in `main`
and never seen again past that boundary.

### Capability attenuation

`main` acquires a single `Fs` from the runtime. Before anything
useful happens, it splits that one cap into two narrower ones:

```capa
let read_fs  = fs.restrict_to("data/")
let write_fs = fs.restrict_to(opts.output_dir)
```

- `read_fs` is passed to `read_transactions` and `load_watchlist`.
  Any path the runtime's `Fs.allows` does not see as starting
  with `"data/"` is rejected at runtime. The parser cannot
  reach `/etc/passwd` even if it tried.
- `write_fs` is passed to the three sinks. They cannot read
  arbitrary files even though their declared cap is still `Fs`.

Two `Fs`s in `run`'s signature, with disjoint authority. The
audit manifest doesn't display the attenuation prefixes
(they're runtime data), but the code structure shows that no
sink ever sees the read Fs, and no parser ever sees the write
Fs.

## What this program exercises in Capa

- **Multi-module project**: 9 `.capa` files including a
  `sinks/` subdirectory, all linked transitively via `import`.
  Demonstrates Capa's resolution order (importer-local,
  CAPA_PATH, ./libraries, project root).
- **All four built-in caps**: `Fs` (input + watchlist read,
  four file writes), `Stdio` (CLI errors), `Env` (CLI args),
  `Clock` (report timestamp).
- **User-defined `Logger`** capability via capa_log, with a
  cap-bearing `StdioLogger` impl holding the real `Stdio`.
- **Capability attenuation**: `Fs.restrict_to` splits authority
  across the read and write halves of the pipeline.
- **Sum types with + without payloads**:
  - `ReportError = JsonError(String) | IoFailed(String) | BadArgs(String)`
  - `RiskCategory = Low | Medium | High | Critical`
- **The `?` operator** for error propagation, used throughout
  `parsing.capa`, `load_watchlist`, and every sink writer.
- **Nested variant patterns** (`Err(HelpRequested) -> ...`).
- **UPPERCASE constants** (`CRITICAL_AMOUNT`, `DEBUG`, `INFO`,
  ...) that previously crashed the transpiler; this program is
  a regression demo for that fix as well.
- **String interpolation**, `Map`, `List`, `Option`, `Result`
  method surfaces, plus `parse_json` / `to_json`.
- **Three seed libraries**, vendored into `libraries/`:
  - `capa_cli` for argument parsing
  - `capa_datetime` for ISO 8601 timestamp parsing + date formatting
  - `capa_log` for levelled logging

## Limitations

This is a demo, not a production deployment. v0.2 ships
deliberately tight:

- **No streaming**. The whole file is read into memory before
  parsing. For million-line logs a future iteration would
  switch `Fs.read` for a line iterator.
- **No HTTP enrichment**. Watchlist comes from a file, not a
  regulator's API. Swapping in `capa_http` (vendored already
  in the language repo) is a 30-line diff: replace
  `load_watchlist` with a call into the `Http` cap.
- **Single-currency**. The `currency` field is preserved in the
  output but no FX conversion happens; all amounts compare
  numerically. A v3 iteration would add a `Rates` capability
  for daily exchange rates.
- **Watchlist is exact-prefix match**. No regex, no fuzzy
  matching, no Unicode normalisation.
- **`Fs.restrict_to("data/")` is a string-prefix check**. A
  symlinked path or a `data/../etc/passwd` traversal would
  bypass it; the v1 attenuation is not the full POSIX-aware
  containment a hostile setting needs. The Capa runtime ticket
  for proper path canonicalisation tracks this.

## License

MIT. See [LICENSE](./LICENSE).
