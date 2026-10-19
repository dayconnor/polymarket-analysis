-- 03_markets.sql
-- Profile of markets.parquet (4,049,900 rows, one per market).
-- Outcome rule for this phase: outcome_prices is inspected for its FORMAT only
-- (clean 0/1, 50/50, other). Which side won is never broken out, so no
-- base rates or price-vs-outcome information is produced here.

-- Q3.0 Pull the needed columns once into an in-memory temp table (~120 MB
-- transfer). token1/token2/condition_id (425 MB together) are left out; they
-- are only needed for joins in Phase 2.
CREATE OR REPLACE TEMP TABLE m AS
SELECT
    id, question, slug, answer1, answer2, closed, active, archived,
    outcome_prices, volume, event_id, event_slug, event_title,
    created_at, end_date, updated_at, neg_risk
FROM src_markets;

-- Q3.1 Key uniqueness and empty strings. The footer showed zero NULLs, but an
-- empty string '' is not NULL, so missing values could hide there instead.
SELECT
    count(*)                                   AS n_rows,
    count(DISTINCT id)                         AS n_distinct_id,
    count(DISTINCT slug)                       AS n_distinct_slug,
    count(DISTINCT event_id)                   AS n_distinct_event_id,
    count(*) FILTER (WHERE trim(event_id) = '')       AS empty_event_id,
    count(*) FILTER (WHERE trim(question) = '')       AS empty_question,
    count(*) FILTER (WHERE trim(event_slug) = '')     AS empty_event_slug,
    count(*) FILTER (WHERE trim(answer1) = '' OR trim(answer2) = '') AS empty_answer,
    count(*) FILTER (WHERE trim(outcome_prices) IN ('', '[]')) AS empty_outcome_prices
FROM m;

-- Q3.2 Status flags. closed = settled per the card; active/archived are
-- Polymarket UI flags. The cross-tab shows which combinations actually occur.
SELECT closed, active, archived, neg_risk, count(*) AS n_markets
FROM m
GROUP BY ALL
ORDER BY n_markets DESC;

