# Data Profile

Phase 1 profile of the two source files, written before any hypothesis is
pre-registered. **No price was compared with any outcome.** `outcome_prices`
was inspected for its encoding and shape only (clean 0/1, 50/50, other), and
the side that won was never broken out. Every number below comes from a query
in `sql/00_profile/`. The query ID (Q2.1, Q3.4, ...) is given next to each
result.

Source: [`SII-WANGZJ/Polymarket_data`](https://huggingface.co/datasets/SII-WANGZJ/Polymarket_data),
commit `73bc1adc43b05709d2cde3bf41ef4111eda3f4fc` (release of 2026-10-05).
Profiled 2026-10-19.

---

## 1. What was read, and at what cost

| Step | What it reads | Transfer |
|---|---|---|
| `01_schema.sql`, `02_footer_stats.sql` | Parquet footers only (schema, row-group min/max/null counts) | a few MB |
| `03_markets.sql` | 17 of 20 markets columns, all rows (token/condition hashes excluded) | ~120 MB |
| `04_trades_sample.sql` | 26 of 1,261 trade row groups, `transaction_hash` excluded; markets token ids for joins | ~0.7 GB per run |

The repo has five files (279 GB in all). Only `trades.parquet` (45.8 GB) and
`markets.parquet` (0.55 GB) are used. Nothing was saved to disk.

**Trade samples (Q4.0a).** These are two whole time slices, so the sample
follows the file's own chunking and isn't a hand-picked window:
- **2024-10:** 7,037,690 trades. October 2024 was the peak of US-election trading.
- **2026-09-08 to 2026-09-15:** 18,948,168 trades, from the V2 exchange era.

Row-level trade results (Section 6) hold only for these two slices.

---

## 2. Schema, row counts, date range, null rates

**trades.parquet** (Q1.1, Q1.3): 1,266,885,846 rows, 17 columns, 1,261 row
groups (about 1.0M rows each), as described in the dataset card. Columns:
`timestamp` (UBIGINT, Unix seconds), `block_number`, `transaction_hash`,
`log_index`, `contract`, `market_id`, `condition_id`, `event_id`, `maker`,
`taker`, `price` (DOUBLE), `usd_amount`, `token_amount`, `maker_direction`,
`taker_direction`, `nonusdc_side` (`token1`/`token2`), `asset_id`.

**markets.parquet** (Q1.2, Q1.3): 4,049,900 rows, 20 columns. Columns: `id`,
`question`, `slug`, `condition_id`, `token1`, `token2`, `answer1`, `answer2`,
`closed`, `active`, `archived`, `outcome_prices` (VARCHAR), `volume`,
`event_id`, `event_slug`, `event_title`, `created_at`, `end_date`,
`updated_at` (TIMESTAMPTZ), `neg_risk`.

**Null rates (Q2.1, Q2.2).** Zero NULLs in every column of both files. These
are exact counts summed from row-group statistics, and every row group carries
them. Missing values are stored as empty strings instead (Q3.1):

| Field | Empty count |
|---|---|
| `outcome_prices = '[]'` | 651 |
| `event_id` | 16 |
| `event_slug` | 16 |
| `question` | 0 |
| `answer1` / `answer2` | 0 |

**Date range (Q2.3).** First trade 2022-11-21 19:49:29 UTC, last trade
2026-10-04 23:59:59 UTC, matching the card.

**Value ranges (Q2.3).**
- `price`: exactly 0 to 1, with no values outside that range.
- `usd_amount`: 0 to 6.31M.
- `token_amount`: 0 to 7.58M.

Zeros do occur (Section 6.4).

**Volume over time (Q2.7a).** Trading is concentrated in the most recent year:

| Year | Trades | Share |
|---|---|---|
| 2022 | 1,739 | <0.1% |
| 2023 | 193,485 | <0.1% |
| 2024 | 31,389,588 | 2.5% |
| 2025 | 142,279,764 | 11.2% |
| 2026 (to Oct 4) | 1,093,021,270 | 86.3% |

---

## 3. Physical layout and what queries cost

**The file is chunked by time slice, not sorted (Q2.4–Q2.7).** Every row group
falls inside one calendar month (Q2.6). Before 2024, each slice is a month
held in a single row group. In 2026, slices are roughly weekly, and about 20
row groups each span the whole week in no useful order, by either timestamp
or `market_id` (1,213 of 1,261 row groups overlap their neighbours on
`market_id`).

- **Time filters prune well.** A `WHERE timestamp ...` filter downloads only the
  matching slices, about 1/65 of the file for one 2026 week.
- **Market filters prune almost nothing.** Building price paths for any set of
  markets means streaming the needed columns across all 1,261 row groups.

**Column sizes (Q2.1, compressed)** determine the cost of each mart:

| Column(s) | GB |
|---|---|
| `transaction_hash` | 26.02 |
| `taker` / `maker` | 5.49 / 2.54 |
| `usd_amount` / `token_amount` | 2.19 / 2.11 |
| `log_index` / `timestamp` / `block_number` | 1.99 / 1.44 / 1.42 |
| `price` | 1.14 |
| `asset_id` | 0.87 |
| `nonusdc_side`, `condition_id`, directions, `market_id`, `event_id`, `contract` | < 0.3 each |

**Full-history costs:**
- **Price paths** (market_id, timestamp, block_number, log_index, price,
  nonusdc_side, usd_amount): about 8.4 GB, read once.
- **Smart money** adds maker and taker: about 8 GB more.
- **`transaction_hash` is never needed.** `(block_number, log_index)` is a
  unique trade key (Section 6.1).

**Coverage gaps (Q2.7b).** Merging row-group time intervals (gaps-and-islands)
finds gaps only at slice boundaries:
- **2022–23:** the largest gaps are 8h15m (2022-12-31) and 2h47m (2022-11-30).
  Both fall in the period with almost no trading.
- **2026-08-31 23:12:43 to 2026-09-01 01:04:45 UTC (1h52m) is very likely missing
  data.** It falls in a period averaging about 27 trades per second (the
  September 2026 sample).

Gaps *inside* a slice can't be seen from metadata alone. Section 8 lists that check as open.

---

## 4. Markets

### 4.1 Keys and status flags

- **Keys (Q3.1).** `id` is unique (4,049,900 distinct). `slug` has 334
  duplicates. There are 1,112,116 distinct `event_id` values.
- **Status flags (Q3.2).** `archived` is always 0 and `active` is always 1, so
  neither carries information. Only `closed` varies: 3,812,058 closed and
  237,842 open.

### 4.2 Resolution encoding

`outcome_prices` is a **Python-repr** string (`['0', '1']`), not the JSON the
dataset card documents (Q3.3b). That covers 4,049,249 rows; the remaining 651
are an empty `[]`. Parsing it requires replacing single quotes with double
quotes. 40 non-empty strings still fail to parse.

Resolution shape among closed markets (Q3.3), without regard to which side won:

| Shape | Closed markets | Share |
|---|---|---|
| Clean 0/1 | 3,162,334 | 83.0% |
| Other | 587,808 | 15.4% |
| 0.5 / 0.5 | 61,729 | 1.6% |
| Unparseable | 187 | <0.1% |

What the "other" bucket contains (Q3.4, measured by the larger side's value,
which is symmetric):
- **Near 1 but not exact:** 569,438 (e.g. 0.9995/0.0005).
- **About 0.99:** 15,910.
- **Between 0.51 and 0.60:** about 2,000, i.e. closed with no decisive price.
- **0 / 0:** 162.

The near-1 values look like final *trading* prices rather than settlement
payouts. Whether they are officially resolved can't be told from this file.

### 4.3 Voided and disputed status

- **Voided:** there is no flag. The 61,729 closed 0.5/0.5 markets would be
  Polymarket's 50/50 resolution, but 99,819 *open* markets also show 0.5/0.5
  (default prices for untraded markets). The pattern is therefore ambiguous,
  not a void marker.
- **Disputed:** there is no field, and the UMA dispute history is not in the
  dataset.

### 4.4 Binary structure and outcome labels

Every market has exactly two tokens (`token1`/`answer1`, `token2`/`answer2`),
so "non-binary market" isn't a property of a row. Multi-outcome questions are
sets of binary markets (Section 4.5). Labels vary widely (Q3.5):

| Labels | Markets | Share |
|---|---|---|
| Yes/No | 1,357,995 | 33.5% |
| Over/Under | 1,214,162 | 30.0% |
| Up/Down | 798,149 | 19.7% |
| Over 2.5/Under 2.5 | 34,266 | 0.8% |
| Odd/Even | 33,466 | 0.8% |

The rest are team-vs-team names and other pairs. For a large share of markets,
which side counts as "YES" is arbitrary.

### 4.5 Multi-outcome events (Q3.6)

**neg_risk events: 109,829 events, 772,609 markets.** These are mutually
exclusive sets with one Yes/No market per outcome, and at most one resolves
Yes. Median 3 markets per event, p99 37, max 156. 16 of these events have a
single market. `neg_risk` never mixes within an event.

**Other events: 1,002,287 events, 3,277,291 markets.**
- 846,595 events have a single market.
- The rest are groups such as threshold ladders ("Bitcoin above 69,000",
  temperature brackets) whose markets are strongly correlated but not mutually
  exclusive.
- p99 is 33 markets per event; the max is 488.

### 4.6 Category signals

**There is no category or tag column** in `markets.parquet`. The only signal is
text: `question`, `slug`, `event_slug`, `event_title`. Treating the first two
words of `event_slug` as a series stem (Q3.11) shows that auto-generated
recurring series make up most of the market count:

| Series | Markets |
|---|---|
| `highest-temperature` + `lowest-temperature` (weather) | 158,057 |
| `btc-updown` | 116,248 |
| `eth-updown` | 114,310 |
| `xrp-updown` | 112,512 |
| `sol-updown` | 112,502 |
| `hype-updown`, `doge-updown`, `bnb-updown` | ~80,500 each |
| `bitcoin-above` | 80,010 |
| `ethereum-above` | 67,778 |
| `atp-doubles` | 30,681 |

There are also hundreds of per-team MLB series of about 8,000 markets each.
The Up/Down markets cover windows as short as 5 minutes ("ZCash Up or Down,
September 19, 2:05PM–2:10PM ET").

Crude, unvalidated keyword hit rates over the 3,812,058 closed markets (Q3.12),
used only to size the problem:

| Keyword group | Markets | Share | Note |
|---|---|---|---|
| crypto | 800,375 | 21.0% | |
| up/down series | 794,444 | 20.8% | overlap with crypto hits not formally checked |
| politics | 30,668 | 0.8% | |
| sports | 1,740,562 | 45.7% | inflated by `vs` |

### 4.7 Dates and market lifetime

**Ranges (Q3.7):**

| Field | Min | Max |
|---|---|---|
| `created_at` | 2020-10-02 | 2026-10-05 |
| `end_date` | 2011-07-05 | 2031-01-01 |
| `updated_at` | 2024-12-30 | 2026-10-05 |

`updated_at` is when the metadata snapshot was taken, not a resolution time.

**Anomalies:**
- 32,720 markets have `end_date < created_at`.
- 55,315 closed markets have `end_date` after the data cutoff, meaning they
  closed early.
- 10,852 open markets passed their `end_date` more than 30 days before the cutoff.

**Pre-CLOB markets (Q3.9).** About 4,500–4,900 markets were created before the
CLOB launch (2022-11-21). Their earlier AMM-era trades aren't in the dataset,
so their price paths are cut off at the start.

**Lifetime of closed markets** (`end_date − created_at`, Q3.8):
- 2.0% are under 1 hour, 32.7% under 1 day, 64.2% under 7 days.
- Quartiles: 24.0h, 57.9h, 185.4h.

Only about 36% of closed markets can have a 1-week snapshot, measured from
creation. Measured from the first trade, the share would be smaller.

**Creation rate (Q3.9).** Market creation rose from about 1–7k per quarter in
2023–24 to 856,582 in 2026 Q2 and 2,307,128 in 2026 Q3.

### 4.8 Liquidity (metadata `volume`, closed markets, Q3.10)

| Volume | Markets | Share |
|---|---|---|
| Zero | 1,583,784 | 41.5% |
| Under $100 | 2,135,054 | 56.0% |
| $10k or more | 440,134 | 11.5% |
| $100k or more | 106,535 | 2.8% |

Median $25, p90 $13,557, max $1.53B.

---

## 5. Exchange contracts and relayers

- **Exchange-contract summary fills are already gone.** The card says
  `trades.parquet` drops the taker-order summary fills, where the exchange
  contract itself is the taker. In both samples, **0** trades have any of the
  four exchange contracts or the NegRisk adapter as maker or taker (Q4.2).
- **There is no "relayer" address in maker/taker.** Polymarket's gasless relayer
  submits transactions, but fills record the users' proxy wallets.
- **No self-trades** (maker = taker) in either sample.

So the planned "filter relayer/exchange-contract trades" step removes nothing
from this file. Staging should still assert it, as a data-quality check.

**`contract` distribution (Q4.2):**
- 2024-10: 88% NegRisk V1.
- 2026 week: 81% CTF V2, 19% NegRisk V2.

**Concentration (Q4.3).** The single largest taker address accounts for 1.59%
of trades (2024-10) and 3.60% (2026 week). Distinct takers: 233,207 and
118,203. Distinct makers: 77,426 and 44,254.

---

## 6. Trades (row-level, two samples)

### 6.1 Keys and integrity

- **Trade key (Q4.1).** `(block_number, log_index)` is unique, with 0 duplicates
  across 25,985,858 trades.
- **Orphans (Q4.4).** 0 trades fail to join to a market.
- **Token mapping (Q4.4).** `nonusdc_side` maps exactly to `asset_id` =
  `token1`/`token2`, with 0 mismatches. A YES-side (token1) price is therefore
  `price` for token1 rows and `1 − price` for token2 rows.
- **`event_id` disagreement (Q4.4).** 396 trades in the 2026 sample carry a
  different `event_id` from their market's current one, presumably because the
  market was regrouped later. Staging should take `event_id` from markets.

### 6.2 Directions

**Directions (Q4.5).** Only BUY/SELL pairs occur. There are no BUY/BUY ("mint")
or SELL/SELL ("merge") rows. Both token sides trade heavily: token2 makes up
29% of trades in 2024-10 and 48% in the 2026 week.

### 6.3 Which price to use

`price` differs from `usd_amount / token_amount` by more than 1e-4 on 25% of
trades (2024-10) and 33% (2026 week) (Q4.6). The gap is rounding in 6-decimal
amounts on small fills (Q4.10):

| Trade size | Mismatches |
|---|---|
| $100 or more | none |
| $10–100 | at most 0.001 |
| Under $1 | p99 up to 0.22, max 0.98 |

`price` is therefore the trade's actual price, and the implied ratio is noise
on dust trades.

### 6.4 Dust and zero amounts (Q4.6, Q4.11)

- **Under $1:** 28.3% (2024-10) and 27.6% (2026 week) of trades.
- **Median trade:** $10.70 and $2.98.
- **`usd_amount = 0`:** 117,200 and 216,906 trades, with prices in the normal
  range (sub-cent fills).

Prices of exactly 0 or 1 never appear in the samples, though the footer shows
both occur somewhere in the file.

### 6.5 Timestamp precision, ties and ordering

- **Precision.** `timestamp` is whole seconds (block time).
- **Ties (Q4.7).** 56.2% (2024-10) and 83.6% (2026 week) of trades share
  their (market, second) with another fill.
- **Prices within ties (Q4.13).** Within tied (market, second, side) groups,
  37.9% and 45.9% contain more than one price; the p90 spread is 0.002 and
  0.040. Only 27.4% and 52.2% of tied groups come from a single taker sweeping
  the book. The rest are several takers in the same second.
- **Ordering problems in 2024 (Q4.12).** In the 2024-10 sample, timestamps
  disagree with block order:
  - 212 blocks carry more than one timestamp.
  - 505 blocks are stamped earlier than the previous block, by up to 196 seconds.

  Neither is possible on-chain. The 2026 sample is clean. Trades should be
  ordered by `(block_number, log_index)`, not by `timestamp`.

### 6.6 Trades relative to `end_date` (timing only, Q4.8)

| | 2024-10 | 2026 week |
|---|---|---|
| Trades after their market's `end_date` | 4.22% | 6.91% |
| More than one day after | 0.87% | 0.13% |
| Markets traded after their `end_date` | 2,150 | 39,192 |
| Trades before `created_at` | 0.03% | 0.00% |

### 6.7 Composition (Q4.9)

- **2024-10:** `presidential-election` alone is 52.8% of trades and 70.3% of USD.
- **2026 week:** `btc-updown` is 43.6% of trades but 11.4% of USD. The crypto
  Up/Down series together are about 60% of trades.

---

## 7. Threats to the planned design

Ordered by how much each could change a conclusion. Each is paired with a
candidate handling to settle in the pre-registration.

**T1. The crypto comparison is confounded by market type.**
- *Problem:* nearly all crypto-keyword markets (about 794K Up/Down hits against
  800K crypto hits) are auto-generated Up/Down series lasting 5 minutes to
  1 day. Politics is 0.8% of closed markets. Crypto vs. non-crypto would mostly
  compare recurring, minutes-long, machine-generated price-direction markets
  against one-off questions, so subject matter would be confounded with
  lifetime, automation and trader mix.
- *Candidate handling:* pre-register a two-dimensional taxonomy, subject
  (crypto, politics, sports, weather, other) × format (recurring series vs.
  one-off). Make the primary comparison crypto vs. non-crypto *within* format
  and within lifetime band, or restrict the primary analysis to one-off
  markets and report series separately.

**T2. No true resolution time. This is the most serious threat.**
- *Problem:* `end_date` is a scheduled date, sometimes impossible (end before
  creation), sometimes far in the future for markets that closed early, and
  4–7% of trades happen after it. A snapshot "1 hour before `end_date`" can
  fall after the outcome is already effectively known, which would make
  markets look better calibrated than they are. RQ3 is affected as well: "only
  markets already resolved at trade time" needs a resolution timestamp.
- *Candidate handling:*
  - **(a, preferred)** Recover the actual resolution block and payout vector
    from the on-chain `ConditionResolution` events of the Conditional Tokens
    contract, keyed by `condition_id`. This is a new data source and needs
    approval.
  - **(b)** Use Gamma API resolution fields, if present.
  - **(c)** As a fallback, anchor at `min(end_date, last trade)` and exclude
    markets with heavy trading after `end_date`.

**T3. Resolution and void status are ambiguous, and disputes are invisible.**
- *Problem:* 15.4% of closed markets are not clean 0/1. 0.5/0.5 is ambiguous
  between voided and untraded. There is no dispute field.
- *Candidate handling:* on-chain payouts (T2a) settle this directly; a void is
  an equal payout. Otherwise, include clean 0/1 only and report exclusions
  broken down by category, since excluding "other" may not be random across
  categories.

**T4. Most markets are dead.**
- *Problem:* 41.5% of closed markets have zero volume, the median is $25, and
  28% of trades are under $1.
- *Candidate handling:* pre-register inclusion thresholds (minimum market
  volume, minimum trade size for a snapshot, maximum staleness of the last
  trade before the horizon), with sensitivity runs at alternative cut-offs.

**T5. The horizon changes the sample.**
- *Problem:* only about 36% of closed markets live past 7 days, and 67% past
  1 day. The 1-week sample is a different population from the 1-hour sample.
- *Candidate handling:* compare categories within each horizon, never across
  horizons, and report sample composition per horizon. Exclude pre-CLOB
  markets.

**T6. "YES" is arbitrary for about two-thirds of markets.**
- *Problem:* Over/Under, team names and Up/Down labels have no natural YES
  side. Brier score and log loss are unaffected by which side is chosen, but
  the calibration curve, calibration slope and the "<10¢" longshot definition
  all depend on it.
- *Candidate handling:* pre-register a side rule, for example token1 for the
  primary analysis, plus a symmetrized curve that uses both sides of each
  market. For RQ2, define the longshot as whichever side is priced below 10¢.

**T7. Dependence between markets.**
- *Problem:* neg_risk sets are mutually exclusive, and ladders put up to 488
  correlated markets in one event. Recurring series in *different* events
  (daily "Bitcoin above X") share the same underlying price on the same day.
- *Candidate handling:* event-clustered standard errors, as planned. Consider
  also clustering crypto series by underlying asset and day, and report the
  number of clusters.

**T8. The snapshot price is not well defined at one-second resolution.**
- *Problem:* most trades are tied within their second, prices differ within
  the tie, and 2024 timestamps can run up to 196 seconds backwards.
- *Candidate handling:* order by `(block_number, log_index)`. Pre-register the
  primary snapshot as the last non-dust trade, with a short-window VWAP as a
  sensitivity check. Convert token2 prices to YES-side with `1 − price`.

**T9. Time coverage.**
- *Problem:* 86% of trades are from 2026. A probable 1h52m gap starts at
  2026-08-31 23:12, and gaps within slices haven't been checked.
- *Candidate handling:* run the coverage scan (Section 8). Flag snapshots whose
  look-back window overlaps a gap, and report results by year.

**T10. Smart-money confounds.**
- *Problem:* top takers are high-frequency bots, at up to 3.6% of trades. A
  wallet's track record also needs resolution times (T2).
- *Candidate handling:* set minimum-history thresholds, analyse maker and taker
  roles separately, and handle bot and market-maker addresses explicitly.

**T11. Minor staging items.**
- `outcome_prices` is Python-repr, not JSON, and 40 non-empty strings fail to
  parse.
- 16 markets have an empty `event_id`.
- 396 sample trades disagree with their market's `event_id`; use markets'
  `event_id`.
- `active` and `archived` are constant and carry no information.

---

## 8. Open checks for Phase 2

1. **Per-minute trade-count scan** over the full `timestamp` column (about
   1.44 GB) to find gaps inside slices.
2. **Full-file assertions for staging:**
   - `(block_number, log_index)` is unique.
   - No contract addresses appear as maker or taker.
   - Every trade joins to a market.
   - `price` is in [0, 1].

   These read about 3.4–8 GB depending on the assertion.
3. **Decide the resolution-time source** (T2) before writing the
   pre-registration, since it changes the horizon definition.
4. **The 0 and 1 prices** the footer shows somewhere in the file: locate and
   count them.

---

## 9. Query index

| File | Contents |
|---|---|
| `sql/00_profile/00_sources.sql` | Pinned `hf://` views, UTC session |
| `sql/00_profile/01_schema.sql` | Q1.1–Q1.3: DESCRIBE, row counts, row groups |
| `sql/00_profile/02_footer_stats.sql` | Q2.1–Q2.7: null counts, column sizes, ranges, sort order, slices, gaps |
| `sql/00_profile/03_markets.sql` | Q3.0–Q3.12: keys, flags, resolution shape, labels, events, dates, lifetime, volume, category signals |
| `sql/00_profile/04_trades_sample.sql` | Q4.0–Q4.13: trade key, contracts, concentration, integrity, directions, price, dust, ties, ordering, timing, composition |
