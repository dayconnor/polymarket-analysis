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

**D8 (after registration, 2026-11-17; RQ1 Holm family rule, recorded after
the RQ1 results; RQ2 estimation details, before any RQ2 result).**

*Part A, RQ1 (recorded after the RQ1 results were computed).* Section 4
shrinks the RQ1 family only for cells with fewer than 30 clusters per side,
and D7.1 does not say whether a cell that is not estimable stays in the
family. In the executed notebook (a395c04), the 1-hour event cell did not
converge: 97.6% of its crypto snapshots are priced at or below $0.01 or at or
above $0.99. It was treated as leaving the family, which gave five Holm-
adjusted tests. Because this rule was settled after the results existed, a
robustness check is reported with it. Keeping the cell in a six-test family
at p = 1 yields the same two significant cells, at the same adjusted
p-values to four decimals; no other cell comes close to α. The
confirmatory conclusion therefore does not depend on the rule.

*Part B, RQ2 (recorded before any RQ2 outcome quantity is computed).* The
RQ2 notebook (`notebooks/02_rq2_longshot.ipynb`, first built in 9745533)
reads no outcome column. Only its planted control on simulated outcomes has
been executed. The weighting choice in item 1 was made from the cluster
composition of the 1-day longshot frame and from simulated outcomes, without
any RQ2 outcome.

1. *H2a.* The estimate is the snapshot-level mean of (won − price) over the
   1-day longshot snapshots, both formats pooled. It is obtained from an
   intercept-only OLS with CR1 cluster-robust SEs on the Section 3 clusters
   and a z reference distribution, as in D7.1. The test is two-sided, with a
   95% Wald CI. This is the mean Section 4 names, with inference by cluster,
   which is how "test on cluster means" is read. The alternative of weighting
   each cluster equally was rejected: the 523 template clusters (4.7% of
   11,067) hold 65.1% of the 144,420 snapshots and would receive 4.7% of the
   weight, and weather would fall from 41.6% to 1.4%. That unweighted
   cluster-mean t test (df = G − 1) is reported as a descriptive.
2. *H2b.* OLS of (won − price) on log liquidity and a template indicator
   (format fixed effect), with CR1 cluster-robust SEs on the Section 3
   clusters and a z reference distribution. The test is two-sided, with a
   95% Wald CI.
3. *Zero liquidity.* Liquidity enters as log(1 + USD). A snapshot that is the
   market's first trade (2,125 of 144,420 one-day longshot snapshots) is kept
   at liquidity 0.
4. *Multiplicity.* Holm across H2a and H2b at family-wise α = 0.05.
5. *Descriptives.* For each horizon × format: count, clusters and mean
   (won − price) with a 1,000-resample cluster-bootstrap percentile CI
   (seed 20261112). At 1 day, the same by liquidity quintile and by subject,
   plus the unweighted cluster-mean test of item 1.
6. *Sensitivities (Section 5 for RQ2).* H2a and H2b are re-estimated at
   1 day, and coefficients and 95% CIs are reported with no p-values: 5.1 no
   volume floor; 5.2 floor $10,000; 5.3 longshot side and price from the
   5-minute VWAP (D7.7); 5.4 no staleness cap; 5.5 `event_id` clustering;
   5.6 each `closedTime` year with at least 30 clusters; 5.7 excluding early
   closes. For 5.7, the RQ1 exploratory notebook (3dd5a4b) shows that early
   close is itself selected on the outcome in deadline markets, so 5.7 is
   read as a check of fragility, not as a bias correction.
7. *Planted control.* The check uses real prices, liquidity and clusters with
   simulated outcomes, 50 draws per scenario. 95% CIs covered the truth in
   94–98% of draws, and the planted effects were rejected in 50/50 draws.
   Null rejection rates were 0.06 (H2a) and 0.02 (H2b); with 1,000 null
   draws, the H2a rate was 0.054.

Recorded before any RQ2 longshot outcome was computed.

