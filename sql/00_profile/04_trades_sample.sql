-- 04_trades_sample.sql
-- Row-level checks on two time-slice samples of trades.parquet:
--   2024-10      (7 row groups, ~7.0M trades, pre-boom, election month)
--   2026-09-08wk (19 row groups, ~18.9M trades, V2 exchange era)
-- The file is chunked by time slice, so a timestamp filter downloads only
-- these 26 row groups: ~400 MB of trade columns (transaction_hash excluded,
-- 26 GB on its own). Nothing here compares prices with outcomes.

-- Q4.0a Trade sample. The WHERE on timestamp is pushed down to the Parquet
-- reader, which skips every row group whose min/max cannot match.
CREATE OR REPLACE TEMP TABLE t AS
SELECT
    CASE WHEN timestamp < epoch(TIMESTAMPTZ '2025-01-01') THEN '2024-10' ELSE '2026-09-08wk' END AS sample,
    timestamp, block_number, log_index, contract, market_id, event_id,
    maker, taker, price, usd_amount, token_amount,
    maker_direction, taker_direction, nonusdc_side, asset_id
FROM src_trades
WHERE (timestamp >= epoch(TIMESTAMPTZ '2024-10-01') AND timestamp < epoch(TIMESTAMPTZ '2024-11-01'))
   OR (timestamp >= epoch(TIMESTAMPTZ '2026-09-08') AND timestamp < epoch(TIMESTAMPTZ '2026-09-16'));

-- Q4.0b Market columns needed for joins (token ids are ~290 MB of the transfer).
CREATE OR REPLACE TEMP TABLE mk AS
SELECT id, token1, token2, event_id, event_slug, created_at, end_date, closed, neg_risk
FROM src_markets;

-- Q4.1 Is (block_number, log_index) a unique trade key? On-chain, a log
-- index is unique within a block, so it should be, and it avoids the 26 GB
-- transaction_hash column entirely.
SELECT
    sample,
    count(*)                                        AS n_trades,
    count(DISTINCT (block_number, log_index))       AS n_distinct_keys,
    count(*) - count(DISTINCT (block_number, log_index)) AS n_duplicate_rows
FROM t
GROUP BY sample ORDER BY sample;

-- Q4.2 Exchange contracts. The card says trades.parquet already drops the
-- taker-summary fills where the exchange itself is the taker. Check that no
-- known exchange/adapter contract appears as maker or taker, and count
-- self-trades (maker = taker), which are wash trades by definition.
WITH known AS (
    SELECT * FROM (VALUES
        ('0x4bfb41d5b3570defd03c39a9a4d8de6bd8b8982e', 'CTF_EXCHANGE'),
        ('0xc5d563a36ae78145c45a50134d48a1215220f80a', 'NEGRISK_CTF_EXCHANGE'),
        ('0xe111180000d2663c0091e4f400237545b87b996b', 'CTF_EXCHANGE_V2'),
        ('0xe2222d279d744050d28e00520010520000310f59', 'NEGRISK_CTF_EXCHANGE_V2'),
        ('0xd91e80cf2e7be2e162c6513ced06f1dd0da35296', 'NEGRISK_ADAPTER')
    ) AS k(address, label)
)
SELECT
    sample,
    count(*)                                                   AS n_trades,
    count(*) FILTER (WHERE taker IN (SELECT address FROM known)) AS taker_is_contract,
    count(*) FILTER (WHERE maker IN (SELECT address FROM known)) AS maker_is_contract,
    count(*) FILTER (WHERE maker = taker)                      AS self_trades
FROM t
GROUP BY sample ORDER BY sample;

SELECT sample, contract, count(*) AS n_trades
FROM t GROUP BY ALL ORDER BY sample, n_trades DESC;

-- Q4.3 Concentration: share of trades where the top takers appear. A single
-- address taking a large share would be a router/bot worth inspecting before
-- the smart-money question (it could look "smart" mechanically).
WITH ranked AS (
    SELECT sample, taker, count(*) AS n,
        100.0 * count(*) / sum(count(*)) OVER (PARTITION BY sample) AS pct,
        row_number() OVER (PARTITION BY sample ORDER BY count(*) DESC) AS rk
    FROM t GROUP BY sample, taker
)
SELECT sample, rk, left(taker, 10) || '...' AS taker_prefix, n, round(pct, 2) AS pct_of_trades
FROM ranked WHERE rk <= 5 ORDER BY sample, rk;

SELECT sample, count(DISTINCT taker) AS n_takers, count(DISTINCT maker) AS n_makers,
       count(DISTINCT market_id) AS n_markets_traded
FROM t GROUP BY sample ORDER BY sample;

