-- 01_schema.sql
-- Schema, row counts, row-group layout. Metadata only: every query here reads
-- the Parquet footer, never row data, so cost is a few MB regardless of file size.

-- Q1.1 Column names and types of trades.parquet (footer schema).
DESCRIBE src_trades;

-- Q1.2 Column names and types of markets.parquet (footer schema).
DESCRIBE src_markets;

-- Q1.3 Exact row counts and number of row groups, straight from the footers.
-- A row group is the unit DuckDB can skip, so the count tells us how finely
-- a timestamp filter can prune.
SELECT 'trades' AS file, num_rows, num_row_groups, format_version, created_by
FROM parquet_file_metadata(getvariable('trades_path'))
UNION ALL
SELECT 'markets', num_rows, num_row_groups, format_version, created_by
FROM parquet_file_metadata(getvariable('markets_path'));
