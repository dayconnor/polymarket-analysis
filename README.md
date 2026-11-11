# Polymarket Calibration

**Status: Phase 2 (pipeline and validation). No calibration results yet.**
The hypotheses were pre-registered in [`docs/hypotheses.md`](docs/hypotheses.md)
(`bc6dca3`, 2026-10-21) before any price was compared with any outcome. Staging,
price paths, horizon snapshots, the subject classifier, the on-chain resolution
check and the wallet extract with its contract check (C5) are complete; the wallet
track-record mart for RQ3 and the analysis notebooks are next.

This project asks whether Polymarket prices behave as calibrated probabilities,
and whether calibration differs between crypto markets and politics, sports and
other categories. The unit of analysis is the market. Each resolved binary
market contributes one price snapshot per fixed horizon before resolution
(1 week, 1 day, 1 hour), taken as the last trade of at least $1 before that
horizon.

## Research questions

Fixed in the pre-registration; none has been tested.

1. **RQ1 (primary).** Within each horizon × format cell, the calibration slope
   (logistic regression of `token1_won` on logit(price)) differs between crypto
   and non-crypto markets. Six interaction tests, Holm–Bonferroni at family-wise
   α = 0.05, cluster-robust standard errors (pre-registration Section 3).
2. **RQ2.** Low-probability outcomes (< 10¢) are overpriced, and the bias shrinks
   with liquidity (1-day horizon).
3. **RQ3.** Net buying by wallets with strong prior track records, computed only
   from markets already resolved at the snapshot, predicts outcomes beyond the
   price.

Departures from the registered design are logged, with dates, in Section 9 of the
pre-registration (D1–D5) before the affected result exists.

## Data