-- Q4.4 Referential integrity. Every trade should join to a market, its
-- event_id should agree with the market's, and asset_id should be the
-- market's token1 when nonusdc_side = 'token1' (else token2). That mapping is
-- what lets us convert every trade into a YES-side (token1) price.
SELECT
    t.sample,
    count(*)                                                       AS n_trades,
    count(*) FILTER (WHERE mk.id IS NULL)                          AS orphan_trades,
    count(*) FILTER (WHERE mk.id IS NOT NULL AND t.event_id <> mk.event_id) AS event_id_mismatch,
    count(*) FILTER (WHERE t.nonusdc_side = 'token1' AND t.asset_id <> mk.token1) AS token1_mismatch,
    count(*) FILTER (WHERE t.nonusdc_side = 'token2' AND t.asset_id <> mk.token2) AS token2_mismatch,
    count(*) FILTER (WHERE t.nonusdc_side NOT IN ('token1', 'token2'))            AS other_side
FROM t LEFT JOIN mk ON t.market_id = mk.id
GROUP BY t.sample ORDER BY t.sample;

-- Q4.5 Direction combinations. Normal fills are BUY/SELL pairs. BUY/BUY would
-- be a "mint" match (a YES buyer matched with a NO buyer) and SELL/SELL a
-- "merge"; in both, the row's price is for nonusdc_side only.
SELECT sample, maker_direction, taker_direction, nonusdc_side, count(*) AS n_trades
FROM t GROUP BY ALL ORDER BY sample, n_trades DESC;

-- Q4.6 Price and amount sanity. price should equal usd_amount / token_amount.
-- Prices of exactly 0 or 1 make logit(price) infinite. Dust trades (< $1)
-- would let a trivial trade set a market's "last price".
SELECT
    sample,
    count(*)                                                          AS n_trades,
    count(*) FILTER (WHERE price <= 0)                                AS price_le_0,
    count(*) FILTER (WHERE price >= 1)                                AS price_ge_1,
    count(*) FILTER (WHERE token_amount <= 0 OR usd_amount <= 0)      AS nonpositive_amount,
    count(*) FILTER (WHERE token_amount > 0
                     AND abs(price - usd_amount / token_amount) > 1e-4) AS price_ne_usd_over_tokens,
    round(100.0 * count(*) FILTER (WHERE usd_amount < 1) / count(*), 1) AS pct_under_1usd,
    quantile_cont(usd_amount, 0.5)                                    AS median_usd
FROM t GROUP BY sample ORDER BY sample;

-- Q4.7 Timestamp precision and ties. Timestamps are whole seconds (block
-- time), so several fills in one market can share a timestamp. "Last trade
-- before the horizon" therefore needs a deterministic tie-break:
-- (timestamp, block_number, log_index). Also confirm block order agrees with
-- time order, so block_number is a valid tie-breaker.
WITH per_sec AS (
    SELECT sample, market_id, timestamp, count(*) AS n
    FROM t GROUP BY ALL
)
SELECT
    sample,
    sum(n)                                         AS n_trades,
    round(100.0 * sum(n) FILTER (WHERE n > 1) / sum(n), 1) AS pct_trades_sharing_market_second,
    count(*) FILTER (WHERE n > 1)                  AS n_tied_market_seconds
FROM per_sec GROUP BY sample ORDER BY sample;

SELECT
    sample,
    count(*) FILTER (WHERE block_number < prev_block AND timestamp > prev_ts) AS block_time_disorder
FROM (
    SELECT sample, block_number, timestamp,
        lag(block_number) OVER (PARTITION BY sample ORDER BY timestamp, block_number) AS prev_block,
        lag(timestamp)    OVER (PARTITION BY sample ORDER BY timestamp, block_number) AS prev_ts
    FROM t
)
GROUP BY sample ORDER BY sample;

-- Q4.8 Trade timing versus market metadata (times only, no prices).
-- Trades after end_date mean end_date is not when trading stopped, so it
-- cannot simply anchor "1 hour before resolution". Trades before created_at
-- would mean created_at is unreliable as a start time.
SELECT
    t.sample,
    count(*)                                                             AS n_trades,
    round(100.0 * count(*) FILTER (WHERE to_timestamp(t.timestamp) > mk.end_date) / count(*), 2)   AS pct_after_end_date,
    round(100.0 * count(*) FILTER (WHERE to_timestamp(t.timestamp) > mk.end_date + INTERVAL 1 DAY) / count(*), 2) AS pct_over_1d_after_end_date,
    round(100.0 * count(*) FILTER (WHERE to_timestamp(t.timestamp) < mk.created_at) / count(*), 2) AS pct_before_created_at,
    count(DISTINCT t.market_id) FILTER (WHERE to_timestamp(t.timestamp) > mk.end_date) AS n_markets_traded_after_end
FROM t JOIN mk ON t.market_id = mk.id
GROUP BY t.sample ORDER BY t.sample;

