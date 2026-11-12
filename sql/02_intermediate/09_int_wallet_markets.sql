-- One row per (wallet, resolved market): net token positions, net cost and USD traded
-- before closedTime, for RQ3 track records (03_marts/02). Also int_wallets: one row per
-- wallet with an integer id, fill count and the T10 bot flag.
-- Self-trades and legs at or after closedTime are dropped and counted. No outcome column:
-- the mart applies pnl = net_tokens1 * won + net_tokens2 * (1 - won) - net_cost, which
-- equals the Section 4 per-trade sum because that sum is linear in tokens.
-- Local Parquet only (08_int_wallet_trades, stg_market_resolution).
-- Scope: --set run_day=all (full extract) or any date (the smoke extract).


SET memory_limit = '12GB';

SET max_temp_directory_size = '500MB';

SET preserve_insertion_order = false;


-- Q0 Abort if the scope is unset or malformed.
SELECT error('pass --set run_day=YYYY-MM-DD or --set run_day=all')
WHERE getvariable('run_day') IS NULL
   OR (getvariable('run_day') <> 'all' AND TRY_CAST(getvariable('run_day') AS DATE) IS NULL);


-- Q1 Paths; the smoke run reads and writes *_smoke files only.
SET VARIABLE sfx = CASE getvariable('run_day') WHEN 'all' THEN '' ELSE '_smoke' END;

SET VARIABLE trades_in = 'data/processed/int_wallet_trades' || getvariable('sfx') || '.parquet';

SET VARIABLE wallets_out = 'data/processed/int_wallets' || getvariable('sfx') || '.parquet';

SET VARIABLE wm_prefix = 'data/processed/int_wallet_markets' || getvariable('sfx') || '_p';


-- Q2 Inputs. Self-trades (maker = taker) net to zero P&L but would add USD and a market
-- to the wallet's record, so they are dropped here, before any count.
CREATE OR REPLACE VIEW fills_in AS
SELECT *
FROM read_parquet(getvariable('trades_in'))
WHERE maker <> taker;

CREATE OR REPLACE TEMP TABLE resolved AS
SELECT market_id, epoch(closed_time)::UBIGINT AS close_unix
FROM 'data/processed/stg_market_resolution.parquet'
WHERE exclusion_reason IS NULL;


-- Q3 Fill counts per wallet (both roles, every market in the file), in 8 hash slices:
-- one exact GROUP BY over 2.5B address strings overflowed 12 GB plus the 500 MB spill cap.
CREATE OR REPLACE TEMP MACRO wallet_counts(k) AS TABLE
SELECT wallet, count(*) AS n_fills
FROM (
    SELECT maker AS wallet FROM fills_in
    UNION ALL
    SELECT taker FROM fills_in
)
WHERE hash(wallet) % 8 = k
GROUP BY wallet;

CREATE OR REPLACE TEMP TABLE counts (wallet VARCHAR, n_fills BIGINT);

INSERT INTO counts SELECT * FROM wallet_counts(0);

INSERT INTO counts SELECT * FROM wallet_counts(1);

INSERT INTO counts SELECT * FROM wallet_counts(2);

INSERT INTO counts SELECT * FROM wallet_counts(3);

INSERT INTO counts SELECT * FROM wallet_counts(4);

INSERT INTO counts SELECT * FROM wallet_counts(5);

INSERT INTO counts SELECT * FROM wallet_counts(6);

INSERT INTO counts SELECT * FROM wallet_counts(7);


-- Q3.1 Wallet dimension. Ids follow address order, so they are reproducible. Bot = top 0.1%
-- by fill count, ties at the cutoff included. The flag uses later fill counts but no
-- outcome, so it cannot leak a result.
COPY (
    SELECT
        row_number() OVER (ORDER BY wallet)::UINTEGER                   AS wallet_id,
        wallet,
        n_fills,
        n_fills >= quantile_disc(n_fills, 0.999) OVER ()                AS is_bot
    FROM counts
) TO (getvariable('wallets_out')) (FORMAT parquet, COMPRESSION zstd);

CREATE OR REPLACE TEMP TABLE wallets AS
SELECT wallet_id, wallet
FROM read_parquet(getvariable('wallets_out'));


-- Q4 One partition of the (wallet, market) aggregate: wallets with wallet_id % 16 = k.
-- About 300M pairs do not fit in 12 GB at once; partitioning by wallet keeps each
-- wallet's full history in one file for the mart's per-wallet running sums.
-- sgn has no ELSE: C5 guarantees BUY/SELL, and anything else would surface as NULL.
CREATE OR REPLACE TEMP MACRO wallet_markets(k) AS TABLE
WITH legs AS (
    SELECT market_id, ts_unix, nonusdc_side, raw_price, token_amount, usd_amount,
           maker AS wallet, maker_direction AS direction, true AS is_maker
    FROM fills_in
    UNION ALL
    SELECT market_id, ts_unix, nonusdc_side, raw_price, token_amount, usd_amount,
           taker, taker_direction, false
    FROM fills_in
),
signed AS (
    SELECT
        l.*,
        CASE l.direction WHEN 'BUY' THEN 1 WHEN 'SELL' THEN -1 END     AS sgn
    FROM legs l
)
SELECT
    w.wallet_id,
    s.market_id,
    count(*)                                                            AS n_legs,
    count(*) FILTER (WHERE s.is_maker)                                  AS n_maker_legs,
    sum(s.usd_amount)                                                   AS usd_traded,
    coalesce(sum(s.sgn * s.token_amount) FILTER (WHERE s.nonusdc_side = 'token1'), 0)
                                                                        AS net_tokens1,
    coalesce(sum(s.sgn * s.token_amount) FILTER (WHERE s.nonusdc_side = 'token2'), 0)
                                                                        AS net_tokens2,
    sum(s.sgn * s.token_amount * s.raw_price)                           AS net_cost
