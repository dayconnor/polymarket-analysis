# Classifier Codebook — Subject and Format

Operational definitions for the subject and format labels fixed in
`docs/hypotheses.md` (Section 3, taxonomy; Section 6, validation). The rules in
`sql/02_intermediate/02_int_market_class.sql` implement this codebook; the
hand labels are assigned from it. Where Section 3 leaves a case open, the
resolution below was fixed before any validation label existed. Neither the
rules nor the labels use price or outcome information.

---

## 1. Subject

The subject is the domain whose events determine resolution, not the domain
the question mentions.

| Subject | Definition |
|---|---|
| **crypto** | Resolution depends on a crypto-asset price or index, a crypto project or token event (launch, airdrop, public sale, listing, FDV after launch, depeg, hack), crypto ETF flows or approval, or crypto-specific regulation. |
| **politics** | Elections, government or official actions, legislation, courts, geopolitics, and the statements or posts of political figures and government accounts. |
| **sports** | Games, matches, tournaments, awards, player statistics, transfers and drafts, including esports, chess, golf, motorsport and pickleball. |
| **weather** | Meteorological quantities and events: temperature, precipitation, snowfall, storms, hurricanes, tornado risk. |
| **other** | Everything else: equities, commodities, FX and indices; macroeconomics and central banks; technology, entertainment, culture, science, health. |

**Edge cases (resolved in advance):**

1. **Mention and post-count markets are never crypto** (Section 3). They are
   politics when the speaker or account is a political figure or government
   body, otherwise other. *"Will Trump say 'Bitcoin'?"* is politics; *"Will CZ
   post 0–19 times?"* is other; *"Will the announcers say 'Goal' 20+ times?"*
   is other.
2. **Equity prices are other, including crypto companies.** *"Will Coinbase
   (COIN) close above $300?"* depends on an equity price, which is none of the
   crypto conditions above. A Coinbase listing decision would be crypto.
3. **DOGE as the Department of Government Efficiency is politics**; Dogecoin
   is crypto.
4. **Team and player names do not set the subject.** Tulsa Golden Hurricane
   and Kendal Tornado FC are sports.
5. **Crypto-adjacent personalities** (Elon Musk, CZ) set the subject only when
   resolution depends on a crypto condition.
6. **Esports, chess and other mind sports are sports.** Whether these count as
   sports is disputed; they are grouped here because their markets share the
   structure of sports markets (matches, maps, tournament winners, handicaps
   and totals) and arrive through the same sports feeds (`sports_market_type`).
   The choice does not affect RQ1, which compares crypto with non-crypto
   markets, and sports and other are both non-crypto. It affects only the
   descriptive subject breakdowns and the Section 7 strata (D4).

## 2. Format

| Format | Definition |
|---|---|
| **template** | The market belongs to a recurring, auto-generated family repeated on a fixed cadence (5 minutes to monthly) in which only the date or window and the strike or bin change, and resolution depends on a measured quantity: a price direction or threshold, a temperature, a count. |
| **event** | Everything else: sports games and props, elections, and one-off questions, including one-off price questions (*"Will Bitcoin reach $150k by December 31?"*). |

**Edge cases (resolved in advance):**

1. **Sports markets are always event** (Section 3), including recurring
   over/under lines.
2. **Recurring count ladders are template**: weekly post or tweet counts,
   daily TSA throughput, weekly box-office bins, daily app-store rank, weekly
   approval Up/Down.
3. **A dated threshold without a series** (*"Solana above $140 on August
   23?"*) is template: it is the pre-series form of the same ladders.
4. **A threshold by a deadline or within a month** (*"before October"*, *"in
   April"*) is event unless the series slug names a recurring family.

## 3. Hand-labeling procedure

- The labeler sees `market_id`, `question`, `slug`, `event_slug`,
  `series_slug` and `sports_market_type`, in random order, and never the
  predicted subject or format, any price, or any outcome.
- Each row receives `subject`, `format`, and an optional `note`; `unsure = 1`
  marks a row the labeler could not decide from this codebook. Unsure rows are
  reported, not dropped.
- The codebook is not edited during a labeling round.

## 4. Validation sample and metrics

- **Frame:** markets in the primary analysis population at any horizon (at
  least one snapshot within the staleness cap, `volume_usd` ≥ 1,000), since
  classifier errors matter where the tests run.
- **Draw:** 80 markets per predicted subject (400 in all), fixed seed, after
  the rules are frozen by commit.
- **Crypto precision:** share of the predicted-crypto stratum labeled crypto.
- **Crypto recall:** labeled-crypto counts per stratum are scaled by stratum
  size N_k / 80, so that

  recall = (N_crypto · p_crypto) / Σ_k (N_k · p_k),

  where p_k is the share of stratum k labeled crypto.
- **Format accuracy:** stratum accuracies weighted by N_k.
- **Acceptance** (Section 6): crypto precision and recall ≥ 0.95 and format
  accuracy ≥ 0.95. Below threshold, the rules are revised and validated on a
  fresh sample, and every round is reported.