-- Q4.9 Which market series the trades come from (slug stem as in Q3.11).
-- Shows whether trading activity, not just market count, is dominated by
-- recurring crypto series.
WITH s AS (
    SELECT t.sample, array_to_string(string_split(mk.event_slug, '-')[1:2], '-') AS slug_stem,
           count(*) AS n_trades, sum(t.usd_amount) AS usd
    FROM t JOIN mk ON t.market_id = mk.id
    GROUP BY ALL
)
SELECT sample, slug_stem, n_trades,
    round(100.0 * n_trades / sum(n_trades) OVER (PARTITION BY sample), 1) AS pct_trades,
    round(100.0 * usd / sum(usd) OVER (PARTITION BY sample), 1)           AS pct_usd
FROM s
QUALIFY row_number() OVER (PARTITION BY sample ORDER BY n_trades DESC) <= 10
ORDER BY sample, n_trades DESC;

-- Q4.10 Follow-up to Q4.6: when price <> usd_amount / token_amount, by how
-- much, and for what trade sizes? Bucket the ratio implied/price. Rounding of
-- 6-decimal amounts on tiny fills would show up as noise concentrated in
-- small trades; a systematic offset (e.g. fees) would show a fixed ratio.
SELECT
    sample,
    CASE WHEN usd_amount < 1 THEN 'a: <$1' WHEN usd_amount < 10 THEN 'b: $1-10'
         WHEN usd_amount < 100 THEN 'c: $10-100' ELSE 'd: $100+' END AS size_bucket,
    count(*) AS n_trades,
    count(*) FILTER (WHERE abs(price - usd_amount / token_amount) > 1e-4) AS n_mismatch,
    round(quantile_cont(abs(price - usd_amount / token_amount), 0.5), 5)  AS median_abs_diff,
    round(quantile_cont(abs(price - usd_amount / token_amount), 0.99), 5) AS p99_abs_diff,
    round(max(abs(price - usd_amount / token_amount)), 4)                 AS max_abs_diff
FROM t
WHERE token_amount > 0
GROUP BY ALL ORDER BY sample, size_bucket;

-- Q4.11 Follow-up to Q4.6: what do zero/negative-amount rows look like?
SELECT sample,
    usd_amount = 0 AS usd_zero, token_amount = 0 AS token_zero,
    count(*) AS n_trades,
    min(price) AS min_price, max(price) AS max_price
FROM t
WHERE usd_amount <= 0 OR token_amount <= 0
GROUP BY ALL ORDER BY sample, n_trades DESC;

-- Q4.12 Follow-up to Q4.7: size of the block/timestamp disagreements. On
-- Polygon, block timestamps never decrease, so for each block take its
-- min/max timestamp, then compare consecutive blocks. If timestamps run
-- backwards, block_number (not timestamp) is the trustworthy order.
WITH b AS (
    -- timestamp is unsigned (UBIGINT); cast to signed so a backwards
    -- difference is a negative number instead of an overflow error.
    SELECT sample, block_number, min(timestamp)::BIGINT AS ts_min, max(timestamp)::BIGINT AS ts_max
    FROM t GROUP BY ALL
)
SELECT
    sample,
    count(*)                                                   AS n_blocks,
    count(*) FILTER (WHERE ts_max <> ts_min)                   AS blocks_with_multiple_timestamps,
    count(*) FILTER (WHERE ts_min < prev_ts_max)               AS blocks_earlier_than_previous_block,
    max(prev_ts_max - ts_min) FILTER (WHERE ts_min < prev_ts_max) AS max_backwards_seconds
FROM (SELECT *, lag(ts_max) OVER (PARTITION BY sample ORDER BY block_number) AS prev_ts_max FROM b)
GROUP BY sample ORDER BY sample;

-- Q4.13 Follow-up to Q4.7: what are the same-second ties? If most are one
-- taker order sweeping several maker orders at different prices, then "the
-- last fill" is just the deepest level swept, and a per-second or
-- per-transaction VWAP is a better snapshot price. Price spread inside a tied
-- (market, second, side) group shows how much the choice matters.
WITH g AS (
    SELECT sample, market_id, timestamp, nonusdc_side,
        count(*)                AS n_fills,
        count(DISTINCT taker)   AS n_takers,
        max(price) - min(price) AS price_spread
    FROM t GROUP BY ALL
    HAVING count(*) > 1
)
SELECT
    sample,
    count(*)                                                  AS n_tied_groups,
    round(100.0 * count(*) FILTER (WHERE n_takers = 1) / count(*), 1) AS pct_single_taker,
    round(quantile_cont(n_fills, 0.5), 1)                     AS median_fills_per_group,
    round(100.0 * count(*) FILTER (WHERE price_spread > 0) / count(*), 1)    AS pct_with_price_spread,
    round(quantile_cont(price_spread, 0.9), 3)                AS p90_price_spread
FROM g GROUP BY sample ORDER BY sample;
