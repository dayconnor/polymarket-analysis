-- One row per (market, horizon) with a qualifying trade before t_h: snapshot price,
-- staleness, liquidity (D2) and cluster. Local Parquet only (01_int_price_paths, 02).
-- No outcome column: token1_won joins only after the section 7 check.
-- The primary snapshot (Section 3) and the no-cap sensitivity (5.4) are the same trade,
-- the last >= $1 trade before t_h; the primary one also needs within_cap.
-- Scope: --set run_day=all (full extract) or any date (the smoke extract).


SET max_temp_directory_size = '500MB';

SET TimeZone = 'UTC';


-- Q0 Abort if the scope is unset or malformed.
SELECT error('pass --set run_day=YYYY-MM-DD or --set run_day=all')
WHERE getvariable('run_day') IS NULL
   OR (getvariable('run_day') <> 'all' AND TRY_CAST(getvariable('run_day') AS DATE) IS NULL);


-- Q1 Input and output paths; the smoke run reads and writes *_smoke files only.
SET VARIABLE paths_in = CASE getvariable('run_day')
    WHEN 'all' THEN 'data/processed/int_price_paths.parquet'
    ELSE 'data/processed/int_price_paths_smoke.parquet'
END;

SET VARIABLE snapshots_out = CASE getvariable('run_day')
    WHEN 'all' THEN 'data/processed/mart_snapshots.parquet'
    ELSE 'data/processed/mart_snapshots_smoke.parquet'
END;


-- Q2 Anchors: every resolved market x horizon, t_h = closedTime - h.
-- past_data_end marks anchors D3 excludes (t_h after the last observed trade time).
CREATE OR REPLACE TEMP TABLE anchors AS
WITH horizons AS (
    SELECT *
    FROM (VALUES ('1w', INTERVAL 7 DAY, 604800), ('1d', INTERVAL 1 DAY, 86400), ('1h', INTERVAL 1 HOUR, 3600))
        AS h(horizon, h_len, h_secs)
)
SELECT
    r.market_id,
    h.horizon,
    h.h_secs,
    r.closed_time - h.h_len                                         AS t_h,
    epoch(r.closed_time - h.h_len)                                  AS t_h_unix,
    r.closed_time - h.h_len > TIMESTAMPTZ '2026-10-04 23:59:59'     AS past_data_end
FROM 'data/processed/stg_market_resolution.parquet' r
CROSS JOIN horizons h
WHERE r.exclusion_reason IS NULL;


-- Q3 Snapshot trade: last trade by (block_number, log_index) with timestamp < t_h and
-- usd_amount >= 1. A per-group arg_max, not a window over ~1B rows, so memory stays
-- at one row per anchor.
CREATE OR REPLACE TEMP TABLE snaps AS
SELECT
    a.market_id,
    a.horizon,
    arg_max(
        {'block_number': p.block_number, 'log_index': p.log_index,
         'ts_unix': p.ts_unix, 'token1_price': p.token1_price},
        {'block_number': p.block_number, 'log_index': p.log_index}
    )                                                               AS snap
FROM read_parquet(getvariable('paths_in')) p
JOIN anchors a
  ON a.market_id = p.market_id
 AND p.ts_unix < a.t_h_unix
WHERE p.usd_amount >= 1
  AND NOT a.past_data_end
GROUP BY a.market_id, a.horizon;


-- Q4 Liquidity (D2): USD volume of every trade strictly before the snapshot trade by key,
-- dust included. Key, not timestamp, because timestamps run backwards by up to 196 s.
CREATE OR REPLACE TEMP TABLE liquidity AS
SELECT
    s.market_id,
    s.horizon,
    sum(p.usd_amount)                                               AS liquidity_usd,
    count(*)                                                        AS n_trades_before
FROM read_parquet(getvariable('paths_in')) p
JOIN snaps s
  ON s.market_id = p.market_id
 AND (p.block_number < s.snap.block_number
      OR (p.block_number = s.snap.block_number AND p.log_index < s.snap.log_index))
GROUP BY s.market_id, s.horizon;


-- Q5 Write the mart. A snapshot that is the market's first trade has no prior volume (0).
-- Cluster = series_slug, else event_id (Section 3), prefixed so the two cannot collide.
COPY (
    SELECT
        a.market_id,
        a.horizon,
        a.t_h,
        s.snap.token1_price                                         AS snap_price,
        to_timestamp(s.snap.ts_unix)                                AS snap_time,
        s.snap.block_number                                         AS snap_block_number,
        s.snap.log_index                                            AS snap_log_index,
        a.t_h_unix - s.snap.ts_unix                                 AS staleness_s,
        s.snap.ts_unix >= a.t_h_unix - a.h_secs                     AS within_cap,
        coalesce(l.liquidity_usd, 0)                                AS liquidity_usd,
        coalesce(l.n_trades_before, 0)                              AS n_trades_before,
        coalesce('s:' || r.series_slug, 'e:' || r.event_id)         AS cluster_id,
        r.event_id,
        r.series_slug,
        r.volume_usd,
        r.created_at,
        r.end_date,
        r.closed_time
    FROM anchors a
    JOIN snaps s
      ON s.market_id = a.market_id AND s.horizon = a.horizon
    LEFT JOIN liquidity l
      ON l.market_id = a.market_id AND l.horizon = a.horizon
    JOIN 'data/processed/stg_market_resolution.parquet' r
      ON r.market_id = a.market_id
) TO (getvariable('snapshots_out')) (FORMAT parquet, COMPRESSION zstd);


-- Q6 Drop report per horizon: anchors -> D3 -> any qualifying trade -> within cap
-- -> primary population (volume_usd >= 1,000).
SELECT
    a.horizon,
    count(*)                                                        AS n_anchors,
    count(*) FILTER (WHERE a.past_data_end)                         AS n_dropped_d3,
    count(m.market_id)                                              AS n_with_snapshot,
    count(*) FILTER (WHERE m.within_cap)                            AS n_within_cap,
    count(*) FILTER (WHERE m.within_cap AND m.volume_usd >= 1000)   AS n_primary,
    count(DISTINCT m.cluster_id) FILTER (WHERE m.within_cap AND m.volume_usd >= 1000)
                                                                    AS n_primary_clusters,
    median(m.staleness_s) FILTER (WHERE m.within_cap)               AS median_staleness_s
FROM anchors a
LEFT JOIN read_parquet(getvariable('snapshots_out')) m
  ON m.market_id = a.market_id AND m.horizon = a.horizon
GROUP BY a.horizon
ORDER BY min(a.h_secs) DESC;


-- Q7.1 Duplicate (market_id, horizon). Expect 0 rows.
SELECT market_id, horizon, count(*) AS n
FROM read_parquet(getvariable('snapshots_out'))
GROUP BY market_id, horizon
HAVING count(*) > 1;

-- Q7.2 Snapshot not strictly before t_h, past the data end, or price outside [0, 1]. Expect 0 rows.
SELECT *
FROM read_parquet(getvariable('snapshots_out'))
WHERE snap_time >= t_h
   OR t_h > TIMESTAMPTZ '2026-10-04 23:59:59'
   OR snap_price IS NULL OR snap_price NOT BETWEEN 0 AND 1
LIMIT 20;

-- Q7.3 Guard: the mart is empty. Expect 0 rows.
SELECT count(*) AS n_rows
FROM read_parquet(getvariable('snapshots_out'))
HAVING count(*) = 0;