**D9 (after registration, drafted 2026-11-17, finalized 2026-11-24; RQ3
estimation details, Section 5 for RQ3 and a USD-floor fix, before any RQ3
result).** Section 4 and D6 fix the RQ3 test, the track records and the
signal. D7 deferred the application of Section 5 to RQ3; this entry fixes
it, together with the inference details. The primary
RQ3 frame is the 351,535 primary 1-day markets (17,291 clusters), of which
273,360 have smart volume and 78,175 have signal 0 (D6.6).

1. *Inference.* `token1_won ~ logit(p) + signal` is fitted by maximum
   likelihood (statsmodels `Logit`), with p clipped as in Section 4. The SEs
   are CR1 cluster-robust on the Section 3 clusters, with z reference
   distributions and 95% Wald CIs. A model that fails to converge or shows
   separation is reported as not estimable, as in D7.1. The signal
   coefficient is the single confirmatory test, two-sided at α = 0.05, so no
   multiplicity correction applies.
2. *Effect size.* The average change in win probability when the signal
   moves from 0 to +1, holding each market's price, is reported with the
   coefficient. It is the mean of expit(η + β) − expit(η), with η the fitted
   index at signal 0.
3. *Secondary tests and descriptive refits.*
   - The maker-only and taker-only models (D6.8) and the repeat without bots
     (D6.9) are secondary tests of the same form, with unadjusted two-sided
     p-values.
   - The following refits report coefficients and 95% CIs only: no USD floor
     (D6.4), markets with smart volume only (D6.6), each bot group removed
     (D6.9), and each format (template, event) separately.
   - Three further refits address misspecification of the price term and the
     size of the signal:
     - (a) *Format-adjusted:* adds a template indicator and a
       template × logit(p) slope. The mean signal differs by format (0.15
       template, 0.02 event), and RQ1 found that calibration differs by
       format.
     - (b) *Price-bin adjusted:* adds indicators for the ten equal-width
       price bins of D7.4, so miscalibration that is not linear in logit(p),
       such as the RQ2 longshot pattern, cannot load on the signal.
     - (c) *Smart volume of at least $1,000:* among markets with smart
       volume, 27.5% have a signal of exactly ±1, which can reflect a few
       dollars.
   - Markets are also binned by signal (no smart volume; [−1, −0.5);
     [−0.5, 0); [0, 0.5); [0.5, 1]). Per bin, the report gives count, mean
     price, win rate, and mean (won − price) with a CR1 95% CI, as in D8.1.
4. *Sensitivities (Section 5 for RQ3).* The confirmatory model is refitted,
   and coefficients and 95% CIs are reported with no p-values:
   - 5.1: no volume floor, i.e. 1-day snapshots within the staleness cap at
     any volume (423,016 markets);
   - 5.2: volume of at least $10,000 (193,596 markets);
   - 5.3: the 5-minute VWAP as p (D7.7), with markets without a VWAP dropped
     and the signal unchanged;
   - 5.4: no staleness cap, i.e. volume of at least $1,000 at any staleness
     (411,945 markets);
   - 5.5: `event_id` clustering;
   - 5.6: each `closedTime` year with at least 30 clusters;
   - 5.7: excluding early closes, read as a fragility check (D8.6).

   For 5.1 and 5.4, `sql/03_marts/02_mart_wallet_signal.sql` is extended to
   compute the signal on the 131,891 additional 1-day rows. Track records and
   cutoffs do not depend on which snapshots receive a signal.

   The rerun also exposed a defect in the D6.4 USD floor as built in bed9e72.
   The floor compared a floating-point sum with 1,000, and the sum for a wallet
   at exactly $1,000.00 fell on either side depending on summation order, so
   47 such wallets entered or left the qualifying population from run to run.
   Every one of the 1,266,885,846 fills is a whole number of cents, so the
   floor now compares the sum rounded to cents, which is the exact sum; the
   D6.4 definition (at least $1,000) is unchanged.
   `sql/03_marts/05_check_signal_extension.sql` verifies, before any RQ3
   outcome is computed, that:
   - two runs of the corrected mart are identical on all 483,426 signal rows
     and all 1,288 snapshot days;
   - the 351,535 primary markets are unchanged as a set;
   - every difference from the previous run comes from a wallet at exactly
     $1,000.00. Floored qualifying counts rise by 1 or 2 on 46 of 1,211
     primary days and never fall, no-floor counts are unchanged, cutoffs move
     by at most 4 × 10⁻⁶ in the main variant and 4 × 10⁻⁵ in any variant, and
     14 of 351,535 primary signals change (by at most 0.023).
