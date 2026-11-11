-- Every fill with its wallets, full file, to local Parquet, for RQ3 (track records,
-- smart-money signal, maker and taker roles) and the C5 contract check.
-- One remote read (~19 GB: price-path columns, maker/taker, token_amount, directions).
-- Not restricted to resolved markets, so C5 covers the whole file; RQ3 filters downstream.
-- No outcome column. Scope via run_sql.py: --set run_day=2026-09-08 (smoke) or all.
-- Run after 00_sources.sql and 03_stg_trades.sql.


SET max_temp_directory_size = '500MB';

SET preserve_insertion_order = false;


-- Q0 Abort if the scope is unset or malformed.
SELECT error('pass --set run_day=YYYY-MM-DD or --set run_day=all')
WHERE getvariable('run_day') IS NULL
   OR (getvariable('run_day') <> 'all' AND TRY_CAST(getvariable('run_day') AS DATE) IS NULL);


-- Q1 Output path; the smoke run never overwrites the full extract.
SET VARIABLE wallet_trades_path = CASE getvariable('run_day')
    WHEN 'all' THEN 'data/processed/int_wallet_trades.parquet'
    ELSE 'data/processed/int_wallet_trades_smoke.parquet'
END;


-- Q2 Fills in scope (row-group metadata on the full run), to prove the extract is complete.
CREATE OR REPLACE TEMP TABLE fills_in_scope AS
SELECT count(*) AS n_rows
FROM stg_trades
WHERE getvariable('run_day') = 'all'
   OR (ts_unix >= epoch(TRY_CAST(getvariable('run_day') AS TIMESTAMPTZ))::UBIGINT
   AND ts_unix <  epoch(TRY_CAST(getvariable('run_day') AS TIMESTAMPTZ) + INTERVAL 1 DAY)::UBIGINT);


-- Q3 Extract. Raw price and side are kept (not token1_price) because a wallet's return is
-- on the token it actually traded; token_amount, not usd/price, avoids dust rounding.
COPY (
    SELECT
        market_id,
        block_number,
        log_index,
        ts_unix,
        nonusdc_side,
        raw_price,
        token_amount,
        usd_amount,
        maker,
        taker,
        maker_direction,
        taker_direction
    FROM stg_trades
    WHERE getvariable('run_day') = 'all'
       OR (ts_unix >= epoch(TRY_CAST(getvariable('run_day') AS TIMESTAMPTZ))::UBIGINT
       AND ts_unix <  epoch(TRY_CAST(getvariable('run_day') AS TIMESTAMPTZ) + INTERVAL 1 DAY)::UBIGINT)
) TO (getvariable('wallet_trades_path')) (FORMAT parquet, COMPRESSION zstd);


-- Q4 Completeness and footprint: extract rows must equal fills in scope. Expect match.
WITH meta AS (
    SELECT
        sum(total_compressed_size)                                          AS n_bytes,
        sum(row_group_num_rows) FILTER (WHERE path_in_schema = 'market_id') AS n_rows
    FROM parquet_metadata(getvariable('wallet_trades_path'))
)
SELECT
    s.n_rows                    AS n_fills_in_scope,
    m.n_rows                    AS n_extracted,
    s.n_rows = m.n_rows         AS complete,
    m.n_bytes / 1e9             AS gb_on_disk
FROM meta m
CROSS JOIN fills_in_scope s;


-- Q5 C5 contract list: as in profile Q4.2, plus the Conditional Tokens contract itself.
CREATE OR REPLACE TEMP TABLE c5_known AS
SELECT * FROM (VALUES
    ('0x4bfb41d5b3570defd03c39a9a4d8de6bd8b8982e'),     -- CTF Exchange
    ('0xc5d563a36ae78145c45a50134d48a1215220f80a'),     -- NegRisk CTF Exchange
    ('0xe111180000d2663c0091e4f400237545b87b996b'),     -- CTF Exchange V2
    ('0xe2222d279d744050d28e00520010520000310f59'),     -- NegRisk CTF Exchange V2
    ('0xd91e80cf2e7be2e162c6513ced06f1dd0da35296'),     -- NegRisk Adapter
    ('0x4d97dcd97ec945f40cf65f87097ace5ea0476045')      -- Conditional Tokens
) AS k(address);


-- Q5.1 C5 as a table macro, so the same predicates run on the extract and on the control.
CREATE OR REPLACE TEMP MACRO c5_counts(tbl) AS TABLE
SELECT
    count(*) FILTER (WHERE lower(maker) IN (SELECT address FROM c5_known))     AS n_contract_maker,
    count(*) FILTER (WHERE lower(taker) IN (SELECT address FROM c5_known))     AS n_contract_taker,
    count(*) FILTER (WHERE maker IS NULL OR taker IS NULL)                     AS n_null_wallet,
    count(*) FILTER (WHERE NOT regexp_full_match(lower(maker), '0x[0-9a-f]{40}')
                        OR NOT regexp_full_match(lower(taker), '0x[0-9a-f]{40}'))
                                                                                AS n_malformed_wallet,
    count(*) FILTER (WHERE maker_direction NOT IN ('BUY', 'SELL')
                        OR taker_direction NOT IN ('BUY', 'SELL')
                        OR maker_direction IS NULL OR taker_direction IS NULL)
                                                                                AS n_bad_direction
FROM query_table(tbl);


-- Q5.2 Positive control: one planted violation per check. Expect every count exactly 1,
-- or the check below cannot be trusted to have found nothing.
CREATE OR REPLACE TEMP TABLE c5_planted AS
SELECT * FROM (VALUES
    ('0x4bfb41d5b3570defd03c39a9a4d8de6bd8b8982e', '0x' || repeat('a', 40), 'BUY', 'SELL'),
    ('0x' || repeat('a', 40), '0xD91E80CF2E7BE2E162C6513CED06F1DD0DA35296', 'BUY', 'SELL'),
    (NULL, '0x' || repeat('a', 40), 'BUY', 'SELL'),
    ('0x' || repeat('a', 39), '0x' || repeat('b', 40), 'BUY', 'SELL'),
    ('0x' || repeat('a', 40), '0x' || repeat('b', 40), 'HOLD', 'SELL')
) AS t(maker, taker, maker_direction, taker_direction);

SELECT * FROM c5_counts('c5_planted');


-- Q5.3 C5 on the extract. Expect every count 0.
CREATE OR REPLACE VIEW wallet_trades_out AS
SELECT * FROM read_parquet(getvariable('wallet_trades_path'));

SELECT * FROM c5_counts('wallet_trades_out');


-- Q5.4 Reported, not asserted: self-trades (maker = taker) and the direction mix, since
-- BUY/BUY (mint) and SELL/SELL (merge) fills change how roles are read.
SELECT
    maker_direction,
    taker_direction,
    count(*)                                                AS n_fills,
    count(*) FILTER (WHERE lower(maker) = lower(taker))     AS n_self_trades
FROM read_parquet(getvariable('wallet_trades_path'))
GROUP BY ALL
ORDER BY n_fills DESC;
