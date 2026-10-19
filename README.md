# Polymarket Calibration

**Status: Phase 1 (data profiling). No results yet. Hypotheses will be
pre-registered in `docs/` before any price is compared with any outcome.**

This project asks whether Polymarket prices behave as calibrated probabilities,
and whether calibration differs between crypto markets and politics, sports and
other categories. The unit of analysis is the market. Each resolved binary
market contributes one price snapshot per fixed horizon before resolution
(1 week, 1 day, 1 hour), taken as the last trade before that horizon.

## Data

[`SII-WANGZJ/Polymarket_data`](https://huggingface.co/datasets/SII-WANGZJ/Polymarket_data)
(MIT), pinned to commit `73bc1adc` (release of 2026-10-05, trades through
2026-10-04 23:59:59 UTC). Two of its five files are used:

- `trades.parquet`: 1,266,885,846 on-chain CLOB fills (45.8 GB)
- `markets.parquet`: 4,049,900 markets of metadata (0.5 GB)

Neither file is downloaded in full. DuckDB queries them in place over `hf://`,
reading only the columns and row groups a query needs. Focused subsets are
written to `data/processed/` (git-ignored). The data profile, including the
issues that affect the design, is in [`docs/data_profile.md`](docs/data_profile.md).

## Layout

```text
sql/00_profile/       schema and data profiling (no outcome comparisons)
sql/01_staging/       typed, deduplicated, real-user trades; resolved binary markets
sql/02_intermediate/  per-market price paths, per-wallet trade histories
sql/03_marts/         market snapshots at each horizon, wallet track records
pipeline/run_sql.py   runs .sql files in one DuckDB session
notebooks/            statistics and figures
docs/                 data profile, pre-registration
```

All SQL lives in numbered `.sql` files. Python handles statistics and figures.

## Reproducing

```bash
python -m venv .venv && .venv/bin/pip install -r requirements.txt
export HF_TOKEN=...   # optional, avoids anonymous rate limits
.venv/bin/python pipeline/run_sql.py sql/00_profile/00_sources.sql sql/00_profile/01_schema.sql
```
