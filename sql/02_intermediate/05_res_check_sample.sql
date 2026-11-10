-- Section 7 resolution-check sample: 200 random kept markets plus 30 per subject x format
-- cell (D4), drawn after the classifier passed round 1. Writes ids and block hints for
-- pipeline/fetch_onchain_resolution.py; no payout or price column leaves this file.


-- Q1 Kept markets with their frozen-classifier cell.
CREATE OR REPLACE TEMP TABLE res_frame AS
SELECT r.market_id, r.condition_id, r.closed_time, c.subject, c.format
FROM 'data/processed/stg_market_resolution.parquet' r
JOIN 'data/processed/int_market_class.parquet' c ON c.market_id = r.market_id
WHERE r.exclusion_reason IS NULL;


-- Q2 Random arm (the 99% rule) and cell arm (D4), each with its own seed.
CREATE OR REPLACE TEMP TABLE res_sample AS
WITH random_arm AS (
    SELECT market_id
    FROM res_frame
    ORDER BY md5(market_id || ':res-check-random')
    LIMIT 200
),
cell_arm AS (
    SELECT market_id
    FROM res_frame
    QUALIFY row_number() OVER (
        PARTITION BY subject, format ORDER BY md5(market_id || ':res-check-cell')) <= 30
)
SELECT
    f.*,
    f.market_id IN (SELECT market_id FROM random_arm)  AS in_random,
    f.market_id IN (SELECT market_id FROM cell_arm)    AS in_cell
FROM res_frame f
WHERE f.market_id IN (SELECT market_id FROM random_arm)
   OR f.market_id IN (SELECT market_id FROM cell_arm);


-- Q3 Block hints: last trade at or before closed_time, and first trade, per sampled market.
-- The resolution event should follow the last pre-close trade; the first trade bounds a
-- fallback search. Markets with no trades get NULL hints and are searched by timestamp.
CREATE OR REPLACE TEMP TABLE res_hints AS
SELECT
    s.market_id,
    max(p.block_number) FILTER (WHERE p.ts_unix <= epoch(s.closed_time))   AS hint_block,
    max(p.ts_unix) FILTER (WHERE p.ts_unix <= epoch(s.closed_time))        AS hint_ts_unix,
    min(p.block_number)                                                     AS first_block
FROM res_sample s
LEFT JOIN 'data/processed/int_price_paths.parquet' p ON p.market_id = s.market_id
GROUP BY s.market_id;


-- Q4 Hand-off sheet for the fetcher.
COPY (
    SELECT
        s.market_id,
        s.condition_id,
        epoch(s.closed_time)::BIGINT    AS closed_ts_unix,
        s.subject,
        s.format,
        s.in_random,
        s.in_cell,
        h.hint_block,
        h.hint_ts_unix,
        h.first_block
    FROM res_sample s
    JOIN res_hints h USING (market_id)
    ORDER BY s.market_id
) TO 'data/processed/res_check_sample.csv' (HEADER);


-- Q5 Arm sizes and cells: 200 random, 30 per cell (fewer only if the cell is smaller).
SELECT subject, format, count(*) AS n, sum(in_random::INTEGER) AS n_random,
       sum(in_cell::INTEGER) AS n_cell, count(hint_block) AS n_with_hint
FROM read_csv('data/processed/res_check_sample.csv')
GROUP BY ALL
ORDER BY subject, format;


-- Q5.1 Expect 0 rows: 200 random, 270 cell rows, unique 0x condition ids.
SELECT 'random' AS check_name, count(*) AS n FROM res_sample WHERE in_random HAVING count(*) <> 200
UNION ALL
SELECT 'cell', count(*) FROM res_sample WHERE in_cell HAVING count(*) <> 270
UNION ALL
SELECT 'bad condition_id', count(*) FROM res_sample
WHERE NOT regexp_full_match(condition_id, '0x[0-9a-f]{64}') HAVING count(*) > 0
UNION ALL
SELECT 'dup condition_id', count(*) - count(DISTINCT condition_id) FROM res_sample
HAVING count(*) <> count(DISTINCT condition_id);
