-- Every trade of every resolved market (02 kept set), full history, to local Parquet.
-- One remote read (~8.4 GB); horizon windows, liquidity (D2), VWAP and the no-cap
-- sensitivity are all derived locally from this file. Trades after closedTime are kept
-- so the drop report comes from the same pass; downstream filters on closed_time.
-- No outcome column: outcomes join only in the marts, after the section 7 check.
-- Scope via run_sql.py: --set run_day=2026-09-08 (smoke, *_smoke.parquet) or --set run_day=all.
-- Run after 00_sources.sql and 03_stg_trades.sql.


SET max_temp_directory_size = '500MB';

-- Lets COPY stream rows as they arrive instead of buffering to keep file order.
SET preserve_insertion_order = false;


-- Q0 Abort if the scope is unset or malformed.
SELECT error('pass --set run_day=YYYY-MM-DD or --set run_day=all')
WHERE getvariable('run_day') IS NULL
   OR (getvariable('run_day') <> 'all' AND TRY_CAST(getvariable('run_day') AS DATE) IS NULL);


-- Q1 Join side: resolved markets, timing only.
CREATE OR REPLACE TEMP TABLE resolved_markets AS
SELECT market_id, closed_time
FROM 'data/processed/stg_market_resolution.parquet'
WHERE exclusion_reason IS NULL;


-- Q1.1 Join key must be unique. With 04 C4 (unique trade key in the source), this proves
-- the inner join cannot duplicate a trade, without re-aggregating ~1B keys. Expect 0 rows.
SELECT market_id, count(*) AS n
FROM resolved_markets
GROUP BY market_id
HAVING count(*) > 1;


-- Q1.2 Trades in scope (row-group metadata on the full run), for the drop report.
CREATE OR REPLACE TEMP TABLE trades_in_scope AS
SELECT count(*) AS n_rows
FROM stg_trades
WHERE getvariable('run_day') = 'all'
   OR (ts_unix >= epoch(TRY_CAST(getvariable('run_day') AS TIMESTAMPTZ))::UBIGINT
   AND ts_unix <  epoch(TRY_CAST(getvariable('run_day') AS TIMESTAMPTZ) + INTERVAL 1 DAY)::UBIGINT);


-- Q2 Output path; the smoke run never overwrites the full extract.
SET VARIABLE price_paths_path = CASE getvariable('run_day')
    WHEN 'all' THEN 'data/processed/int_price_paths.parquet'
    ELSE 'data/processed/int_price_paths_smoke.parquet'
END;


-- Q3 Extract. Inner join drops trades of unresolved or excluded markets. File order is
-- arbitrary (no sort: ~1B rows would spill far past the cap); order by key downstream.
COPY (
    SELECT
        t.market_id,
        t.block_number,
        t.log_index,
        t.ts_unix,
        t.token1_price,
        t.usd_amount
    FROM stg_trades t
    JOIN resolved_markets m ON m.market_id = t.market_id
    WHERE getvariable('run_day') = 'all'
       OR (t.ts_unix >= epoch(TRY_CAST(getvariable('run_day') AS TIMESTAMPTZ))::UBIGINT
       AND t.ts_unix <  epoch(TRY_CAST(getvariable('run_day') AS TIMESTAMPTZ) + INTERVAL 1 DAY)::UBIGINT)
) TO (getvariable('price_paths_path')) (FORMAT parquet, COMPRESSION zstd);


-- Q4 Drop report: every in-scope trade counted once by fate.
SELECT
    s.n_rows                                                        AS n_trades_in_scope,
    s.n_rows - count(*)                                             AS n_dropped_not_resolved,
    count(*) FILTER (WHERE p.ts_unix >= epoch(m.closed_time))       AS n_at_or_after_close,
    count(*) FILTER (WHERE p.ts_unix <  epoch(m.closed_time))       AS n_before_close,
    count(DISTINCT p.market_id)                                     AS n_markets_with_trades,
    (SELECT count(*) FROM resolved_markets) - count(DISTINCT p.market_id)
                                                                    AS n_resolved_without_trades
FROM read_parquet(getvariable('price_paths_path')) p
JOIN resolved_markets m ON m.market_id = p.market_id
CROSS JOIN trades_in_scope s
GROUP BY s.n_rows;


-- Q4.1 Local footprint of the extract.
WITH meta AS (
    SELECT
        sum(total_compressed_size)                                          AS n_bytes,
        sum(row_group_num_rows) FILTER (WHERE path_in_schema = 'market_id') AS n_rows
    FROM parquet_metadata(getvariable('price_paths_path'))
)
SELECT n_bytes / 1e6 AS mb_on_disk, n_rows, n_bytes / n_rows AS bytes_per_row
FROM meta;


-- Q5 Guard: the extract is empty. Expect 0 rows.
SELECT count(*) AS n_rows
FROM read_parquet(getvariable('price_paths_path'))
HAVING count(*) = 0;
