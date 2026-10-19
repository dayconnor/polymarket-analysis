-- 02_footer_stats.sql
-- Whole-file profiling from Parquet row-group statistics. Still metadata only:
-- parquet_metadata() returns one row per (row group x column) with min, max,
-- null count and byte sizes, all stored in the footer.

-- Q2.1 trades: exact null counts and on-disk size per column.
-- Summing stats_null_count over all 1,261 row groups gives whole-file null
-- rates without reading data. compressed_gb is what a full scan of that
-- column would download, which is how data volume is estimated before any
-- larger query. missing_stats > 0 would mean a null count is unknown.
SELECT
    path_in_schema                                   AS column_name,
    sum(num_values)                                  AS n_values,
    sum(stats_null_count)                            AS n_null,
    round(100.0 * sum(stats_null_count) / sum(num_values), 4) AS pct_null,
    count(*) FILTER (WHERE stats_null_count IS NULL) AS missing_stats,
    round(sum(total_compressed_size) / 1e9, 2)       AS compressed_gb
FROM parquet_metadata(getvariable('trades_path'))
GROUP BY path_in_schema
ORDER BY min(column_id);

-- Q2.2 markets: same null and size profile.
SELECT
    path_in_schema                                   AS column_name,
    sum(num_values)                                  AS n_values,
    sum(stats_null_count)                            AS n_null,
    round(100.0 * sum(stats_null_count) / sum(num_values), 4) AS pct_null,
    count(*) FILTER (WHERE stats_null_count IS NULL) AS missing_stats,
    round(sum(total_compressed_size) / 1e6, 1)       AS compressed_mb
FROM parquet_metadata(getvariable('markets_path'))
GROUP BY path_in_schema
ORDER BY min(column_id);

-- Q2.3 trades: date range and value ranges from row-group min/max.
-- Stats are stored as strings, so they are cast back to their real types.
-- price outside [0, 1] or negative amounts here would be a data-quality flag.
SELECT
    path_in_schema AS column_name,
    min(TRY_CAST(stats_min_value AS DOUBLE)) AS file_min,
    max(TRY_CAST(stats_max_value AS DOUBLE)) AS file_max
FROM parquet_metadata(getvariable('trades_path'))
WHERE path_in_schema IN ('timestamp', 'block_number', 'price', 'usd_amount', 'token_amount', 'log_index')
GROUP BY path_in_schema;

SELECT
    to_timestamp(min(stats_min_value::UBIGINT)) AS first_trade_utc,
    to_timestamp(max(stats_max_value::UBIGINT)) AS last_trade_utc
FROM parquet_metadata(getvariable('trades_path'))
WHERE path_in_schema = 'timestamp';

-- Q2.4 trades: is the file sorted by time?
-- For each row group, compare its min timestamp to the previous group's max
-- (LAG over row_group_id). If no group starts before the previous one ends,
-- the file is time-ordered and a WHERE on timestamp skips whole row groups.
WITH rg AS (
    SELECT
        row_group_id,
        row_group_num_rows,
        stats_min_value::UBIGINT AS ts_min,
        stats_max_value::UBIGINT AS ts_max
    FROM parquet_metadata(getvariable('trades_path'))
    WHERE path_in_schema = 'timestamp'
)
SELECT
    count(*)                                                        AS n_row_groups,
    count(*) FILTER (WHERE ts_min < lag_max)                        AS n_overlapping,
    round(avg(row_group_num_rows))                                  AS avg_rows_per_group,
    round(median((ts_max - ts_min) / 3600.0), 2)                    AS median_hours_per_group,
    round(max((ts_max - ts_min) / 3600.0), 1)                       AS max_hours_per_group
FROM (SELECT *, lag(ts_max) OVER (ORDER BY row_group_id) AS lag_max FROM rg);