5. *Planted control.* The check keeps the real prices, signals and clusters
   and simulates outcomes as Bernoulli(expit(logit(p) + β · signal)), with
   200 draws for each of β = 0.03 and β = 0, on the corrected signals.
   - 95% CIs covered the truth in 95.0% of draws in both scenarios.
   - β = 0.03 was rejected in 95.5% of draws; the null rejection rate was
     5.0%.
   - The minimum detectable effect at 80% power is 0.021 on the log-odds
     scale per unit of signal.
   - Before the floor fix (e576842) the control gave 93.0% and 95.5%
     coverage, 99.0% rejection and a 4.5% null rate. The current code on the
     pre-fix frame reproduces those figures exactly, so the change comes only
     from the 14 corrected signals altering the simulated draws. Both runs
     are consistent with the analytic power of about 98% (β / SE ≈ 4.0).

Recorded before any RQ3 outcome quantity was computed.

**Note (2026-11-27; reproducibility, not a deviation).** `03_mart_analysis.sql`
now writes the analysis frame ordered by `(market_id, horizon)`. DuckDB's
parallel write kept no row order, and the seeded cluster bootstraps and planted
controls index clusters by first appearance, so the D9 rebuild of the frame
changed their Monte Carlo digits. Every test, estimate and p-value is unchanged
(to 10⁻⁶), and every decision above stands. On the ordered frame, the D8.7
control gives 94–100% coverage, 50/50 rejections and null rates of 0.06 (H2a)
and 0.06 (H2b); the D9.5 control gives 96.5% (null) and 93.5% (planted)
coverage, 98.5% rejection, a 3.5% null rate and an MDE of 0.021. D8.7 and D9.5
are kept as written, since they record what was seen before the corresponding
outcomes were computed. This note was written after all results.

**Note (2026-11-27; `1 − price` floating-point boundary fix, not a deviation).**
`03_stg_trades.sql` converted `token2` fills with `1 - price` in IEEE-754
float64 without rounding, and notebooks 01, 02 and 02b computed `1 - p` the same
way. Because `1.0 - 0.90 = 0.09999999999999998 < 0.10` and `1.0 - 0.80 =
0.19999999999999996 < 0.20`, exact 10¢ `token2` snapshots (2,087 rows from
staging plus 893 rows from `1 - 0.90` in Python; 2,980 in all) leaked into the
RQ2 `< 0.10` longshot sample while exact 10¢ `token1` snapshots (1,638 rows)
were excluded, violating the side-agnostic T6 rule. Exact 10¢ and 20¢ `token2`
fills also shifted one bin down in RQ1 calibration curves. Every raw CLOB price
has at most 6 decimal places (USDC precision), so `03_stg_trades.sql`,
`03_mart_analysis.sql` and notebooks 01, 02 and 02b now round prices and
`1 - price` to 6 decimals. No definition or threshold changes; every RQ1 and
RQ3 test estimate is unchanged to 10⁻¹², and RQ2 conclusions are unchanged
(141,440 1-day longshots in 10,870 clusters; H2a −0.00232 [−0.00338, −0.00125],
Holm p = 0.00004; H2b −0.00034 [−0.00072, +0.00004], Holm p = 0.078; unweighted
cluster-mean H2a +0.00276 [+0.00025, +0.00527], p = 0.031). Also fixed:
untestable 2024 cells (< 30 clusters) in `results/rq1_sensitivities.csv` now
carry `estimable = False` and a `testable` column. Written after all results.
