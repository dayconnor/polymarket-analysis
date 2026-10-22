# Pre-registration — Polymarket Calibration

Central question: are Polymarket prices well-calibrated probabilities, and does
calibration differ for crypto markets relative to other subjects?

This document fixes the hypotheses, population, variable definitions, models,
tests and inclusion rules **before any price has been compared with any
outcome**. It is committed to git before the price-path and snapshot tables
(`sql/02_intermediate/`, `sql/03_marts/`) exist; the commit timestamp is the
record of that ordering. Results and interpretation will live in `README.md`,
not here. Any change after this commit is logged in Section 9 with its date and
reason.

---

## 1. What had been seen before this document was written

- **Phase 1 profile** (`docs/data_profile.md`): schema, row counts, layout,
  resolution encoding, category signals, lifetimes and volumes. Threats T1–T11
  in that document motivate most choices below.
- **Staging counts** (`sql/01_staging/01`, `02`) and the Gamma field profile
  (`sql/00_profile/05_gamma_fields.sql`): exclusion counts, settlement shapes,
  resolution-status values, timing of `closedTime` against `created_at` and
  `end_date`, and agreement counts between Gamma and the Hugging Face payout.
- **Eligible-universe counts** by rough market type, lifetime band, volume
  band, outcome-label pair and `series_slug` presence (counts only).
- **One disclosed deviation from the no-outcome rule** (Section 9, D1).

No snapshot price, price path, calibration curve, Brier score or wallet track
record had been computed.

---

## 2. Data and population

**Sources.** Hugging Face `SII-WANGZJ/Polymarket_data` pinned to commit
`73bc1adc43b05709d2cde3bf41ef4111eda3f4fc` (trades through 2026-10-04
23:59:59 UTC); Polymarket Gamma API fields fetched 2026-10-20/21 (every row
stamped with `fetched_at`; Gamma is live and unpinned).

**Resolved-market universe** (`data/processed/stg_market_resolution.parquet`,
`exclusion_reason IS NULL`): 2,205,956 markets. Of the 2,223,448 markets
requested from Gamma (closed, binary-shaped, CLOB era, with an event, volume
> 0), the following were excluded, each counted once under its first failing
rule:

| Reason | Markets |
|---|---:|
| `half_payout` (Gamma 0.5/0.5, voided) | 12,929 |
| `disputed` (any `disputed` in the UMA status history) | 2,758 |
| `not_finalized` (`umaResolutionStatus` other than `resolved`) | 1,039 |
| `not_in_gamma` | 397 |
| `no_binary_payout` | 182 |
| `no_closed_time` | 143 |
| `payout_conflict` (Gamma and HF disagree on the winning slot) | 36 |
| `closed_before_created` | 8 |

**Outcome.** `token1_won` = 1 if the final payout vector is `[1, 0]`. The final
payout is Gamma `outcomePrices` when clean 0/1, else the HF payout when clean
0/1 (in practice every kept market resolved from Gamma). The alignment of
payout slot 1 with token1 is an assumption shared with the trade price rule;
it is checked in the on-chain validation (Section 7).

**Resolution time.** Gamma `closedTime`. `end_date` is not used as a
resolution time (21% of markets close before it; T2).

**Primary analysis population.** Resolved markets with metadata
`volume_usd >= 1,000` (about 1.01M markets), further restricted per horizon
by the snapshot rule (Section 3).

---

## 3. Definitions

**Horizons.** h ∈ {1 week, 1 day, 1 hour}, measured backward from
`closedTime`. Horizon anchor t_h = `closedTime − h`.

**Snapshot price.** The price of the last trade with `timestamp < t_h`,
ordered by `(block_number, log_index)`, among trades of at least $1 USD
(dust excluded; T8). Price is expressed on the token1 side: `price` if
`nonusdc_side = 'token1'`, else `1 − price`.

**Staleness cap.** The snapshot trade must satisfy
`timestamp >= t_h − h` (1-hour horizon: within the hour before t_h; 1 day:
within the day; 1 week: within the week). A market with no qualifying trade
has no snapshot at that horizon and is excluded from that horizon only.

**Lifetime requirement.** `created_at <= t_h` (implied by the staleness cap,
stated for clarity). Samples therefore differ by horizon; categories are
compared within a horizon, never across horizons (T5).

**Side rule.** For RQ1 and RQ3 the forecast is the token1 price and the
outcome is `token1_won`, in every market type (Yes, Up, Over, first-listed
team). A symmetrized calibration curve using both sides of each market is
reported descriptively. RQ2 uses the cheaper side (Section 4).

**Subject taxonomy** (classifier, Section 6): crypto, politics, sports,
weather, other. **Crypto** = the resolution depends on a crypto-asset price,
a crypto project or company event (launch, listing, hack, ETF decision), or
crypto-specific regulation. A market that only mentions crypto (e.g. whether a
politician will say "Bitcoin") is not crypto.

**Format stratum.**

- *Template:* auto-generated price-direction or price-threshold markets on a
  recurring schedule (crypto Up/Down, multi-strike hourly/daily ladders,
  weather ladders, equivalent templates).
- *Event:* everything else (sports games, elections, one-off questions).

`series_slug` is not sufficient on its own, because Gamma also groups sports
leagues into series (`mlb`, `atp`, `nba-2026`). Format is assigned by the
classifier from the question template and validated with the same hand-labeled
sample.

**Clusters.** `series_slug` when present, else `event_id`. Each crypto Up/Down
market is its own event, so event clustering would treat correlated markets in
one series as independent (T7).

**Liquidity** (RQ2). Cumulative USD volume of the market's trades before the
snapshot trade, log-transformed. Lifetime metadata `volume_usd` is not used,
because it includes trades after the horizon.

---

