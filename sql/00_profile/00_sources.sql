-- 00_sources.sql
-- Remote sources, pinned to dataset commit 73bc1adc (2026-10-05 release,
-- data through 2026-10-04 23:59:59 UTC). Pinning the commit means every query
-- in this project reads the same bytes even if the maintainers re-release.
-- These are VIEWS, not copies: nothing is downloaded until a query selects
-- columns, and DuckDB then fetches only those columns' byte ranges.

-- All timestamps are reported in UTC, regardless of the machine's local zone.
SET TimeZone = 'UTC';

-- HF allows 5,000 resolver requests per 5-minute window with a token (3,000 without),
-- and a full-column scan needs more. Waits of 20 s x1.5 over 6 retries (~415 s) outlast
-- one window, so a 429 pauses the scan instead of failing it.
SET http_retries = 6;

SET http_retry_wait_ms = 20000;

SET http_retry_backoff = 1.5;

SET VARIABLE trades_path = 'hf://datasets/SII-WANGZJ/Polymarket_data@73bc1adc43b05709d2cde3bf41ef4111eda3f4fc/trades.parquet';

SET VARIABLE markets_path = 'hf://datasets/SII-WANGZJ/Polymarket_data@73bc1adc43b05709d2cde3bf41ef4111eda3f4fc/markets.parquet';

CREATE OR REPLACE VIEW src_trades AS
SELECT * FROM read_parquet(getvariable('trades_path'));

CREATE OR REPLACE VIEW src_markets AS
SELECT * FROM read_parquet(getvariable('markets_path'));