-- Q2.5 trades: if not time-sorted, what IS the sort order?
-- Pivot each row group's timestamp and market_id min/max side by side, then
-- look at the first few groups. Calendar-month timestamp bounds plus ascending,
-- non-overlapping market_id ranges would mean "chunked by month, sorted by
-- market within month", so a market_id filter prunes row groups.
-- Note: market_id stats compare as strings, not numbers.
WITH rg AS (
    SELECT
        row_group_id,
        max(CASE WHEN path_in_schema = 'timestamp' THEN to_timestamp(stats_min_value::UBIGINT) END) AS ts_min,
        max(CASE WHEN path_in_schema = 'timestamp' THEN to_timestamp(stats_max_value::UBIGINT) END) AS ts_max,
        max(CASE WHEN path_in_schema = 'market_id' THEN stats_min_value END) AS mkt_min,
        max(CASE WHEN path_in_schema = 'market_id' THEN stats_max_value END) AS mkt_max
    FROM parquet_metadata(getvariable('trades_path'))
    WHERE path_in_schema IN ('timestamp', 'market_id')
    GROUP BY row_group_id
)
SELECT * FROM rg ORDER BY row_group_id LIMIT 12;

-- Q2.6 Summarize the pattern over all row groups: group them by the calendar
-- month of ts_max and count how many row groups each month has, and whether
-- market_id ranges within a month are non-overlapping (sorted).
WITH rg AS (
    SELECT
        row_group_id,
        max(CASE WHEN path_in_schema = 'timestamp' THEN to_timestamp(stats_min_value::UBIGINT) END) AS ts_min,
        max(CASE WHEN path_in_schema = 'timestamp' THEN to_timestamp(stats_max_value::UBIGINT) END) AS ts_max,
        max(CASE WHEN path_in_schema = 'market_id' THEN stats_min_value END) AS mkt_min,
        max(CASE WHEN path_in_schema = 'market_id' THEN stats_max_value END) AS mkt_max
    FROM parquet_metadata(getvariable('trades_path'))
    WHERE path_in_schema IN ('timestamp', 'market_id')
    GROUP BY row_group_id
),
flagged AS (
    SELECT *,
        date_trunc('month', ts_min) = date_trunc('month', ts_max) AS within_one_month,
        mkt_min < lag(mkt_max) OVER (PARTITION BY date_trunc('month', ts_max) ORDER BY row_group_id) AS mkt_overlap
    FROM rg
)
SELECT
    count(*)                                   AS n_row_groups,
    count(*) FILTER (WHERE within_one_month)   AS n_within_one_calendar_month,
    count(*) FILTER (WHERE mkt_overlap)        AS n_market_overlap_within_month,
    count(DISTINCT date_trunc('month', ts_max)) AS n_months
FROM flagged;

-- Q2.7 Time slices and coverage gaps (gaps-and-islands interval merge).
-- Sort row groups by start time. Running max of all EARLIER groups' end time
-- tells us how far coverage already extends; if a group starts after that, a
-- new slice begins and (start - running_end) is a gap with no trades at all.
-- Large gaps would make "last trade before the horizon" silently stale.
CREATE OR REPLACE TEMP VIEW rg_gaps AS
WITH rg AS (
    SELECT
        row_group_id,
        row_group_num_rows,
        to_timestamp(stats_min_value::UBIGINT) AS ts_min,
        to_timestamp(stats_max_value::UBIGINT) AS ts_max
    FROM parquet_metadata(getvariable('trades_path'))
    WHERE path_in_schema = 'timestamp'
),
running AS (
    SELECT *,
        max(ts_max) OVER (ORDER BY ts_min, row_group_id
                          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS covered_until
    FROM rg
)
SELECT *,
    ts_min > covered_until            AS starts_new_slice,
    greatest(ts_min - covered_until, INTERVAL 0 SECOND) AS gap_before
FROM running;

-- Q2.7a Slices per year: how fine-grained time pruning is in each period.
SELECT
    year(ts_min)                                         AS yr,
    count(*) FILTER (WHERE starts_new_slice OR covered_until IS NULL) AS n_slices,
    count(*)                                             AS n_row_groups,
    sum(row_group_num_rows)                              AS n_rows
FROM rg_gaps
GROUP BY yr
ORDER BY yr;

-- Q2.7b The largest coverage gaps in the whole history.
SELECT covered_until AS gap_from, ts_min AS gap_to, gap_before
FROM rg_gaps
WHERE starts_new_slice
ORDER BY gap_before DESC
LIMIT 15;
