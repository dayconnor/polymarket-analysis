-- Trade-level data-quality assertions over stg_trades (run 00_sources.sql and 03 first).
-- Every Q4 check returns 0 rows on success. Window comes from run_sql.py:
--   --set dq_day=2026-09-08   smoke run, one pruned UTC day
--   --set dq_day=all          full file
-- C5 (exchange contracts as maker/taker) runs in the RQ3 wallet extract, which reads
-- maker/taker (8 GB) anyway; no analysis notebook runs before it passes.


-- C4 is chunked to fit in memory; past this cap DuckDB errors instead of spilling more.
SET max_temp_directory_size = '500MB';


-- Q0 Abort if the window is unset or malformed: a NULL window scans nothing and every check passes.
SELECT error('pass --set dq_day=YYYY-MM-DD or --set dq_day=all')
WHERE getvariable('dq_day') IS NULL
   OR (getvariable('dq_day') <> 'all' AND TRY_CAST(getvariable('dq_day') AS DATE) IS NULL);


-- Q1 Trades in the window. getvariable folds to a constant, so the day filter prunes row
-- groups and 'all' removes the filter (no timestamp read on the full run). UBIGINT bounds
-- keep the pushed-down filter on the raw column.
CREATE OR REPLACE TEMP VIEW dq_trades AS
SELECT *
FROM stg_trades
WHERE getvariable('dq_day') = 'all'
   OR (ts_unix >= epoch(TRY_CAST(getvariable('dq_day') AS TIMESTAMPTZ))::UBIGINT
   AND ts_unix <  epoch(TRY_CAST(getvariable('dq_day') AS TIMESTAMPTZ) + INTERVAL 1 DAY)::UBIGINT);


-- Q1.1 Rows checked, so a vacuous pass is visible (row-group metadata on the full run).
CREATE OR REPLACE TEMP TABLE dq_rows_checked AS
SELECT count(*) AS n_rows
FROM dq_trades;


-- Q2 C1-C3 in one scan of market_id, price, nonusdc_side; keeps failing rows only.
-- The trade key is left out: projecting it would add 3.4 GB to this scan.
-- markets_subset holds every market id (00_extract_markets has no filter).
CREATE OR REPLACE TEMP TABLE dq_row_failures AS
SELECT
    t.market_id,
    t.raw_price,
    t.nonusdc_side,
    t.raw_price IS NULL OR t.raw_price NOT BETWEEN 0 AND 1     AS c1_bad_price,
    t.token1_price IS NULL                                      AS c2_no_token1_price,
    m.id IS NULL                                                AS c3_orphan
FROM dq_trades t
LEFT JOIN (SELECT id FROM 'data/raw/markets_subset.parquet') m ON m.id = t.market_id
WHERE c1_bad_price OR c2_no_token1_price OR c3_orphan;


-- Q3 C4 chunk plan from footer stats (no data read). Duplicate keys share a block, so
-- splitting on block_number is exact. Chunks are whole block islands (merged overlapping
-- row-group ranges; > not >=, so a block split across row groups stays in one island),
-- so each chunk prunes to its own row groups. 13 chunks of ~100M keys fit in memory.
CREATE OR REPLACE TEMP TABLE dq_c4_chunks AS
WITH rg AS (
    SELECT
        row_group_id,
        row_group_num_rows                  AS n_rows,
        stats_min_value::UBIGINT            AS block_lo,
        stats_max_value::UBIGINT            AS block_hi
    FROM parquet_metadata(getvariable('trades_path'))
    WHERE path_in_schema = 'block_number'
),

