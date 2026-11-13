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

**D2 (after registration, 2026-10-31; clarification, no design change).** The
RQ2 liquidity definition (Section 3) is read literally: the sum of
`usd_amount` over all of the market's trades whose `(block_number, log_index)`
precedes that of the snapshot trade. Dust trades (< $1) are included, since
the $1 floor applies only to the choice of snapshot trade; the snapshot trade
itself is excluded. Liquidity therefore uses the market's full trade history
since creation, not only the two weeks before `closedTime` that the staleness
cap requires for snapshot prices. No definition, test or threshold changes.
Recorded before any price path or snapshot exists.

**D3 (after registration, 2026-10-31; inclusion rule, before any snapshot).**
Trade data end at 2026-10-04 23:59:59 UTC, but 3,347 resolved markets close
after that (by 2026-10-05 07:12). A (market, horizon) snapshot is formed only
if t_h ≤ 2026-10-04 23:59:59, so that every trade before t_h is observed. This
mainly removes 1-hour snapshots near the data end; markets with no observed
trades have no snapshot at any horizon. Recorded before any snapshot exists.

**D4 (after registration, 2026-10-31; strengthens Section 7, before any
outcome comparison).** The Section 7 check adds a stratified sample to the 200
random markets: 30 kept markets per subject × format cell (5 subjects × 2
formats; every market in a cell with fewer than 30), drawn with a fixed seed
after the classifier is frozen and validated (Section 6). The random sample
alone gives a rare cell such as politics (about 0.8% of markets) roughly a 20%
chance of no draws. Two or more payout disagreements among a cell's markets
stop analysis of that cell until its outcome mapping is explained and fixed;
the 99% rule on the random sample is unchanged. The `closedTime` −
resolution-time distribution is also reported per cell. Recorded before any
price is compared with any outcome.

**D5 (after registration, 2026-11-01; changes Section 6 labeling, before any
evaluation result).** The round-1 labels (`labels/class_round1.csv`) were
drafted by Claude, the assistant that wrote the classifier rules, and then
reviewed and corrected by the author. They are therefore not independent of
the rules. The drafter applied `docs/classifier_codebook.md` to the six text
fields only, without consulting `int_market_class.parquet`, any price or any
outcome, so "blind to the predicted class" (Section 6) holds only in that
narrower sense. A labeler who also wrote the rules tends to share their reading
of ambiguous cases, which biases agreement upward. The evaluation therefore
reports the number of rows the author changed in review, and the rows marked
unsure separately. Recorded before the evaluation query was written or run.

**D6 (after registration, 2026-11-11; RQ3 operational details, before any
track record).** The wallet tables (`sql/02_intermediate/08`, `09`) require
the following choices, which Section 4 left open. Counts are from
`09_int_wallet_markets.sql`, which carries no outcome column.

1. *Self-trades.* The 905 fills with maker = taker (513 in resolved markets)
   are dropped from every RQ3 quantity: track records, market counts, the
   signal and bot fill counts. They net to zero P&L but would add USD to the
   denominator and a market toward the 20-market threshold.
2. *Trades that build a record.* A record uses both legs of every fill
   (maker and taker pooled) in the 2,205,956 resolved markets of Section 2,
   with no volume threshold, and only legs timestamped before that market's
   `closedTime`. This drops 378,875,786 legs in unresolved markets and
   2,613,342 legs (0.12%; $354M, 0.46% of resolved-market USD) traded at or
   after `closedTime`, when the outcome is already fixed. Price is the raw
   price of the traded token, tokens are `token_amount`, USD is `usd_amount`;
   fees are not modelled. The return does not depend on whether a
   complementary match is recorded as a buy of one token or a sale of the
   other. Kept: 2,152,280,754 legs in 290,120,454 (wallet, market) pairs over
   3,065,859 wallets.
3. *Point in time.* Track records, the 20-market qualification and the
   top-decile cutoff are recomputed once per UTC day, from markets whose
   `closedTime` precedes 00:00 UTC of the snapshot trade's day, not at each
   snapshot's exact time. The qualifying population is 299,834,233
   wallet-days over the 1,211 snapshot days (up to 1,052,265 wallets on one
   day), and a cutoff at each of 351,535 snapshot times is not computable
   here. The rule uses strictly less information than Section 4 and cannot
   leak.
4. *USD floor.* A wallet qualifies only if it also traded at least $1,000
   (`usd_amount`) in the same pre-as-of resolved markets as its 20-market
   count. A realized return per USD over a few dollars is mostly noise, and
   such wallets would crowd the top decile. At data end the floor removes
   380,461 of 1,053,260 wallets with 20 or more markets (36%) but only 0.2% of
   resolved-market USD (90.7% to 90.5% held by qualifying wallets). The level
   was chosen from these USD counts alone. The Section 4 definition without
   the floor is reported as a sensitivity.
