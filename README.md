# Polymarket Calibration

**Status: analysis complete. RQ1, RQ2 and RQ3 tested; write-up to come.**
**Interactive dashboard: [polymarket-analysis-cd.streamlit.app](https://polymarket-analysis-cd.streamlit.app/)**
(reads only the committed result tables).

The hypotheses were pre-registered in [`docs/hypotheses.md`](docs/hypotheses.md)
(`bc6dca3`, 2026-10-21) before any price was compared with any outcome. Every later
estimation choice was logged there as a dated deviation (D1–D9) before the result
it affects existed, except one RQ1 family rule (D8 Part A), which is marked as
written after the RQ1 results and reported with a robustness check.

This project asks whether Polymarket prices behave as calibrated probabilities,
and whether calibration differs between crypto markets and politics, sports and
other categories. The unit of analysis is the market. Each resolved binary
market contributes one price snapshot per fixed horizon before resolution
(1 week, 1 day, 1 hour), taken as the last trade of at least $1 before that
horizon.

## Key findings

- **RQ1, crypto vs. non-crypto calibration: supported in two of five estimable
  cells, both qualified by a registered sensitivity.**
  - One day before resolution, crypto event markets are under-confident relative
    to non-crypto (slope 1.37 vs. 0.98; interaction +0.388 [0.210, 0.567], Holm
    p = 0.0001). Without early-closing markets the interaction falls to +0.13
    [−0.07, 0.32]. In deadline markets the early close is itself set by the
    outcome.
  - One hour before resolution, non-crypto template markets are under-confident
    relative to crypto (slope 1.30 vs. 1.10; −0.202 [−0.293, −0.110], Holm
    p = 0.0001). The difference disappears under 5-minute VWAP pricing.
  - The 1-hour event cell is not estimable: 97.6% of its crypto prices are at or
    below 1¢ or at or above 99¢.
- **RQ2, longshot bias: H2a supported, H2b not.**
  - One-day longshots (below 10¢) are overpriced by 0.25¢ on average (−0.00247
    [−0.00357, −0.00137], Holm p = 0.00002), about 10% of their mean price.
  - The bias sits in auto-generated ladder markets, mostly weather (about 22%
    overpriced per price band). Event-market longshots are calibrated.
  - The sign reverses under a $10,000 volume floor (+0.0043 [0.0020, 0.0067]).
    With clusters weighted equally, the point estimate is also positive and the
    CI covers 0.
  - The bias does not shrink with liquidity (−0.00033, p = 0.088); the sign is
    opposite to the prediction.
- **RQ3, smart money: statistically supported, economically negligible.**
  - Net buying by wallets with strong prior records predicts outcomes beyond the
    price (β = +0.038 [0.020, 0.056], p = 0.00006).
  - Moving the signal from 0 to +1 changes the win probability by 0.49
    percentage points.
  - The information comes from heavy smart selling; heavy smart buying carries
    none.
  - Where smart volume is at least $1,000, the CI covers 0.

Every departure from calibration that survives the pre-registered tests is
confined to particular market formats or price measures, and each weakens or
reverses under at least one registered sensitivity.

## Research questions

1. **RQ1 (primary).** Within each horizon × format cell, the calibration slope
   (logistic regression of `token1_won` on logit(price)) differs between crypto
   and non-crypto markets. Six interaction tests, Holm–Bonferroni at family-wise
   α = 0.05, cluster-robust standard errors (pre-registration Section 3).
2. **RQ2.** Low-probability outcomes (< 10¢) are overpriced (H2a), and the bias
   shrinks with liquidity (H2b). 1-day horizon, Holm across the two.
3. **RQ3.** Net buying by wallets with strong prior track records, computed only
   from markets already resolved at the snapshot, predicts outcomes beyond the
   price.

## Results

### RQ1: crypto vs. non-crypto calibration

**Supported under the registered rule.** Two of the five estimable cells show a
significant crypto × logit(p) interaction after Holm correction. A slope above 1
means prices are too timid (outcomes are more extreme than priced); below 1 means
they are overconfident.

| Horizon | Format | Slope, non-crypto | Slope, crypto | Interaction [95% CI] | Holm p |
| --- | --- | ---: | ---: | --- | ---: |
| 1 week | template | 0.975 | 0.927 | −0.048 [−0.210, 0.114] | 0.559 |
| 1 week | event | 0.964 | 1.105 | +0.141 [0.003, 0.279] | 0.135 |
| 1 day | template | 1.083 | 1.023 | −0.060 [−0.119, −0.000] | 0.135 |
| 1 day | event | 0.980 | 1.369 | **+0.388 [0.210, 0.567]** | **0.0001** |
| 1 hour | template | 1.304 | 1.103 | **−0.202 [−0.293, −0.110]** | **0.0001** |
| 1 hour | event | — | — | not estimable | — |

![Calibration curves by horizon and format, crypto vs. non-crypto](results/rq1_curves.png)

*Calibration curves for primary snapshots: mean price vs. observed win frequency in
ten equal-width bins, with cluster-bootstrap 95% CIs (D7.4–D7.5). Hollow points are
bins with fewer than 30 markets. The diagonal marks perfect calibration. The
symmetrized version, which uses each market as both (p, y) and (1 − p, 1 − y), is
`results/rq1_curves_symmetrized.png`.*

The confirmatory result comes with four caveats:

- **The 1-hour event cell is not estimable.** The model did not converge because
  97.6% of the 869 crypto snapshots there are priced at or below 1¢ or at or
  above 99¢. This is a non-estimate, not a null. The cell leaves the Holm family
  (D8 Part A, written after the results). Counting it as a sixth test at p = 1
  leaves the same two cells significant.
- **The 1-day event effect depends on early closes.**
  - 66% of the crypto markets in this cell closed before their `end_date`. Without
    them (sensitivity 5.7), the interaction falls to +0.13 [−0.07, 0.32].
  - An exploratory follow-up (`notebooks/01b`) shows why this matters. In deadline
    markets ("will X reach Y by date"), an early close mostly means the event
    happened, so `closedTime` is set by the outcome. "One day before close" then
    means "one day before the event", a point chosen using the future.
  - Consistent with this, crypto early closes resolve more often than priced
    (calibration-in-the-large +0.58), and on-time crypto markets less often
    (−0.80).
  - The split is itself selected on the outcome, so it is consistent with this
    mechanism but cannot isolate it. Part of the 1-day event effect plausibly
    reflects horizon anchoring rather than mispricing a trader could exploit.
- **The 1-hour template effect disappears under 5-minute VWAP pricing**
  (sensitivity 5.3: −0.03 [−0.17, 0.11]). It holds in sensitivities 5.1, 5.2,
  5.4, 5.5 and 5.7.
- **Which side is `token1` is arbitrary for about two-thirds of markets** (data
  profile T6), so intercept signs there carry little meaning. Symmetrized
  calibration curves are reported alongside.

### RQ2: longshot bias and liquidity

- **H2a supported.** One-day longshots (the cheaper side, priced below 10¢;
  144,420 snapshots in 11,067 clusters) are overpriced by 0.25¢ on average,
  −0.00247 [−0.00357, −0.00137], Holm p = 0.00002. That is about 10% of the mean
  longshot price of 2.4¢.
- **H2b not supported, and the sign is opposite to the prediction.** The
  liquidity coefficient is −0.00033 [−0.00072, 0.00005], p = 0.088. The bias
  does not shrink in deeper markets; it is significantly larger there in four
  sensitivities (5.2, 5.5, 5.7, 2026). Liquidity quintiles are not monotone: the
  thinnest quintile shows no bias.

The H2a result is narrower than "Polymarket longshots are overpriced":

- **It sits in auto-generated ladder markets.** Event longshots average −0.0001
  [−0.0022, 0.0024]; template longshots average −0.0037 [−0.0048, −0.0026].
- **It is not a tick-floor artifact.** An exploratory split by price band
  (`notebooks/02b`, `results/rq2_price_bands.png`) shows:
  - event longshots are calibrated in every band above the 0.1¢ minimum tick;
  - template longshots are overpriced in every band from 0.6¢ up, by 15–24% of
    the price;
  - weather ladders carry most of it: about 22% overpriced per band (at 5–10¢,
    5.9% wins against a 7.5% price). Sports and politics show no reliable bias.
- **The weighting rule decides the sign.** H2a weights each snapshot equally with
  cluster-robust inference (D8.1, fixed before any RQ2 outcome was computed).
  Weighting each cluster equally gives +0.0025 [−0.0001, 0.0051], because 95% of
  clusters are event markets. The average longshot *snapshot* is overpriced; the
  average longshot *market series* is not.
- **It is fragile to the volume floor.** With a $10,000 floor (5.2) the sign flips
  to +0.0043 [0.0020, 0.0067]. With 5-minute VWAP pricing (5.3) the CI covers 0.

![1-day longshot win rate against price by price band and format](results/rq2_price_bands.png)

*Exploratory (`notebooks/02b`). Win rate against mean longshot price per band, by
format, with the CR1 95% CI of the bias; both axes log-scaled, the grey line is perfect
calibration. Template points sit below the line from 0.6¢ up; event points do not.*

### RQ3: smart money

**Supported statistically; economically negligible.** In `token1_won ~ logit(p) +
signal` over the 351,535 primary 1-day markets (17,291 clusters), the signal
coefficient is +0.038 [0.020, 0.056], p = 0.00006. The signal is the net share of
smart-wallet USD bought on the token1 side in the 7 days to the snapshot, from −1
to +1 (D6). Moving it from 0 to +1 raises the win probability by 0.49 percentage
points at the market's own price. Among markets with smart volume the median
|signal| is 0.76, so a typical market moves by about 0.4 points. The estimate is
1.8 times the minimum detectable effect (0.021, planted control D9.5), so it is not
marginal. It is small.

| Test | β [95% CI] | p |
| --- | --- | ---: |
| Confirmatory: all smart legs | **+0.038 [0.020, 0.056]** | **0.00006** |
| Secondary: maker legs only | +0.036 [0.017, 0.054] | 0.0002 |
| Secondary: taker legs only | +0.036 [0.019, 0.053] | 0.00004 |
| Secondary: bots excluded | +0.036 [0.019, 0.053] | 0.00003 |

Secondary p-values are unadjusted (D9.3). The effect does not depend on the price
term or the clustering. Adding a template intercept and price slope (+0.040),
price-bin indicators (+0.039), `event_id` clustering (CI [0.023, 0.053]) or
dropping early closes (+0.036) leaves it intact. Four limits apply:

- **It is one-sided.** By signal bin, mean (won − price) is −0.93¢
  [−1.26, −0.59] under heavy smart selling ([−1, −0.5)) and +0.53¢
  [0.19, 0.87] under mild buying ([0, 0.5)). Under heavy smart buying ([0.5, 1],
  103,491 markets) it is −0.04¢ [−0.27, 0.19]. The strongest buy signals carry no
  measurable information; most of the slope comes from heavy selling. The bins
  are descriptive.
- **It is not established where the smart money is substantial.** 27.5% of
  markets with smart volume have a signal of exactly ±1, which can reflect a few
  dollars. With at least $1,000 of smart volume (refit A4; 43,373 markets) the
  coefficient is +0.028 [−0.015, 0.072]. The point estimate is similar, but the
  CI covers 0.
- **It is not seen under 5-minute VWAP pricing** (sensitivity 5.3: −0.003
  [−0.044, 0.037]). Only 49,703 primary markets (14%) have a VWAP window, so
  this cannot separate the price measure from the subsample.
- **It is concentrated in 2026 and in thinner markets.** By `closedTime` year
  (5.6), 2026 (77% of markets) gives +0.038 [0.019, 0.058] and 2025 gives +0.027
  [−0.012, 0.066]. The coefficient is +0.053 with no volume floor (5.1) and +0.026
  [0.004, 0.048] with a $10,000 floor (5.2). This fits informed wallets mattering
  most where prices are thin, but that reading was not tested.

![Mean of won minus price by smart-money signal bin](results/rq3_signal_bins.png)

*Descriptive. Mean of (won − price) in cents per signal bin for the primary 1-day
markets, with CR1 95% CIs. The confirmatory slope rests mostly on the heavy-selling
bin; heavy buying ([0.5, 1]) is indistinguishable from 0.*

The planted control (real prices, signals and clusters; simulated outcomes)
covered the truth in 96.5% (null) and 93.5% (planted) of 200 draws per scenario,
detected β = 0.03 in 98.5%, and rejected a true null in 3.5%. These are the
reproducible figures from the row-ordered frame (2026-11-27, see Reproducing); D9.5
records the earlier run (95.0%, 95.5%, 5.0%).

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
| Intermediate | `02_intermediate/09_int_wallet_markets.sql` | Net position per (wallet, resolved market): 290,120,454 pairs (5.4 GB), legs reconcile with 08. 3,192,129 wallets; 3,193 flagged as bots (≥ 83,099 fills, the top 0.1%), holding 53.2% of legs. No outcome column. |
| Marts | `03_marts/02_mart_wallet_signal.sql` | Daily as-of track records (41,115,052 rows over 3,065,859 wallets), top-decile cutoffs for 1,288 snapshot days, and the smart-money signal for the 351,535 primary 1-day markets (273,360 with smart volume) plus 131,891 rows for sensitivities 5.1 and 5.4. The USD floor compares cent-rounded sums (every fill is whole cents), so two runs are identical (D9.4). Reconciles D6 exactly. Independent recomputes of records at the day boundary, literal per-trade P&L, cutoffs and signals find 0 mismatches. No outcome column. |
| Marts | `03_marts/03_mart_analysis.sql` | The analysis frame: 1,925,812 snapshots joined to outcome, class and signal. The first file to join outcomes to prices; prints counts only. All six RQ1 cells have ≥ 161 clusters per side. |
| Marts | `03_marts/04_mart_vwap.sql` | 5-minute token-weighted VWAP before each horizon for sensitivity 5.3 (available for 14% of 1-day primary snapshots, 49,703 of 351,535). The trade sets match the price paths for 192,689 of 192,689 windows. |
| Analysis | `notebooks/01`, `01b` | RQ1 tests, descriptives, calibration curves, sensitivities; exploratory early-close check. |
| Analysis | `notebooks/02`, `02b` | RQ2 tests, descriptives, sensitivities; exploratory price-band split. |
| Analysis | `notebooks/03` | RQ3 confirmatory and secondary tests, signal-bin descriptives, refits, sensitivities. |

Each confirmatory notebook runs a planted control on simulated outcomes before the
real outcome is loaded. Notebooks 02 and 03 keep the outcome column unread behind a
`RUN_CONFIRMATORY` switch until the protocol entry they implement is committed.

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
  anchored on it carry no look-ahead from resolution timing. They can still
  carry look-ahead from early closes, as the RQ1 caveat above describes.

Only kept markets were checked; excluded (voided, disputed) markets were not.

## Layout

```text
sql/00_profile/       schema and data profiling (no outcome comparisons)
sql/01_staging/       typed trades, resolved binary markets, data-quality checks
sql/02_intermediate/  price paths, classifier and its validation, resolution check,
                      wallet trades and positions
sql/03_marts/         snapshots, wallet track records and signal, analysis frame, VWAP
sql/04_dashboard/     small aggregate exports for the dashboard
pipeline/             SQL runner, Gamma and on-chain fetchers
app/                  Streamlit dashboard; reads results/ and app/data/ only
notebooks/            RQ1-RQ3 tests (01-03) and exploratory follow-ups (01b, 02b)
results/              tables (CSV) and figures written by the notebooks
labels/               hand-labeled classifier validation sample
docs/                 data profile, pre-registration, classifier codebook
```

All SQL lives in numbered `.sql` files, one `-- Qn` comment per query. Python
fetches API and chain data and handles the statistics and figures. Code is under
the MIT license ([`LICENSE`](LICENSE)); the dataset carries its own MIT license.

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
$R --set run_day=all sql/02_intermediate/09_int_wallet_markets.sql
$R --set run_day=all sql/03_marts/02_mart_wallet_signal.sql
$R sql/03_marts/03_mart_analysis.sql
$R --set run_day=all sql/03_marts/04_mart_vwap.sql
for nb in 01_rq1_calibration 01b_rq1_early_close 02_rq2_longshot 02b_rq2_price_bands 03_rq3_smart_money; do
  .venv/bin/jupyter nbconvert --to notebook --execute --inplace notebooks/$nb.ipynb
done
$R sql/04_dashboard/01_dash_calibration.sql
.venv/bin/streamlit run app/streamlit_app.py
```

`03_class_validation_sample.sql` is omitted on purpose: it rewrites
`labels/class_round1.csv` as a blank sheet and would erase the committed labels
(`git checkout labels/` restores them). Files that take `--set run_day` accept a
date (`YYYY-MM-DD`) for a one-day smoke run that writes `*_smoke.parquet` instead.
The full remote reads total about 33 GB (price paths 8.4 GB, wallet trades about
19 GB, data-quality checks about 5 GB); every step after `08` reads local extracts
only. The notebooks run in seconds to about a minute each.

The analysis frame is written in `(market_id, horizon)` order. The seeded cluster
bootstraps and planted controls index clusters by first appearance, and DuckDB's
parallel write keeps no row order, so before 2026-11-27 a rebuild changed their Monte
Carlo digits (CI bounds by up to 0.03, control rates by a few draws). Tests, estimates
and p-values were unaffected (to 10⁻⁶), and no CI changed whether it covers 0 outside
one 14-cluster descriptive cell. With the order fixed, two full reruns of every
notebook give byte-identical results and figures.
