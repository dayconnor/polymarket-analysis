-- One row per fill: typed, keyed, token1-side price, flags. A VIEW, not a copy.
-- Reads src_trades (00_sources.sql must run first in the same session).
-- Nothing is downloaded until a query selects columns; downstream queries
-- should filter on ts_unix so row groups are pruned (profile §2: time slices).
-- No row filters here: exchange-contract and orphan checks are assertions
-- in 04, not WHERE clauses, so the view never forces a maker/taker read.
-- event_id is omitted (stale on some trades, profile §6.1): take it from markets.
-- transaction_hash is never selected (26 GB).


-- Q1 Define staging view.
CREATE OR REPLACE VIEW stg_trades AS
SELECT
    -- Key and ordering: order by (block_number, log_index), not timestamp.
    block_number,
    log_index,
    -- Raw seconds keep row-group min/max pruning; trade_time is for reading.
    timestamp                                   AS ts_unix,
    to_timestamp(timestamp)                     AS trade_time,
    market_id,
    price                                       AS raw_price,
    nonusdc_side,
    -- Explicit WHEN for both sides: an unexpected side value yields NULL
    -- (caught by the 04 assertions) instead of a silently flipped price.
    CASE nonusdc_side
        WHEN 'token1' THEN price
        WHEN 'token2' THEN 1 - price
    END                                         AS token1_price,
    usd_amount,
    token_amount,
    -- Parties and roles for RQ3; never filtered here.
    maker,
    taker,
    maker_direction,
    taker_direction,
    contract,
    -- Flags only; thresholds are fixed in docs/hypotheses.md §3.
    usd_amount < 1                              AS is_dust,
    price IN (0, 1)                             AS is_boundary_price
FROM src_trades;


-- Q2 Smoke test on one day of a weekly slice (pruned to a few row groups).
SELECT *
FROM stg_trades
WHERE ts_unix >= epoch(TIMESTAMPTZ '2026-09-08')
  AND ts_unix <  epoch(TIMESTAMPTZ '2026-09-09')
LIMIT 10;