FROM signed s
JOIN wallets w
  ON w.wallet = s.wallet
 AND w.wallet_id % 16 = k
JOIN resolved r
  ON r.market_id = s.market_id
 AND s.ts_unix < r.close_unix
GROUP BY w.wallet_id, s.market_id;


-- Q4.1 Write partitions 0-15 (zero-padded so the file glob sorts).
COPY (SELECT * FROM wallet_markets(0)) TO (getvariable('wm_prefix') || '00.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(1)) TO (getvariable('wm_prefix') || '01.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(2)) TO (getvariable('wm_prefix') || '02.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(3)) TO (getvariable('wm_prefix') || '03.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(4)) TO (getvariable('wm_prefix') || '04.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(5)) TO (getvariable('wm_prefix') || '05.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(6)) TO (getvariable('wm_prefix') || '06.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(7)) TO (getvariable('wm_prefix') || '07.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(8)) TO (getvariable('wm_prefix') || '08.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(9)) TO (getvariable('wm_prefix') || '09.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(10)) TO (getvariable('wm_prefix') || '10.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(11)) TO (getvariable('wm_prefix') || '11.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(12)) TO (getvariable('wm_prefix') || '12.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(13)) TO (getvariable('wm_prefix') || '13.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(14)) TO (getvariable('wm_prefix') || '14.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM wallet_markets(15)) TO (getvariable('wm_prefix') || '15.parquet') (FORMAT parquet, COMPRESSION zstd);

CREATE OR REPLACE VIEW wm_out AS
SELECT *
FROM read_parquet(getvariable('wm_prefix') || '*.parquet', filename = true);


-- Q5 Leg accounting: every leg in the file -> self-trade -> unresolved market -> at or after
-- closedTime -> kept. kept_legs must equal the output's sum(n_legs) in Q6.
WITH all_legs AS (
    SELECT 2 * count(*)                                                 AS n_legs,
           2 * count(*) FILTER (WHERE maker = taker)                    AS n_self
    FROM read_parquet(getvariable('trades_in'))
),
by_market AS (
    SELECT
        2 * count(*) FILTER (WHERE r.market_id IS NULL)                 AS n_unresolved,
        2 * count(*) FILTER (WHERE f.ts_unix >= r.close_unix)           AS n_after_close,
        2 * sum(f.usd_amount) FILTER (WHERE f.ts_unix >= r.close_unix)  AS usd_after_close,
        2 * count(*) FILTER (WHERE f.ts_unix < r.close_unix)            AS n_kept
    FROM fills_in f
    LEFT JOIN resolved r USING (market_id)
)
SELECT * FROM all_legs CROSS JOIN by_market;


-- Q6 Output footprint and completeness, plus the wallet dimension and bot cutoff.
WITH wm AS (
    SELECT
        count(*)                                                        AS n_pairs,
        sum(n_legs)                                                     AS n_legs_out,
        count(DISTINCT wallet_id)                                       AS n_wallets_resolved
    FROM wm_out
),
dim AS (
    SELECT
        count(*)                                                        AS n_wallets,
        count(*) FILTER (WHERE is_bot)                                  AS n_bots,
        min(n_fills) FILTER (WHERE is_bot)                              AS bot_min_fills,
        sum(n_fills) FILTER (WHERE is_bot) / sum(n_fills)               AS bot_leg_share
    FROM read_parquet(getvariable('wallets_out'))
),
disk AS (
    SELECT sum(total_compressed_size) / 1e9                             AS gb_on_disk
    FROM parquet_metadata(getvariable('wm_prefix') || '*.parquet')
)
SELECT * FROM wm CROSS JOIN dim CROSS JOIN disk;


-- Q7.1 Partition integrity: every row sits in the file for its wallet_id % 16. With the
-- GROUP BY in Q4 this makes (wallet_id, market_id) unique. Expect 0.
SELECT count(*) AS n_misplaced
FROM wm_out
WHERE wallet_id % 16 <> regexp_extract(filename, '_p(\d+)\.parquet$', 1)::INTEGER;

-- Q7.2 NULL keys or measures, or a pair with no legs. Expect 0.
SELECT count(*) AS n_bad
FROM wm_out
WHERE wallet_id IS NULL OR market_id IS NULL OR n_legs = 0
   OR usd_traded IS NULL OR net_tokens1 IS NULL OR net_tokens2 IS NULL OR net_cost IS NULL;

-- Q7.3 Mixed-case address duplicates (one wallet, two ids). Expect 0.
SELECT count(*) - count(DISTINCT lower(wallet)) AS n_case_dupes
FROM read_parquet(getvariable('wallets_out'));


-- Q8 Outcome-free sizing for RQ3: wallets by distinct resolved markets traded, at data end.
SELECT
    count(*)                                                            AS n_wallets,
    count(*) FILTER (WHERE n_markets >= 20)                             AS n_ge20_markets,
    median(n_markets)                                                   AS median_markets,
    quantile_disc(n_markets, 0.99)                                      AS p99_markets
FROM (SELECT wallet_id, count(*) AS n_markets FROM wm_out GROUP BY wallet_id);