## 4. Hypotheses

### RQ1 (primary): crypto vs. non-crypto calibration

At each horizon h and within each format stratum, the calibration slope of
crypto markets differs from that of non-crypto markets.

- *Model:* logistic regression
  `token1_won ~ logit(p) + crypto + crypto × logit(p)`, fit separately per
  (horizon × format) cell. p is clipped to [0.001, 0.999] before the logit.
  The calibration slope for a group is the coefficient on logit(p) (1 =
  perfectly calibrated, < 1 = overconfident prices, > 1 = underconfident).
- *Test:* the `crypto × logit(p)` coefficient, two-sided, cluster-robust SEs
  (Section 3).
- *Family:* 3 horizons × 2 formats = 6 tests, Holm–Bonferroni at
  family-wise α = 0.05.
- *Supported if:* at least one of the six interaction coefficients is
  significant after Holm correction; direction and size are reported for all
  six regardless of significance.
- *Falsified if:* no interaction coefficient is significant after correction.
  A null is reported as a null, with the confidence intervals that bound how
  large a difference the data can rule out.
- A cell with fewer than 30 crypto clusters or fewer than 30 non-crypto
  clusters is reported descriptively and not tested; the family size shrinks
  accordingly and the change is reported.
- *Descriptive, untested:* Brier score, log loss, calibration intercept and
  decile calibration curves per (horizon × format × subject), with
  cluster-bootstrap 95% CIs (1,000 resamples of clusters).

### RQ2 (secondary): longshot bias and liquidity

Low-probability outcomes are overpriced, and the bias shrinks with liquidity.

- *Longshot definition:* in each snapshot, the cheaper side when it is priced
  below $0.10 (side-agnostic, since T6 makes "YES" arbitrary). Its outcome is
  whether that side won.
- *H2a:* mean(won − price) over longshot snapshots is negative (realized
  frequency below price). One-sample test on cluster means, two-sided.
- *H2b:* among longshot snapshots, in an OLS regression of (won − price) on
  log liquidity with cluster-robust SEs, the coefficient is positive (the
  negative bias moves toward zero as liquidity rises). Two-sided.
- Tested at the 1-day horizon (pre-chosen as the primary horizon for RQ2),
  pooled over formats with format fixed effects; the other horizons are
  reported descriptively. α = 0.05 per hypothesis, Holm across H2a and H2b.

### RQ3 (secondary): smart money

Wallets with strong past track records predict outcomes beyond the price.

- *Track record:* for each wallet at each point in time, realized return per
  USD traded: the sum over its trades in resolved markets of
  tokens × (payout − price) for buys and tokens × (price − payout) for sells,
  divided by the USD value of those trades. Only markets whose `closedTime`
  precedes that point in time count (no leakage). A wallet qualifies after
  trading in at least 20 such resolved markets.
- *Smart wallets:* the top decile of qualifying wallets by track record, as of
  the snapshot time (recomputed each time, never using later information).
- *Signal:* net USD bought in token1 minus token2 by smart wallets in the
  market over the 7 days before the snapshot, scaled to [−1, 1] by total smart
  volume.
- *Test:* in `token1_won ~ logit(p) + signal`, the coefficient on signal is
  positive. 1-day horizon, two-sided, α = 0.05, cluster-robust SEs.
- Maker and taker roles are analysed separately. Wallets in the top 0.1% by
  trade count are flagged as likely bots or market makers, and the test is
  repeated without them (T10).
- RQ3 design details may need deviations once the wallet tables exist; each
  will be logged in Section 9 before any RQ3 result is computed.

---

## 5. Sensitivity analyses (pre-specified, not tested for significance)

1. No volume threshold (all 2.2M resolved markets).
2. Volume threshold $10,000.
3. Snapshot as 5-minute VWAP before t_h instead of the last trade (T8).
4. No staleness cap.
5. Event-only clustering.
6. Results by calendar year of `closedTime` (86% of trades are from 2026; T9).
7. Excluding markets with `closedTime < end_date` (early closes).

---

## 6. Classifier validation

- Rules over `question`, `slug`, `event_slug`, `series_slug` and
  `sports_market_type` assign subject and format. They are written and frozen
  before validation; they use no outcome or price information.
- **Hand-labeled sample:** 400 markets, stratified by predicted subject (80 per
  class) and drawn with a fixed seed, labeled blind to the predicted class.
- **Acceptance:** crypto precision and recall ≥ 0.95 and format accuracy
  ≥ 0.95. Below threshold, the rules are revised and validated on a fresh
  sample (still before any outcome is examined). All rounds are reported.

---

## 7. Resolution validation

Gamma `closedTime` and payouts are checked against on-chain
`ConditionResolution` events for 200 randomly sampled kept markets (fixed
seed), keyed by `condition_id`. Payout agreement and the
`closedTime − resolution block time` distribution are reported. If payout
agreement is below 99%, analysis stops and the resolution source is
reconsidered before any outcome comparison.

---

## 8. Reporting commitments

- Every exclusion is counted at each layer and reported.
- All six RQ1 cells are reported, whatever their significance.
- Null results are reported as nulls, with interval bounds.
- Anything not specified here is labeled exploratory.

---

## 9. Deviations log

**D1 (before registration, 2026-10-20).** A Phase 2 profiling query broke the
`near_settled` HF payouts out by which slot held the 0.9995 value
(`[0.0005, 0.9995]` 300,416 vs `[0.9995, 0.0005]` 147,238). This is a
winning-side breakdown of the outcome field and violates the rule fixed for
the project. No prices were involved. The figure shows the token2 slot ending
near 1 about twice as often as token1 in that subset, which carries
information about the token1 base rate, so it is disclosed here. No later
decision in this document was chosen using it, and it does not enter any
analysis.