flagged AS (
    SELECT
        *,
        coalesce(block_lo > max(block_hi) OVER (ORDER BY block_lo, row_group_id
                                                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
                 true)                      AS starts_island
    FROM rg
),

islands AS (
    SELECT
        sum(starts_island::INT) OVER (ORDER BY block_lo, row_group_id) AS island,
        n_rows, block_lo, block_hi
    FROM flagged
),

island_rows AS (
    SELECT island, min(block_lo) AS block_lo, max(block_hi) AS block_hi, sum(n_rows) AS n_rows
    FROM islands
    GROUP BY island
),

assigned AS (
    SELECT
        *,
        floor(13 * (sum(n_rows) OVER (ORDER BY island) - n_rows)
                 / sum(n_rows) OVER ())::INT + 1    AS chunk
    FROM island_rows
)

SELECT chunk, min(block_lo) AS block_lo, max(block_hi) AS block_hi, sum(n_rows) AS n_rows
FROM assigned
GROUP BY chunk
ORDER BY chunk;


-- Q3.1 Chunk bounds as variables so the block filter is a constant and prunes.
SET VARIABLE c4_lo = (SELECT list(block_lo ORDER BY chunk) FROM dq_c4_chunks);

SET VARIABLE c4_hi = (SELECT list(block_hi ORDER BY chunk) FROM dq_c4_chunks);


-- Q3.2 C4 duplicate trade keys, one chunk per statement (3.4 GB in all on the full run).
CREATE OR REPLACE TEMP TABLE dq_dup_keys (block_number UBIGINT, log_index UINTEGER, n_rows BIGINT);

CREATE OR REPLACE TEMP MACRO dq_dup_keys_in_chunk(k) AS TABLE
SELECT block_number, log_index, count(*) AS n_rows
FROM dq_trades
WHERE block_number BETWEEN getvariable('c4_lo')[k] AND getvariable('c4_hi')[k]
GROUP BY block_number, log_index
HAVING count(*) > 1;

INSERT INTO dq_dup_keys FROM dq_dup_keys_in_chunk(1);
INSERT INTO dq_dup_keys FROM dq_dup_keys_in_chunk(2);
INSERT INTO dq_dup_keys FROM dq_dup_keys_in_chunk(3);
INSERT INTO dq_dup_keys FROM dq_dup_keys_in_chunk(4);
INSERT INTO dq_dup_keys FROM dq_dup_keys_in_chunk(5);
INSERT INTO dq_dup_keys FROM dq_dup_keys_in_chunk(6);
INSERT INTO dq_dup_keys FROM dq_dup_keys_in_chunk(7);
INSERT INTO dq_dup_keys FROM dq_dup_keys_in_chunk(8);
INSERT INTO dq_dup_keys FROM dq_dup_keys_in_chunk(9);
INSERT INTO dq_dup_keys FROM dq_dup_keys_in_chunk(10);
INSERT INTO dq_dup_keys FROM dq_dup_keys_in_chunk(11);
INSERT INTO dq_dup_keys FROM dq_dup_keys_in_chunk(12);
INSERT INTO dq_dup_keys FROM dq_dup_keys_in_chunk(13);


-- Q4.1 C1 price NULL or outside [0, 1].
SELECT * FROM dq_row_failures WHERE c1_bad_price LIMIT 20;

-- Q4.2 C2 token1_price NULL (nonusdc_side not token1/token2, or NULL price).
SELECT * FROM dq_row_failures WHERE c2_no_token1_price LIMIT 20;

-- Q4.3 C3 market_id missing from markets.
SELECT * FROM dq_row_failures WHERE c3_orphan LIMIT 20;

-- Q4.4 C4 duplicate (block_number, log_index).
SELECT * FROM dq_dup_keys LIMIT 20;

-- Q4.5 Guard: the window matched no trades.
SELECT * FROM dq_rows_checked WHERE n_rows = 0;

-- Q4.6 Guard: the C4 plan skipped a chunk (13 INSERTs above assume 13).
SELECT count(*) AS n_chunks FROM dq_c4_chunks HAVING count(*) <> 13;


-- Q5 Summary: violating rows per check over the rows checked.
-- C4 counts extra copies beyond the first, i.e. rows a dedup would drop.
SELECT check_name, n_violations::BIGINT AS n_violations, n_rows AS n_rows_checked
FROM (
    SELECT 'C1 price outside [0,1]' AS check_name, count(*) FILTER (WHERE c1_bad_price) AS n_violations, 1 AS ord
    FROM dq_row_failures
    UNION ALL
    SELECT 'C2 token1_price NULL', count(*) FILTER (WHERE c2_no_token1_price), 2
    FROM dq_row_failures
    UNION ALL
    SELECT 'C3 orphan market_id', count(*) FILTER (WHERE c3_orphan), 3
    FROM dq_row_failures
    UNION ALL
    SELECT 'C4 duplicate trade key', coalesce(sum(n_rows - 1), 0), 4
    FROM dq_dup_keys
)
CROSS JOIN dq_rows_checked
ORDER BY ord;