[`SII-WANGZJ/Polymarket_data`](https://huggingface.co/datasets/SII-WANGZJ/Polymarket_data)
(MIT), pinned to commit `73bc1adc` (release of 2026-10-05, trades through
2026-10-04 23:59:59 UTC). Two of its five files are used:

- `trades.parquet`: 1,266,885,846 on-chain CLOB fills (45.8 GB)
- `markets.parquet`: 4,049,900 markets of metadata (0.5 GB)

Neither file is downloaded in full. DuckDB queries them in place over `hf://`,
reading only the columns and row groups a query needs; focused extracts are
written to `data/processed/` (git-ignored). Two further sources were added after
profiling: the Polymarket Gamma API for resolution status and `closedTime`
(fetched 2026-10-20/21, live and unpinned, every row stamped with `fetched_at`),
and Polygon archive state from the Conditional Tokens contract for the resolution
check. The data profile, including the eleven design threats (T1–T11) that shaped
the pre-registration, is in [`docs/data_profile.md`](docs/data_profile.md).

## Progress

| Layer | File | Output and result |
| --- | --- | --- |
| Staging | `01_staging/00`–`02`, `pipeline/fetch_gamma.py` | 2,205,956 resolved binary markets kept of 2,223,448 requested from Gamma; 17,492 excluded, each under its first failing rule (12,929 voided 0.5/0.5, 2,758 ever disputed, 1,039 not finalized, 766 other). |
| Staging | `01_staging/03`–`04` | Trade view and data-quality checks C1–C4 (price in [0, 1], side mapped, every trade joins a market, unique `(block_number, log_index)`): 0 violations over all 1,266,885,846 fills. |
| Intermediate | `02_intermediate/01_int_price_paths.sql` | All trades of the kept markets, full history: 1,077,447,561 rows (6.8 GB). 1,009 kept markets have no trades. No outcome column. |
| Marts | `03_marts/01_mart_snapshots.sql` | 1,925,812 (market, horizon) snapshots. Primary population (within the staleness cap, volume ≥ $1,000): 78,156 / 351,535 / 371,676 markets at 1 week / 1 day / 1 hour. A window-function recompute on 2,000 random markets matched every row. |
| Classifier | `02_intermediate/02`–`04`, [`docs/classifier_codebook.md`](docs/classifier_codebook.md) | Rule-based subject (crypto, politics, sports, weather, other) and format (template, event) from text fields only, frozen before validation. Passes round 1 (below). |
| Resolution check | `02_intermediate/05`–`07`, `pipeline/fetch_onchain_resolution.py` | Gamma payouts and `closedTime` verified against on-chain resolutions. Passes every stop rule (below). |
| Intermediate | `02_intermediate/08_int_wallet_trades.sql` | Every fill with maker, taker and directions, full file, for RQ3: 1,266,885,846 rows (18.1 GB). C5 (no exchange, adapter or CTF contract as maker or taker; well-formed wallets and directions): 0 violations, with an in-file planted-row control firing once per check. Only BUY/SELL pairs occur; 905 fills are self-trades (maker = taker). |

## Validation

**Classifier (pre-registration Section 6).** 400 markets, 80 per predicted
subject, drawn with a fixed seed after the rules were frozen. Labels were drafted
by the assistant that wrote the rules and reviewed by the author, who changed 3
rows (D5); the labels are therefore not independent of the rules, which biases
agreement upward. Metrics are weighted by stratum size in the sampling frame.

| Metric | Value | Threshold |
| --- | ---: | ---: |
| Crypto precision | 1.000 (80/80) | ≥ 0.95 |
| Crypto recall | 0.994 | ≥ 0.95 |
| Format accuracy | 0.987 | ≥ 0.95 |
| Subject accuracy (descriptive) | 0.982 | — |

The precision estimate has an exact 95% lower bound of about 0.963. Recall rests on
a single crypto-labeled market outside the crypto stratum; zero crypto labels in 80
draws from the sports stratum (N = 275,223) cannot rule out a crypto share near
3.7% there, so the recall bound is wide. Errors concentrate in the fallback
`other` subject (accuracy 0.825), where politics and sports questions without a
matching keyword land, and in weekly chart and post-count ladders labeled event
instead of template. Neither affects the crypto/non-crypto split that RQ1 tests.

**Resolution (pre-registration Section 7 and D4).** 200 random kept markets plus
30 per subject × format cell (470 in all). For each, the final payout, resolution
block, `ConditionResolution` event and the position id behind each outcome slot
were read from the Conditional Tokens contract on Polygon.

- Payout agreement with the staged outcome: 200/200 on the random arm (stop rule:
  < 99%), 0 disagreements in each of the 9 cells (stop rule: ≥ 2 per cell). With
  200/200, the exact 95% lower bound on agreement is about 0.985.
- Payout slot 1 is `token1` in 470/470 markets (312 standard, 158 neg-risk), which
  confirms the token1 price rule and outcome definition.
- Gamma `closedTime` equals the resolution block time in 97.5% of the random arm
  and lies within 60 s in 99%; the range is −2,094 s to +6 s. `closedTime`
  therefore never falls meaningfully after on-chain resolution, so snapshots
  anchored on it carry no look-ahead.

Only kept markets were checked; excluded (voided, disputed) markets were not.

## Layout

```text
sql/00_profile/       schema and data profiling (no outcome comparisons)
sql/01_staging/       typed trades, resolved binary markets, data-quality checks
sql/02_intermediate/  price paths, classifier and its validation, resolution check,
                      wallet trades
sql/03_marts/         market snapshots at each horizon (wallet track records next)
pipeline/             SQL runner, Gamma and on-chain fetchers
labels/               hand-labeled classifier validation sample
docs/                 data profile, pre-registration, classifier codebook
```

All SQL lives in numbered `.sql` files, one `-- Qn` comment per query. Python
fetches API and chain data and, later, handles statistics and figures.

## Reproducing

```bash
python -m venv .venv && .venv/bin/pip install -r requirements.txt
export HF_TOKEN=...            # Hugging Face; full-file scans exceed anonymous limits
export POLYGON_RPC_URL=...     # Polygon archive endpoint, resolution check only
R=".venv/bin/python pipeline/run_sql.py"
SRC="sql/00_profile/00_sources.sql sql/01_staging/03_stg_trades.sql"
```

Every remote query runs after `00_sources.sql` (and trade queries after
`03_stg_trades.sql`) in the same session. Run order follows dependencies, which
differ from file numbering in one place: the snapshot mart precedes the
classifier, whose frame it defines.

```bash
$R sql/00_profile/00_sources.sql sql/01_staging/00_extract_markets.sql
$R sql/01_staging/01_stg_markets.sql
.venv/bin/python pipeline/fetch_gamma.py
$R sql/01_staging/02_stg_market_resolution.sql
$R --set dq_day=all $SRC sql/01_staging/04_dq_trades.sql
$R --set run_day=all $SRC sql/02_intermediate/01_int_price_paths.sql
$R --set run_day=all sql/03_marts/01_mart_snapshots.sql
$R sql/02_intermediate/02_int_market_class.sql
$R sql/02_intermediate/04_class_evaluation.sql
$R sql/02_intermediate/05_res_check_sample.sql
$R sql/00_profile/00_sources.sql sql/02_intermediate/06_res_check_tokens.sql
.venv/bin/python pipeline/fetch_onchain_resolution.py --workers 2
.venv/bin/python pipeline/fetch_onchain_resolution.py --tokens --workers 2
$R sql/02_intermediate/07_res_check.sql
$R --set run_day=all $SRC sql/02_intermediate/08_int_wallet_trades.sql
```

`03_class_validation_sample.sql` is omitted on purpose: it rewrites
`labels/class_round1.csv` as a blank sheet and would erase the committed labels
(`git checkout labels/` restores them). Files that take `--set run_day` accept a
date (`YYYY-MM-DD`) for a one-day smoke run that writes `*_smoke.parquet` instead.
The full remote reads total about 33 GB (price paths 8.4 GB, wallet trades about
19 GB, data-quality checks about 5 GB).
