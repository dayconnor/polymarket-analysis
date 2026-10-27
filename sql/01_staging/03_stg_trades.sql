-- One row per fill. A view over src_trades (run 00_sources.sql first).
-- No row filters: contract and orphan checks are assertions in 04, so the
-- view never forces a maker/taker read. event_id comes from markets (stale here).


-- Q1 Define staging view.
CREATE OR REPLACE VIEW stg_trades AS
SELECT
    block_number,
    log_index,
    -- Filter on ts_unix downstream: row-group pruning needs the raw column.
    timestamp                                   AS ts_unix,
    to_timestamp(timestamp)                     AS trade_time,
    market_id,
    price                                       AS raw_price,
    nonusdc_side,
    -- No ELSE: an unexpected side yields NULL, not a silently flipped price.
    CASE nonusdc_side
        WHEN 'token1' THEN price
        WHEN 'token2' THEN 1 - price
    END                                         AS token1_price,
    usd_amount,
    token_amount,
    maker,
    taker,
    maker_direction,
    taker_direction,
    contract,
    usd_amount < 1                              AS is_dust,
    price IN (0, 1)                             AS is_boundary_price
FROM src_trades;


-- Q2 Smoke test on one pruned day.
SELECT *
FROM stg_trades
WHERE ts_unix >= epoch(TIMESTAMPTZ '2026-09-08')
  AND ts_unix <  epoch(TIMESTAMPTZ '2026-09-09')
LIMIT 10;