5. *Smart wallets.* A qualifying wallet is smart on a day if its record is
   at or above the 0.9 quantile (`quantile_disc`, ties included) of all
   wallets qualifying that day, including wallets that no longer trade. A day
   with no qualifying wallet has no smart wallets.
6. *Signal.* Over smart wallets' legs in the market from 7 days before the
   snapshot trade through the snapshot trade itself (by
   `(block_number, log_index)`), signal = Σ d · usd / Σ usd, with d = +1 for
   buying token1 or selling token2 and −1 for the reverse. A market with no
   smart volume has signal 0. The number of such markets is reported, and the
   model is refit on markets with smart volume as a descriptive sensitivity.
7. *Population.* 1-day primary snapshots (Section 3; 351,535 markets), with
   p clipped and SEs clustered as in RQ1.
8. *Roles.* The single confirmatory test uses all smart legs. Maker-only and
   taker-only signals (records still pooled over roles) are fitted in two
   further models and reported as secondary, with unadjusted two-sided
   p-values.
9. *Bots (T10).* The top 0.1% by trade count are the wallets with at least
   83,099 fills (both roles, every market in the file, self-trades excluded):
   3,193 wallets holding 53.2% of all legs. Bots stay in the confirmatory
   test. The flag uses full-period fill counts but no outcome. The repeated
   test removes these wallets from both the qualifying population (cutoffs
   recomputed) and the signal. As a descriptive breakdown, bots are split by
   their share of maker legs in resolved markets: market-maker-like (≥ 80%
   maker; 1,316), taker-like (≥ 80% taker; 713) and mixed (1,164). The model
   is refit with each group removed in turn, to show which kind of bot drives
   any difference.

Recorded before any wallet track record or payout-weighted wallet quantity was
computed.

**D7 (after registration, 2026-11-12; RQ1 estimation details, before any
calibration quantity).** Section 4 leaves the following open for RQ1. The
analysis frame (`sql/03_marts/03_mart_analysis.sql`) has joined outcomes to
prices, but it prints counts only. All six cells have at least 161 clusters
per side, so the family stays at six tests.

1. *Inference.* Logistic regressions are fitted by maximum likelihood
   (statsmodels `Logit`). The standard errors are cluster-robust (CR1:
   G/(G − 1) · (N − 1)/(N − K)), using the Section 3 clusters, with z
   reference distributions. Each test reports the interaction coefficient,
   its SE, a 95% Wald CI, and the unadjusted and Holm-adjusted p-values. A
   model that fails to converge or shows perfect separation is reported as
   not estimable. No substitute model is fitted.
2. *Calibration intercept.* Calibration-in-the-large is the intercept a in
   logit P(win) = a + logit(p), with logit(p) entered as an offset (a = 0:
   prices are right on average; a > 0: outcomes occur more often than
   priced). The slope is the registered coefficient on logit(p).
3. *Scores.* The Brier score uses the unclipped price. Log loss uses p
   clipped to [0.001, 0.999], as in the model.
4. *Calibration curves.* The "decile" curves use ten equal-width price bins,
   [0, 0.1), [0.1, 0.2), …, [0.9, 1.0]. Each bin plots the mean price
   against the observed win frequency. Bins with fewer than 30 markets are
   drawn but flagged.
5. *Bootstrap.* The descriptive CIs are percentile intervals from 1,000
   resamples of clusters, drawn within each (horizon × format × subject)
   cell, with seed 20261112.
6. *Symmetrized curve.* Each market enters twice, as (p, token1_won) and as
   (1 − p, 1 − token1_won), per (horizon × format) and crypto vs.
   non-crypto. Clusters are resampled as in item 5. Descriptive only.
7. *Sensitivities (Section 5) for RQ1.* Each sensitivity refits the six
   interaction models with the same specification and reports coefficients
   and 95% CIs only. No p-values and no Holm correction are applied.
   - 5.1 drops the volume floor; 5.2 raises it to $10,000.
   - 5.4 drops the staleness cap. 5.5 clusters by `event_id`.
   - 5.6 fits each `closedTime` calendar year separately. A cell-year with
     fewer than 30 clusters on either side is not fitted.
   - 5.7 drops markets with `closedTime < end_date`.
   - 5.3 replaces the snapshot price with the token-weighted VWAP,
     Σ price · tokens / Σ tokens, over all trades (dust included) with
     timestamp in [t_h − 5 min, t_h). It uses `token_amount` from
     `08_int_wallet_trades`, with prices on the token1 side. A market with
     no trade in that window has no VWAP snapshot. The population is
     otherwise primary.

   The application of Section 5 to RQ2 and RQ3 is fixed in a later entry,
   before either is analysed.

Recorded before any calibration slope, intercept, score or curve was
computed.
