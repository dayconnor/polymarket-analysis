-- Sensitivity 5.3 (D7.7): token-weighted VWAP of all trades in [t_h - 5 min, t_h), on the
-- token1 side, for every snapshot row in the volume >= $1,000 population. No outcome.
-- Local Parquet only (08_int_wallet_trades, 01_mart_snapshots, 01_int_price_paths).
-- Scope: --set run_day=all (full extract) or any date (the smoke extract).


SET memory_limit = '12GB';

SET max_temp_directory_size = '500MB';


-- Q0 Abort if the scope is unset or malformed.
SELECT error('pass --set run_day=YYYY-MM-DD or --set run_day=all')
WHERE getvariable('run_day') IS NULL
   OR (getvariable('run_day') <> 'all' AND TRY_CAST(getvariable('run_day') AS DATE) IS NULL);


-- Q1 Paths; the smoke run reads and writes *_smoke files only.
SET VARIABLE sfx = CASE getvariable('run_day') WHEN 'all' THEN '' ELSE '_smoke' END;

SET VARIABLE trades_in = 'data/processed/int_wallet_trades' || getvariable('sfx') || '.parquet';

SET VARIABLE paths_in = 'data/processed/int_price_paths' || getvariable('sfx') || '.parquet';

SET VARIABLE snaps_in = 'data/processed/mart_snapshots' || getvariable('sfx') || '.parquet';

SET VARIABLE vwap_out = 'data/processed/mart_vwap' || getvariable('sfx') || '.parquet';


-- Q2 Windows: one per snapshot row with volume_usd >= 1,000.
CREATE OR REPLACE TEMP TABLE win AS
SELECT market_id, horizon, epoch(t_h)::UBIGINT AS t_h_unix
FROM read_parquet(getvariable('snaps_in'))
WHERE volume_usd >= 1000;


-- Q3 Write the VWAP. token_amount is the traded token's quantity and price is converted to
-- the token1 side, so the weights are shares traded whichever side the fill was on.
COPY (
    SELECT
        w.market_id,
        w.horizon,
        sum(CASE f.nonusdc_side WHEN 'token1' THEN f.raw_price ELSE 1 - f.raw_price END
            * f.token_amount) / sum(f.token_amount)                     AS vwap_price,
        count(*)                                                        AS n_trades,
        sum(f.token_amount)                                             AS tokens
    FROM read_parquet(getvariable('trades_in')) f
    JOIN win w
      ON w.market_id = f.market_id
     AND f.ts_unix >= w.t_h_unix - 300
     AND f.ts_unix < w.t_h_unix
    GROUP BY w.market_id, w.horizon
    HAVING sum(f.token_amount) > 0
) TO (getvariable('vwap_out')) (FORMAT parquet, COMPRESSION zstd);

CREATE OR REPLACE VIEW vwap AS
SELECT * FROM read_parquet(getvariable('vwap_out'));


-- Q4 Coverage per horizon: windows, windows with a VWAP, and median trades per window.
SELECT
    w.horizon,
    count(*)                                                            AS n_windows,
    count(v.market_id)                                                  AS n_with_vwap,
    median(v.n_trades)                                                  AS median_trades
FROM win w
LEFT JOIN vwap v USING (market_id, horizon)
GROUP BY w.horizon
ORDER BY w.horizon;


-- Q5.1 One row per (market, horizon), price in [0, 1]. Expect 0s.
SELECT
    count(*) - count(DISTINCT (market_id, horizon))                     AS n_dupes,
    count(*) FILTER (WHERE vwap_price IS NULL OR vwap_price NOT BETWEEN 0 AND 1)
                                                                        AS n_bad_price
FROM vwap;

-- Q5.2 Trade-set cross-check: the price paths (all trades of resolved markets) must give
-- the same trade count per window as the wallet-trade file. Expect n_mismatch = 0.
WITH pp AS (
    SELECT w.market_id, w.horizon, count(*) AS n_pp
    FROM read_parquet(getvariable('paths_in')) p
    JOIN win w
      ON w.market_id = p.market_id
     AND p.ts_unix >= w.t_h_unix - 300
     AND p.ts_unix < w.t_h_unix
    GROUP BY w.market_id, w.horizon
)
SELECT
    count(*)                                                            AS n_windows_checked,
    count(*) FILTER (WHERE coalesce(v.n_trades, 0) <> coalesce(pp.n_pp, 0)) AS n_mismatch
FROM pp
FULL JOIN vwap v USING (market_id, horizon);
