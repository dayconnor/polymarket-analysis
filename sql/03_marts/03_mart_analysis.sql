-- Analysis frame: one row per (market, horizon) snapshot with class, outcome and, for the
-- 1-day primary rows, the RQ3 signal. The notebooks read only this file.
-- First file to join token1_won to prices: allowed after the pre-registration (bc6dca3)
-- and the Section 7 check (210a837). Prints counts only, never an outcome rate.
-- Keeps every snapshot (no cap, any volume) so sensitivities 5.1, 5.2, 5.4-5.7 filter it.
-- Local Parquet only (01_mart_snapshots, 02_mart_wallet_signal, 02_int_market_class,
-- stg_market_resolution).


SET TimeZone = 'UTC';


-- Q1 Write the frame. is_primary = Section 3 snapshot (within cap) in the Section 2
-- population (volume_usd >= 1,000). early_close feeds sensitivity 5.7.
COPY (
    SELECT
        s.market_id,
        s.horizon,
        s.snap_price,
        s.staleness_s,
        s.within_cap,
        s.within_cap AND s.volume_usd >= 1000                           AS is_primary,
        s.liquidity_usd,
        s.n_trades_before,
        s.volume_usd,
        s.cluster_id,
        s.event_id,
        s.series_slug,
        c.subject,
        c.format,
        c.subject = 'crypto'                                            AS is_crypto,
        r.token1_won,
        s.closed_time,
        year(s.closed_time)                                             AS close_year,
        s.end_date,
        s.closed_time < s.end_date                                      AS early_close,
        g.n_smart_wallets,
        g.signal, g.smart_usd,
        g.signal_maker, g.smart_usd_maker,
        g.signal_taker, g.smart_usd_taker,
        g.signal_nofloor, g.smart_usd_nofloor,
        g.signal_nobot, g.smart_usd_nobot,
        g.signal_no_mm, g.smart_usd_no_mm,
        g.signal_no_tk, g.smart_usd_no_tk,
        g.signal_no_mx, g.smart_usd_no_mx
    FROM 'data/processed/mart_snapshots.parquet' s
    JOIN 'data/processed/int_market_class.parquet' c USING (market_id)
    JOIN 'data/processed/stg_market_resolution.parquet' r USING (market_id)
    LEFT JOIN 'data/processed/mart_smart_signal.parquet' g
      ON g.market_id = s.market_id
     AND s.horizon = '1d' AND s.within_cap AND s.volume_usd >= 1000
) TO 'data/processed/mart_analysis.parquet' (FORMAT parquet, COMPRESSION zstd);

CREATE OR REPLACE VIEW frame AS
SELECT * FROM 'data/processed/mart_analysis.parquet';


-- Q2 Completeness: every snapshot kept, one row per (market, horizon), every row classed
-- with a known outcome, the signal on exactly the 1-day primary rows, and NULL
-- end_date counted (early_close is NULL there). Expect 0 except n_null_end_date.
SELECT
    (SELECT count(*) FROM frame)
      - (SELECT count(*) FROM 'data/processed/mart_snapshots.parquet')  AS n_row_diff,
    (SELECT count(*) - count(DISTINCT (market_id, horizon)) FROM frame) AS n_dupes,
    count(*) FILTER (WHERE subject IS NULL OR format IS NULL)           AS n_unclassed,
    count(*) FILTER (WHERE token1_won IS NULL)                          AS n_null_outcome,
    count(*) FILTER (WHERE (signal IS NOT NULL) <> (horizon = '1d' AND is_primary))
                                                                        AS n_signal_misplaced,
    (SELECT count(*) FROM 'data/processed/mart_smart_signal.parquet')
      - count(*) FILTER (WHERE signal IS NOT NULL)                      AS n_signal_unjoined,
    count(*) FILTER (WHERE end_date IS NULL)                            AS n_null_end_date
FROM frame;

-- Q3 RQ1 cells (Section 4): primary snapshots and clusters per horizon x format x crypto.
-- A side with < 30 clusters is descriptive only. Counts only.
SELECT
    horizon, format, is_crypto,
    count(*)                                                            AS n_markets,
    count(DISTINCT cluster_id)                                          AS n_clusters,
    count(DISTINCT event_id)                                            AS n_events
FROM frame
WHERE is_primary
GROUP BY ALL
ORDER BY horizon, format, is_crypto;

-- Q4 Sensitivity populations per horizon: rows each Section 5 filter keeps (5.3 VWAP is
-- built separately). Counts only.
SELECT
    horizon,
    count(*) FILTER (WHERE is_primary)                                  AS n_primary,
    count(*) FILTER (WHERE within_cap)                                  AS n_s1_no_volume_floor,
    count(*) FILTER (WHERE within_cap AND volume_usd >= 10000)          AS n_s2_volume_10k,
    count(*) FILTER (WHERE volume_usd >= 1000)                          AS n_s4_no_cap,
    count(*) FILTER (WHERE is_primary AND NOT coalesce(early_close, false))
                                                                        AS n_s7_no_early_close,
    count(*) FILTER (WHERE is_primary AND close_year = 2026)            AS n_s6_2026,
    count(*) FILTER (WHERE is_primary AND close_year < 2026)            AS n_s6_pre2026
FROM frame
GROUP BY horizon
ORDER BY horizon;