-- Q3.3 Resolution format. Parse the JSON string into a list of doubles, then
-- classify by shape only:
--   clean_0_1   = one entry exactly 1 and the other exactly 0 (either order)
--   half_half   = both 0.5, Polymarket's convention for a 50/50 (voided) market
--   other       = anything else (unresolved, partially settled, or odd)
--   unparseable = not a 2-element numeric list
-- Grouped by `closed`, so we see how resolution status maps onto the flag.
-- The string comes in two encodings: JSON ["0", "1"] and Python-repr
-- ['0', '1'], so single quotes are swapped for double quotes before parsing,
-- and TRY_CAST turns anything still unparseable into NULL instead of erroring.
CREATE OR REPLACE TEMP VIEW m_res AS
WITH parsed AS (
    SELECT *,
        TRY_CAST(TRY_CAST(replace(outcome_prices, '''', '"') AS JSON) AS DOUBLE[]) AS op
    FROM m
)
SELECT *,
    CASE
        WHEN op IS NULL OR len(op) <> 2 OR list_has_any(op, [NULL::DOUBLE]) THEN 'unparseable'
        WHEN list_sort(op) = [0.0, 1.0]         THEN 'clean_0_1'
        WHEN op = [0.5, 0.5]                    THEN 'half_half'
        ELSE 'other'
    END AS res_format
FROM parsed;

SELECT closed, res_format, count(*) AS n_markets
FROM m_res
GROUP BY ALL
ORDER BY closed, n_markets DESC;

-- Q3.3b Which string encoding each row uses (a staging concern).
SELECT
    CASE WHEN outcome_prices LIKE '[''%' THEN 'python_repr'
         WHEN outcome_prices LIKE '["%' THEN 'json'
         ELSE 'other: ' || left(outcome_prices, 12) END AS encoding,
    count(*) AS n_markets
FROM m
GROUP BY ALL
ORDER BY n_markets DESC;

-- Q3.4 For closed markets in the 'other' bucket, how far from a clean
-- settlement are they? greatest(p1, p2) is symmetric in the two sides, so it
-- shows "how decisive" without revealing which side was ahead.
SELECT
    round(greatest(op[1], op[2]), 2) AS larger_side_value,
    round(op[1] + op[2], 3)          AS sum_of_sides,
    count(*)                         AS n_markets
FROM m_res
WHERE closed = 1 AND res_format = 'other'
GROUP BY ALL
ORDER BY n_markets DESC
LIMIT 15;

-- Q3.5 Outcome labels. Every market has exactly two tokens, but the labels
-- tell us whether it is a Yes/No question, an Up/Down crypto market, a
-- team-vs-team sports market, etc. This matters for defining "the YES side".
SELECT answer1, answer2, count(*) AS n_markets
FROM m
GROUP BY ALL
ORDER BY n_markets DESC
LIMIT 20;

SELECT
    count(*) FILTER (WHERE answer1 = 'Yes' AND answer2 = 'No') AS yes_no,
    count(*) FILTER (WHERE answer1 = 'Up' AND answer2 = 'Down') AS up_down,
    count(*) FILTER (WHERE NOT (answer1 = 'Yes' AND answer2 = 'No')
                       AND NOT (answer1 = 'Up' AND answer2 = 'Down')) AS other_labels,
    count(*) AS n_markets
FROM m;

-- Q3.6 Event structure. Count markets per event, separately for neg_risk
-- (mutually exclusive multi-outcome sets, e.g. "Who will win the election?"
-- split into one Yes/No market per candidate) and non-neg_risk events.
WITH ev AS (
    SELECT event_id,
        count(*)               AS n_markets,
        max(neg_risk)          AS any_neg_risk,
        min(neg_risk)          AS all_neg_risk
    FROM m
    GROUP BY event_id
)
SELECT
    CASE WHEN all_neg_risk = 1 THEN 'neg_risk'
         WHEN any_neg_risk = 0 THEN 'not_neg_risk'
         ELSE 'mixed' END                    AS event_type,
    count(*)                                 AS n_events,
    sum(n_markets)                           AS n_markets,
    count(*) FILTER (WHERE n_markets = 1)    AS events_with_1_market,
    quantile_cont(n_markets, 0.5)            AS median_markets_per_event,
    quantile_cont(n_markets, 0.99)           AS p99_markets_per_event,
    max(n_markets)                           AS max_markets_per_event
FROM ev
GROUP BY ALL
ORDER BY n_events DESC;

-- Q3.7 Dates. Ranges of each timestamp, plus anomalies: markets that "end"
-- before they are created, and closed markets whose end_date is still in the
-- future relative to the data cutoff (resolved early, so end_date is NOT the
-- resolution time for them).
SELECT
    min(created_at) AS min_created, max(created_at) AS max_created,
    min(end_date)   AS min_end,     max(end_date)   AS max_end,
    min(updated_at) AS min_updated, max(updated_at) AS max_updated,
    count(*) FILTER (WHERE end_date < created_at)                         AS end_before_created,
    count(*) FILTER (WHERE closed = 1 AND end_date > TIMESTAMPTZ '2026-10-05') AS closed_but_end_in_future,
    count(*) FILTER (WHERE closed = 0 AND end_date < TIMESTAMPTZ '2026-09-04') AS open_but_ended_over_30d_ago
FROM m;

-- Q3.8 Scheduled lifetime (end_date - created_at). The planned horizons are
-- 1 week, 1 day and 1 hour before resolution; a market that lives less than
-- a horizon cannot have a snapshot at it. Shares are of all closed markets.
SELECT
    count(*)                                                           AS n_closed,
    round(100.0 * count(*) FILTER (WHERE end_date - created_at < INTERVAL 1 HOUR) / count(*), 1) AS pct_under_1h,
    round(100.0 * count(*) FILTER (WHERE end_date - created_at < INTERVAL 1 DAY)  / count(*), 1) AS pct_under_1d,
    round(100.0 * count(*) FILTER (WHERE end_date - created_at < INTERVAL 7 DAY)  / count(*), 1) AS pct_under_7d,
    quantile_cont(epoch(end_date - created_at) / 3600, 0.25) AS p25_hours,
    quantile_cont(epoch(end_date - created_at) / 3600, 0.50) AS median_hours,
    quantile_cont(epoch(end_date - created_at) / 3600, 0.75) AS p75_hours
FROM m
WHERE closed = 1;

-- Q3.9 Market creation by quarter, with scheduled lifetime. Shows when the
-- flood of markets arrived and whether it is short-lived markets.
SELECT
    date_trunc('quarter', created_at)                         AS created_quarter,
    count(*)                                                  AS n_markets,
    count(*) FILTER (WHERE end_date - created_at < INTERVAL 1 DAY) AS n_under_1d,
    round(sum(volume) / 1e6, 1)                               AS volume_musd
FROM m
GROUP BY ALL
ORDER BY created_quarter;

-- Q3.10 Volume distribution (metadata field, USD). Many tiny markets would
-- dominate an unweighted market-level analysis.
SELECT
    count(*) FILTER (WHERE volume = 0)        AS n_zero_volume,
    count(*) FILTER (WHERE volume < 100)      AS n_under_100usd,
    count(*) FILTER (WHERE volume >= 10000)   AS n_10k_plus,
    count(*) FILTER (WHERE volume >= 100000)  AS n_100k_plus,
    quantile_cont(volume, 0.5)                AS median_volume,
    quantile_cont(volume, 0.9)                AS p90_volume,
    max(volume)                               AS max_volume
FROM m
WHERE closed = 1;

-- Q3.11 What the text fields say about category. There is no category/tag
-- column, so the only category signal is text. The first two hyphen-separated
-- words of event_slug act as a "series stem" (e.g. 'btc-updown'), which
-- exposes auto-generated recurring series.
SELECT
    array_to_string(string_split(event_slug, '-')[1:2], '-') AS slug_stem,
    count(*)                                                 AS n_markets,
    count(DISTINCT event_id)                                 AS n_events,
    round(sum(volume) / 1e6, 1)                              AS volume_musd,
    any_value(question)                                      AS example_question
FROM m
GROUP BY slug_stem
ORDER BY n_markets DESC
LIMIT 30;

-- Q3.12 Crude, UNVALIDATED keyword hit rates, only to size the problem for
-- the Phase 2 classifier. Regexes on lowercased question + event_slug.
-- Word boundaries (\b) avoid matches like 'eth' inside 'method'.
WITH t AS (
    SELECT lower(question || ' ' || event_slug) AS txt, volume, closed FROM m
)
SELECT
    count(*)                                                                     AS n_markets,
    count(*) FILTER (WHERE regexp_matches(txt, '\b(bitcoin|btc|ethereum|eth|solana|sol|xrp|dogecoin|doge|crypto)\b'))     AS crypto_kw,
    count(*) FILTER (WHERE regexp_matches(txt, '\b(up or down|updown)\b'))                                                 AS up_down_kw,
    count(*) FILTER (WHERE regexp_matches(txt, '\b(election|president|presidential|senate|congress|trump|biden|harris|parliament|prime minister|governor|mayor)\b')) AS politics_kw,
    count(*) FILTER (WHERE regexp_matches(txt, '\b(nba|nfl|mlb|nhl|ufc|premier league|champions league|la liga|serie a|bundesliga|vs\.?|fifa|tennis|atp|wta|f1|grand prix)\b')) AS sports_kw
FROM t
WHERE closed = 1;
