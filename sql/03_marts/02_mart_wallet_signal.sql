-- RQ3 mart (Section 4 + D6). Three outputs:
--   mart_wallet_records_pXX: each wallet's running track record, one row per day it changes
--   mart_wallet_cutoffs: per snapshot day, qualifying counts and 0.9-quantile cutoffs
--   mart_smart_signal: one row per 1-day primary snapshot, smart-money signal per variant
-- Variants: main (D6), nofloor (D6.4 sensitivity), nobot (T10 repeat), no_mm / no_tk /
-- no_mx (each bot group removed from population and signal). Roles (D6.8) use main.
-- No outcome column in any output: the signal-vs-outcome model belongs to the notebook.
-- Local Parquet only (08, 09, 01_mart_snapshots, stg_market_resolution).
-- Scope: --set run_day=all (full extract) or any date (the smoke extract).


SET memory_limit = '12GB';

SET max_temp_directory_size = '500MB';

SET preserve_insertion_order = false;

SET TimeZone = 'UTC';


-- Q0 Abort if the scope is unset or malformed.
SELECT error('pass --set run_day=YYYY-MM-DD or --set run_day=all')
WHERE getvariable('run_day') IS NULL
   OR (getvariable('run_day') <> 'all' AND TRY_CAST(getvariable('run_day') AS DATE) IS NULL);


-- Q1 Paths; the smoke run reads and writes *_smoke files only.
SET VARIABLE sfx = CASE getvariable('run_day') WHEN 'all' THEN '' ELSE '_smoke' END;

SET VARIABLE trades_in = 'data/processed/int_wallet_trades' || getvariable('sfx') || '.parquet';

SET VARIABLE wallets_in = 'data/processed/int_wallets' || getvariable('sfx') || '.parquet';

SET VARIABLE wm_prefix = 'data/processed/int_wallet_markets' || getvariable('sfx') || '_p';

SET VARIABLE snaps_in = 'data/processed/mart_snapshots' || getvariable('sfx') || '.parquet';

SET VARIABLE rec_prefix = 'data/processed/mart_wallet_records' || getvariable('sfx') || '_p';

SET VARIABLE cutoffs_out = 'data/processed/mart_wallet_cutoffs' || getvariable('sfx') || '.parquet';

SET VARIABLE signal_out = 'data/processed/mart_smart_signal' || getvariable('sfx') || '.parquet';


-- Q2 Resolved markets with outcome. A market enters a record on the day after its UTC
-- close day, the first 00:00 UTC strictly after closedTime (D6.3).
CREATE OR REPLACE TEMP TABLE resolved AS
SELECT
    market_id,
    closed_time,
    closed_time::DATE + 1                                               AS as_of_from,
    token1_won::INTEGER                                                 AS won
FROM 'data/processed/stg_market_resolution.parquet'
WHERE exclusion_reason IS NULL;


-- Q3 Wallet dimension plus bot groups (D6.9): share of maker legs in resolved markets.
CREATE OR REPLACE TEMP TABLE wallets AS
WITH bot_share AS (
    SELECT wm.wallet_id, sum(wm.n_maker_legs) / sum(wm.n_legs)         AS maker_share
    FROM read_parquet(getvariable('wm_prefix') || '*.parquet') wm
    SEMI JOIN read_parquet(getvariable('wallets_in')) w
      ON w.wallet_id = wm.wallet_id AND w.is_bot
    GROUP BY wm.wallet_id
)
SELECT
    w.wallet_id,
    w.wallet,
    w.is_bot,
    b.maker_share,
    CASE
        WHEN NOT w.is_bot          THEN NULL
        WHEN b.maker_share IS NULL THEN NULL
        WHEN b.maker_share >= 0.8  THEN 'maker'
        WHEN b.maker_share <= 0.2  THEN 'taker'
        ELSE 'mixed'
    END                                                                 AS bot_group
FROM read_parquet(getvariable('wallets_in')) w
LEFT JOIN bot_share b USING (wallet_id);


-- Q4 Track records for one wallet partition. pnl applies the outcome to 09's net
-- positions; steps are summed per wallet and day, then accumulated. as_of_to is the last
-- day a row applies (NULL = still current at data end).
CREATE OR REPLACE TEMP MACRO records(path) AS TABLE
WITH steps AS (
    SELECT
        wm.wallet_id,
        r.as_of_from,
        count(*)                                                        AS d_markets,
        sum(wm.usd_traded)                                              AS d_usd,
        sum(wm.net_tokens1 * r.won + wm.net_tokens2 * (1 - r.won) - wm.net_cost)
                                                                        AS d_pnl
    FROM read_parquet(path) wm
    JOIN resolved r USING (market_id)
    GROUP BY wm.wallet_id, r.as_of_from
),
running AS (
    SELECT
        wallet_id,
        as_of_from,
        lead(as_of_from) OVER (PARTITION BY wallet_id ORDER BY as_of_from) - 1
                                                                        AS as_of_to,
        d_markets,
        sum(d_markets) OVER w                                           AS n_markets,
        sum(d_usd) OVER w                                               AS usd,
        sum(d_pnl) OVER w                                               AS pnl
    FROM steps
    WINDOW w AS (PARTITION BY wallet_id ORDER BY as_of_from ROWS UNBOUNDED PRECEDING)
)
SELECT *, pnl / nullif(usd, 0)                                          AS record
FROM running;


-- Q4.1 Write partitions 0-15, aligned with 09's wallet_id % 16 files.
COPY (SELECT * FROM records(getvariable('wm_prefix') || '00.parquet')) TO (getvariable('rec_prefix') || '00.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '01.parquet')) TO (getvariable('rec_prefix') || '01.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '02.parquet')) TO (getvariable('rec_prefix') || '02.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '03.parquet')) TO (getvariable('rec_prefix') || '03.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '04.parquet')) TO (getvariable('rec_prefix') || '04.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '05.parquet')) TO (getvariable('rec_prefix') || '05.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '06.parquet')) TO (getvariable('rec_prefix') || '06.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '07.parquet')) TO (getvariable('rec_prefix') || '07.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '08.parquet')) TO (getvariable('rec_prefix') || '08.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '09.parquet')) TO (getvariable('rec_prefix') || '09.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '10.parquet')) TO (getvariable('rec_prefix') || '10.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '11.parquet')) TO (getvariable('rec_prefix') || '11.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '12.parquet')) TO (getvariable('rec_prefix') || '12.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '13.parquet')) TO (getvariable('rec_prefix') || '13.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '14.parquet')) TO (getvariable('rec_prefix') || '14.parquet') (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM records(getvariable('wm_prefix') || '15.parquet')) TO (getvariable('rec_prefix') || '15.parquet') (FORMAT parquet, COMPRESSION zstd);

CREATE OR REPLACE VIEW recs AS
SELECT *
FROM read_parquet(getvariable('rec_prefix') || '*.parquet');


-- Q5 1-day primary snapshots (Section 3; D6.7) and their UTC days. day_idx batches Q6.
CREATE OR REPLACE TEMP TABLE snaps AS
SELECT
    row_number() OVER (ORDER BY market_id)::UINTEGER                    AS snap_idx,
    market_id,
    epoch(snap_time)::UBIGINT                                           AS snap_ts,
    snap_block_number,
    snap_log_index,
    snap_time::DATE                                                     AS snap_day
FROM read_parquet(getvariable('snaps_in'))
WHERE horizon = '1d' AND within_cap AND volume_usd >= 1000;

CREATE OR REPLACE TEMP TABLE days AS
SELECT snap_day, row_number() OVER (ORDER BY snap_day) AS day_idx
FROM (SELECT DISTINCT snap_day FROM snaps);


-- Q6 Cutoffs for days with day_idx % 8 = k: every record row valid on the day, for wallets
-- with >= 20 markets, active or not (D6.5). Batched by day because a quantile needs a
-- day's whole population at once; about 300M wallet-days do not fit in one pass.
CREATE OR REPLACE TEMP MACRO cutoffs(k) AS TABLE
WITH panel AS (
    SELECT d.snap_day, r.record, w.is_bot, w.bot_group,
           r.usd >= 1000                                                AS floor_ok
    FROM recs r
    JOIN days d
      ON d.snap_day >= r.as_of_from
     AND d.snap_day <= coalesce(r.as_of_to, DATE '9999-12-31')
    JOIN wallets w USING (wallet_id)
    WHERE r.n_markets >= 20
      AND d.day_idx % 8 = k
)
SELECT
    snap_day,
    count(*) FILTER (WHERE floor_ok)                                    AS n_q_main,
    quantile_disc(record, 0.9) FILTER (WHERE floor_ok)                  AS cut_main,
    count(*)                                                            AS n_q_nofloor,
    quantile_disc(record, 0.9)                                          AS cut_nofloor,
    count(*) FILTER (WHERE floor_ok AND NOT is_bot)                     AS n_q_nobot,
    quantile_disc(record, 0.9) FILTER (WHERE floor_ok AND NOT is_bot)   AS cut_nobot,
    count(*) FILTER (WHERE floor_ok AND bot_group IS DISTINCT FROM 'maker')
                                                                        AS n_q_no_mm,
    quantile_disc(record, 0.9) FILTER (WHERE floor_ok AND bot_group IS DISTINCT FROM 'maker')
                                                                        AS cut_no_mm,
    count(*) FILTER (WHERE floor_ok AND bot_group IS DISTINCT FROM 'taker')
                                                                        AS n_q_no_tk,
    quantile_disc(record, 0.9) FILTER (WHERE floor_ok AND bot_group IS DISTINCT FROM 'taker')
                                                                        AS cut_no_tk,
    count(*) FILTER (WHERE floor_ok AND bot_group IS DISTINCT FROM 'mixed')
                                                                        AS n_q_no_mx,
    quantile_disc(record, 0.9) FILTER (WHERE floor_ok AND bot_group IS DISTINCT FROM 'mixed')
                                                                        AS cut_no_mx
FROM panel
GROUP BY snap_day;

CREATE OR REPLACE TEMP TABLE cuts AS SELECT * FROM cutoffs(0);

INSERT INTO cuts SELECT * FROM cutoffs(1);

INSERT INTO cuts SELECT * FROM cutoffs(2);

INSERT INTO cuts SELECT * FROM cutoffs(3);

INSERT INTO cuts SELECT * FROM cutoffs(4);

INSERT INTO cuts SELECT * FROM cutoffs(5);

INSERT INTO cuts SELECT * FROM cutoffs(6);

INSERT INTO cuts SELECT * FROM cutoffs(7);


-- Q6.1 Write cutoffs. A snapshot day with no qualifying wallet keeps a row with NULL
-- counts and cutoffs, so it has no smart wallets (D6.5).
COPY (
    SELECT d.snap_day, c.* EXCLUDE (snap_day)
    FROM days d
    LEFT JOIN cuts c USING (snap_day)
    ORDER BY d.snap_day
) TO (getvariable('cutoffs_out')) (FORMAT parquet, COMPRESSION zstd);

CREATE OR REPLACE TEMP TABLE cuts AS
SELECT * FROM read_parquet(getvariable('cutoffs_out'));


-- Q7 Window fills (D6.6): non-self fills in the market from 7 days before the snapshot
-- trade through the snapshot trade by key. d = +1 buys token1 or sells token2.
-- No ELSE in the sign CASEs: C5 guarantees BUY/SELL, so anything else surfaces as NULL.
CREATE OR REPLACE TEMP TABLE win_fills AS
SELECT
    s.snap_idx,
    s.snap_day,
    mw.wallet_id                                                        AS maker_id,
    tw.wallet_id                                                        AS taker_id,
    (CASE f.maker_direction WHEN 'BUY' THEN 1 WHEN 'SELL' THEN -1 END
     * CASE f.nonusdc_side WHEN 'token1' THEN 1 WHEN 'token2' THEN -1 END)::TINYINT
                                                                        AS maker_d,
    (CASE f.taker_direction WHEN 'BUY' THEN 1 WHEN 'SELL' THEN -1 END
     * CASE f.nonusdc_side WHEN 'token1' THEN 1 WHEN 'token2' THEN -1 END)::TINYINT
                                                                        AS taker_d,
    f.usd_amount                                                        AS usd
FROM read_parquet(getvariable('trades_in')) f
JOIN snaps s
  ON s.market_id = f.market_id
 AND f.ts_unix >= s.snap_ts - 604800
 AND (f.block_number < s.snap_block_number
      OR (f.block_number = s.snap_block_number AND f.log_index <= s.snap_log_index))
JOIN wallets mw ON mw.wallet = f.maker
JOIN wallets tw ON tw.wallet = f.taker
WHERE f.maker <> f.taker;


-- Q8 Signal sums for one wallet partition. Each leg takes its wallet's record as of the
-- snapshot day (ASOF: latest as_of_from <= snap_day), so only markets closed before that
-- day's 00:00 UTC count. Sums are additive across partitions; the ratio is taken in Q9.
CREATE OR REPLACE TEMP MACRO signal_part(k) AS TABLE
WITH legs AS (
    SELECT snap_idx, snap_day, maker_id AS wallet_id, maker_d AS d, usd, true AS is_maker
    FROM win_fills WHERE maker_id % 16 = k
    UNION ALL
    SELECT snap_idx, snap_day, taker_id, taker_d, usd, false
    FROM win_fills WHERE taker_id % 16 = k
),
tagged AS (
    SELECT
        l.snap_idx, l.wallet_id, l.d, l.usd, l.is_maker,
        r.n_markets >= 20 AND r.usd >= 1000                             AS q_main,
        r.n_markets >= 20                                               AS q_nofloor,
        r.record,
        w.is_bot,
        w.bot_group,
        c.cut_main, c.cut_nofloor, c.cut_nobot, c.cut_no_mm, c.cut_no_tk, c.cut_no_mx
    FROM legs l
    ASOF LEFT JOIN (SELECT * FROM recs WHERE wallet_id % 16 = k) r
      ON r.wallet_id = l.wallet_id AND l.snap_day >= r.as_of_from
    JOIN wallets w ON w.wallet_id = l.wallet_id
    JOIN cuts c ON c.snap_day = l.snap_day
),
flagged AS (
    SELECT
        snap_idx, wallet_id, d, usd, is_maker,
        coalesce(q_main AND record >= cut_main, false)                  AS s_main,
        coalesce(q_nofloor AND record >= cut_nofloor, false)            AS s_nofloor,
        coalesce(q_main AND NOT is_bot AND record >= cut_nobot, false)  AS s_nobot,
        coalesce(q_main AND bot_group IS DISTINCT FROM 'maker' AND record >= cut_no_mm, false)
                                                                        AS s_no_mm,
        coalesce(q_main AND bot_group IS DISTINCT FROM 'taker' AND record >= cut_no_tk, false)
                                                                        AS s_no_tk,
        coalesce(q_main AND bot_group IS DISTINCT FROM 'mixed' AND record >= cut_no_mx, false)
                                                                        AS s_no_mx
    FROM tagged
)
SELECT
    snap_idx,
    count(*)                                                            AS n_legs,
    sum(usd)                                                            AS usd_all,
    count(DISTINCT wallet_id) FILTER (WHERE s_main)                     AS n_smart_main,
    sum(d * usd) FILTER (WHERE s_main)                                  AS dv_main,
    sum(usd) FILTER (WHERE s_main)                                      AS v_main,
    sum(d * usd) FILTER (WHERE s_main AND is_maker)                     AS dv_maker,
    sum(usd) FILTER (WHERE s_main AND is_maker)                         AS v_maker,
    sum(d * usd) FILTER (WHERE s_main AND NOT is_maker)                 AS dv_taker,
    sum(usd) FILTER (WHERE s_main AND NOT is_maker)                     AS v_taker,
    sum(d * usd) FILTER (WHERE s_nofloor)                               AS dv_nofloor,
    sum(usd) FILTER (WHERE s_nofloor)                                   AS v_nofloor,
    sum(d * usd) FILTER (WHERE s_nobot)                                 AS dv_nobot,
    sum(usd) FILTER (WHERE s_nobot)                                     AS v_nobot,
    sum(d * usd) FILTER (WHERE s_no_mm)                                 AS dv_no_mm,
    sum(usd) FILTER (WHERE s_no_mm)                                     AS v_no_mm,
    sum(d * usd) FILTER (WHERE s_no_tk)                                 AS dv_no_tk,
    sum(usd) FILTER (WHERE s_no_tk)                                     AS v_no_tk,
    sum(d * usd) FILTER (WHERE s_no_mx)                                 AS dv_no_mx,
    sum(usd) FILTER (WHERE s_no_mx)                                     AS v_no_mx
FROM flagged
GROUP BY snap_idx;

CREATE OR REPLACE TEMP TABLE parts AS SELECT * FROM signal_part(0);

INSERT INTO parts SELECT * FROM signal_part(1);

INSERT INTO parts SELECT * FROM signal_part(2);

INSERT INTO parts SELECT * FROM signal_part(3);

INSERT INTO parts SELECT * FROM signal_part(4);

INSERT INTO parts SELECT * FROM signal_part(5);

INSERT INTO parts SELECT * FROM signal_part(6);

INSERT INTO parts SELECT * FROM signal_part(7);

INSERT INTO parts SELECT * FROM signal_part(8);

INSERT INTO parts SELECT * FROM signal_part(9);

INSERT INTO parts SELECT * FROM signal_part(10);

INSERT INTO parts SELECT * FROM signal_part(11);

INSERT INTO parts SELECT * FROM signal_part(12);

INSERT INTO parts SELECT * FROM signal_part(13);

INSERT INTO parts SELECT * FROM signal_part(14);

INSERT INTO parts SELECT * FROM signal_part(15);


-- Q9 Write the signal mart: signal = sum(d * usd) / sum(usd) over smart legs, 0 when a
-- market has no smart volume (D6.6). smart_usd_* lets the notebook flag those markets.
CREATE OR REPLACE TEMP MACRO sig(dv, v) AS CASE WHEN v > 0 THEN dv / v ELSE 0 END;

COPY (
    WITH t AS (
        SELECT
            snap_idx,
            sum(n_legs) AS n_legs, sum(usd_all) AS usd_all, sum(n_smart_main) AS n_smart_main,
            sum(dv_main) AS dv_main,       sum(v_main) AS v_main,
            sum(dv_maker) AS dv_maker,     sum(v_maker) AS v_maker,
            sum(dv_taker) AS dv_taker,     sum(v_taker) AS v_taker,
            sum(dv_nofloor) AS dv_nofloor, sum(v_nofloor) AS v_nofloor,
            sum(dv_nobot) AS dv_nobot,     sum(v_nobot) AS v_nobot,
            sum(dv_no_mm) AS dv_no_mm,     sum(v_no_mm) AS v_no_mm,
            sum(dv_no_tk) AS dv_no_tk,     sum(v_no_tk) AS v_no_tk,
            sum(dv_no_mx) AS dv_no_mx,     sum(v_no_mx) AS v_no_mx
        FROM parts
        GROUP BY snap_idx
    )
    SELECT
        s.market_id,
        s.snap_day,
        coalesce(t.n_legs, 0)                                           AS n_window_legs,
        coalesce(t.usd_all, 0)                                          AS window_usd,
        coalesce(t.n_smart_main, 0)                                     AS n_smart_wallets,
        sig(t.dv_main, t.v_main)                                        AS signal,
        coalesce(t.v_main, 0)                                           AS smart_usd,
        sig(t.dv_maker, t.v_maker)                                      AS signal_maker,
        coalesce(t.v_maker, 0)                                          AS smart_usd_maker,
        sig(t.dv_taker, t.v_taker)                                      AS signal_taker,
        coalesce(t.v_taker, 0)                                          AS smart_usd_taker,
        sig(t.dv_nofloor, t.v_nofloor)                                  AS signal_nofloor,
        coalesce(t.v_nofloor, 0)                                        AS smart_usd_nofloor,
        sig(t.dv_nobot, t.v_nobot)                                      AS signal_nobot,
        coalesce(t.v_nobot, 0)                                          AS smart_usd_nobot,
        sig(t.dv_no_mm, t.v_no_mm)                                      AS signal_no_mm,
        coalesce(t.v_no_mm, 0)                                          AS smart_usd_no_mm,
        sig(t.dv_no_tk, t.v_no_tk)                                      AS signal_no_tk,
        coalesce(t.v_no_tk, 0)                                          AS smart_usd_no_tk,
        sig(t.dv_no_mx, t.v_no_mx)                                      AS signal_no_mx,
        coalesce(t.v_no_mx, 0)                                          AS smart_usd_no_mx
    FROM snaps s
    LEFT JOIN t USING (snap_idx)
) TO (getvariable('signal_out')) (FORMAT parquet, COMPRESSION zstd);

CREATE OR REPLACE VIEW sig_out AS
SELECT * FROM read_parquet(getvariable('signal_out'));


-- Q10 Sizes and reconciliations. wallet_days_nofloor should match D6.3 (299,834,233),
-- bot groups D6.9 (1,316 / 713 / 1,164), and window legs out = 2 x window fills.
SELECT
    (SELECT count(*) FROM recs)                                         AS n_record_rows,
    (SELECT count(DISTINCT wallet_id) FROM recs)                        AS n_record_wallets,
    (SELECT sum(total_compressed_size) / 1e9
     FROM parquet_metadata(getvariable('rec_prefix') || '*.parquet'))   AS rec_gb,
    (SELECT sum(n_q_nofloor) FROM cuts)                                 AS wallet_days_nofloor,
    (SELECT sum(n_q_main) FROM cuts)                                    AS wallet_days_main,
    (SELECT count(*) FILTER (WHERE bot_group = 'maker') FROM wallets)   AS n_bot_maker,
    (SELECT count(*) FILTER (WHERE bot_group = 'taker') FROM wallets)   AS n_bot_taker,
    (SELECT count(*) FILTER (WHERE bot_group = 'mixed') FROM wallets)   AS n_bot_mixed,
    (SELECT count(*) FILTER (WHERE is_bot AND maker_share IS NULL) FROM wallets)
                                                                        AS n_bot_no_resolved,
    (SELECT 2 * count(*) FROM win_fills)                                AS n_window_legs_in,
    (SELECT sum(n_window_legs) FROM sig_out)                            AS n_window_legs_out;

-- Q10.1 Per-day qualifying population and cutoffs (main and nofloor).
SELECT
    count(*)                                                            AS n_days,
    count(*) FILTER (WHERE coalesce(n_q_main, 0) = 0)                   AS n_days_no_qualifier,
    min(n_q_main) AS min_q_main, median(n_q_main) AS med_q_main, max(n_q_main) AS max_q_main,
    max(n_q_nofloor)                                                    AS max_q_nofloor,
    min(cut_main) AS min_cut_main, median(cut_main) AS med_cut_main, max(cut_main) AS max_cut_main,
    median(cut_nofloor)                                                 AS med_cut_nofloor
FROM cuts;

-- Q10.2 Smart-volume coverage per variant (D6.6 reports markets with signal 0).
SELECT
    count(*)                                                            AS n_markets,
    count(*) FILTER (WHERE smart_usd > 0)                               AS n_smart_main,
    count(*) FILTER (WHERE smart_usd_maker > 0)                         AS n_smart_maker,
    count(*) FILTER (WHERE smart_usd_taker > 0)                         AS n_smart_taker,
    count(*) FILTER (WHERE smart_usd_nofloor > 0)                       AS n_smart_nofloor,
    count(*) FILTER (WHERE smart_usd_nobot > 0)                         AS n_smart_nobot,
    count(*) FILTER (WHERE smart_usd_no_mm > 0)                         AS n_smart_no_mm,
    count(*) FILTER (WHERE smart_usd_no_tk > 0)                         AS n_smart_no_tk,
    count(*) FILTER (WHERE smart_usd_no_mx > 0)                         AS n_smart_no_mx,
    sum(smart_usd) / sum(window_usd)                                    AS smart_usd_share,
    median(n_smart_wallets) FILTER (WHERE smart_usd > 0)                AS med_smart_wallets
FROM sig_out;


-- Q11.1 One row per snapshot, signals in [-1, 1], no NULLs, every leg signed and opposite
-- to its counterparty, every outcome known. Expect all 0.
SELECT
    (SELECT count(*) FROM sig_out) - (SELECT count(*) FROM snaps)       AS n_row_diff,
    (SELECT count(*) - count(DISTINCT market_id) FROM sig_out)          AS n_dupes,
    (SELECT count(*) FROM sig_out
     WHERE greatest(abs(signal), abs(signal_maker), abs(signal_taker), abs(signal_nofloor),
                    abs(signal_nobot), abs(signal_no_mm), abs(signal_no_tk), abs(signal_no_mx))
           > 1 + 1e-9
        OR signal IS NULL OR smart_usd < 0)                             AS n_bad_signal,
    (SELECT count(*) FROM win_fills
     WHERE maker_d IS NULL OR taker_d IS NULL OR maker_d = taker_d)     AS n_bad_dir,
    (SELECT count(*) FROM resolved WHERE won IS NULL)                   AS n_null_outcome;

-- Q11.2 Independent record recompute: 500 random record rows, each checked on its
-- as_of_from day and the day before, straight from 09 with closed_time < day 00:00.
-- This is the leakage test: an off-by-one at the day boundary fails it. Expect 0.
CREATE OR REPLACE TEMP TABLE chk AS
SELECT wallet_id, as_of_from + o AS day
FROM (SELECT wallet_id, as_of_from FROM recs USING SAMPLE reservoir(500 ROWS) REPEATABLE (42))
CROSS JOIN (VALUES (0), (-1)) AS t(o);

-- MATERIALIZED forces the wallet join first; otherwise chk x resolved on the inequality
-- alone is planned first (~2B rows).
WITH pairs AS MATERIALIZED (
    SELECT c.wallet_id, c.day, wm.market_id, wm.usd_traded,
           wm.net_tokens1, wm.net_tokens2, wm.net_cost
    FROM chk c
    JOIN read_parquet(getvariable('wm_prefix') || '*.parquet') wm USING (wallet_id)
),
direct AS (
    SELECT
        p.wallet_id, p.day,
        count(*)                                                        AS n_markets,
        sum(p.usd_traded)                                               AS usd,
        sum(p.net_tokens1 * r.won + p.net_tokens2 * (1 - r.won) - p.net_cost) AS pnl
    FROM pairs p
    JOIN resolved r USING (market_id)
    WHERE r.closed_time < p.day::TIMESTAMPTZ
    GROUP BY p.wallet_id, p.day
),
panel AS (
    SELECT c.wallet_id, c.day, r.n_markets, r.usd, r.pnl
    FROM chk c
    ASOF LEFT JOIN recs r ON r.wallet_id = c.wallet_id AND c.day >= r.as_of_from
)
SELECT
    count(*)                                                            AS n_checked,
    count(*) FILTER (WHERE coalesce(p.n_markets, 0) <> coalesce(d.n_markets, 0)
                        OR abs(coalesce(p.usd, 0) - coalesce(d.usd, 0)) > 1e-6 * (1 + abs(coalesce(d.usd, 0)))
                        OR abs(coalesce(p.pnl, 0) - coalesce(d.pnl, 0)) > 1e-6 * (1 + abs(coalesce(d.usd, 0))))
                                                                        AS n_mismatch
FROM panel p
LEFT JOIN direct d USING (wallet_id, day);

-- Q11.3 Section 4's literal per-trade P&L for 200 random (wallet, market) pairs, from raw
-- fills: tokens x (payout - price) for buys, tokens x (price - payout) for sells, at the
-- traded token's payout. Must equal 09's linear form used above. Expect n_mismatch = 0.
CREATE OR REPLACE TEMP TABLE chk_pairs AS
SELECT wm.wallet_id, w.wallet, wm.market_id, r.won, epoch(r.closed_time) AS close_unix,
       wm.net_tokens1 * r.won + wm.net_tokens2 * (1 - r.won) - wm.net_cost AS pnl_linear,
       wm.usd_traded
FROM (SELECT * FROM read_parquet(getvariable('wm_prefix') || '*.parquet')
      USING SAMPLE reservoir(200 ROWS) REPEATABLE (42)) wm
JOIN resolved r USING (market_id)
JOIN wallets w USING (wallet_id);

WITH fills AS (
    SELECT *
    FROM read_parquet(getvariable('trades_in'))
    WHERE maker <> taker AND market_id IN (SELECT market_id FROM chk_pairs)
),
legs AS (
    SELECT market_id, maker AS wallet, maker_direction AS direction, nonusdc_side,
           raw_price, token_amount, ts_unix
    FROM fills
    UNION ALL
    SELECT market_id, taker, taker_direction, nonusdc_side, raw_price, token_amount, ts_unix
    FROM fills
),
literal AS (
    SELECT
        c.wallet_id, c.market_id,
        sum(CASE l.direction
                WHEN 'BUY'  THEN l.token_amount * (CASE l.nonusdc_side WHEN 'token1' THEN c.won ELSE 1 - c.won END - l.raw_price)
                WHEN 'SELL' THEN l.token_amount * (l.raw_price - CASE l.nonusdc_side WHEN 'token1' THEN c.won ELSE 1 - c.won END)
            END)                                                        AS pnl_literal
    FROM chk_pairs c
    JOIN legs l
      ON l.market_id = c.market_id AND l.wallet = c.wallet AND l.ts_unix < c.close_unix
    GROUP BY c.wallet_id, c.market_id
)
SELECT
    count(*)                                                            AS n_checked,
    count(*) FILTER (WHERE abs(c.pnl_linear - coalesce(l.pnl_literal, 0)) > 1e-6 * (1 + c.usd_traded))
                                                                        AS n_mismatch
FROM chk_pairs c
LEFT JOIN literal l USING (wallet_id, market_id);

-- Q11.4 Independent signal recompute (main) for 100 random markets: record looked up by
-- range (as_of_from <= day <= as_of_to) instead of ASOF, all partitions at once.
-- Expect n_mismatch = 0.
CREATE OR REPLACE TEMP TABLE chk_snaps AS
SELECT snap_idx, market_id FROM snaps USING SAMPLE reservoir(100 ROWS) REPEATABLE (42);

WITH legs AS (
    SELECT snap_idx, snap_day, maker_id AS wallet_id, maker_d AS d, usd FROM win_fills
    WHERE snap_idx IN (SELECT snap_idx FROM chk_snaps)
    UNION ALL
    SELECT snap_idx, snap_day, taker_id, taker_d, usd FROM win_fills
    WHERE snap_idx IN (SELECT snap_idx FROM chk_snaps)
),
smart AS (
    SELECT l.snap_idx, l.d, l.usd
    FROM legs l
    JOIN recs r
      ON r.wallet_id = l.wallet_id
     AND l.snap_day BETWEEN r.as_of_from AND coalesce(r.as_of_to, DATE '9999-12-31')
    JOIN cuts c ON c.snap_day = l.snap_day
    WHERE r.n_markets >= 20 AND r.usd >= 1000 AND r.record >= c.cut_main
),
direct AS (
    SELECT c.market_id,
           coalesce(sum(s.d * s.usd) / nullif(sum(s.usd), 0), 0)       AS signal
    FROM chk_snaps c
    LEFT JOIN smart s USING (snap_idx)
    GROUP BY c.market_id
)
SELECT
    count(*)                                                            AS n_checked,
    count(*) FILTER (WHERE s.smart_usd > 0)                             AS n_with_smart,
    count(*) FILTER (WHERE abs(d.signal - s.signal) > 1e-9)             AS n_mismatch
FROM direct d
JOIN sig_out s USING (market_id);


-- Q11.4.1 Free the window legs and partial sums before the full scans of 09 below.
DROP TABLE win_fills;

DROP TABLE parts;


-- Q11.5 Zero sum: every fill has a buyer and a seller of the same token at one price, so
-- P&L summed over all wallets in a market is 0 up to rounding. Catches a pnl term with
-- the wrong token or sign. In 8 market-hash batches: one GROUP BY over 290M rows by 2.2M
-- string keys overflowed 12 GB plus the spill cap. Expect both maxima ~ 0.
CREATE OR REPLACE TEMP MACRO zero_sum(k) AS TABLE
SELECT
    max(abs(mkt_pnl))                                                   AS max_abs_market_pnl,
    max(abs(mkt_tok1))                                                  AS max_abs_net_tokens1
FROM (
    SELECT wm.market_id,
           sum(wm.net_tokens1 * r.won + wm.net_tokens2 * (1 - r.won) - wm.net_cost) AS mkt_pnl,
           sum(wm.net_tokens1)                                          AS mkt_tok1
    FROM read_parquet(getvariable('wm_prefix') || '*.parquet') wm
    JOIN resolved r USING (market_id)
    WHERE hash(wm.market_id) % 8 = k
    GROUP BY wm.market_id
);

CREATE OR REPLACE TEMP TABLE zs AS SELECT * FROM zero_sum(0);

INSERT INTO zs SELECT * FROM zero_sum(1);

INSERT INTO zs SELECT * FROM zero_sum(2);

INSERT INTO zs SELECT * FROM zero_sum(3);

INSERT INTO zs SELECT * FROM zero_sum(4);

INSERT INTO zs SELECT * FROM zero_sum(5);

INSERT INTO zs SELECT * FROM zero_sum(6);

INSERT INTO zs SELECT * FROM zero_sum(7);

SELECT max(max_abs_market_pnl) AS max_abs_market_pnl, max(max_abs_net_tokens1) AS max_abs_net_tokens1
FROM zs;

-- Q11.6 Independent cutoff recompute (main) for 3 random snapshot days, straight from 09
-- with closed_time < day 00:00: n_q_main and cut_main must match. Expect no mismatch.
CREATE OR REPLACE TEMP TABLE chk_days AS
SELECT snap_day FROM days USING SAMPLE reservoir(3 ROWS) REPEATABLE (42);

WITH per_wallet AS (
    SELECT d.snap_day, wm.wallet_id,
           count(*)                                                     AS n_markets,
           sum(wm.usd_traded)                                           AS usd,
           sum(wm.net_tokens1 * r.won + wm.net_tokens2 * (1 - r.won) - wm.net_cost)
               / nullif(sum(wm.usd_traded), 0)                          AS record
    FROM read_parquet(getvariable('wm_prefix') || '*.parquet') wm
    JOIN resolved r USING (market_id)
    JOIN chk_days d ON r.closed_time < d.snap_day::TIMESTAMPTZ
    GROUP BY d.snap_day, wm.wallet_id
),
direct AS (
    SELECT snap_day, count(*) AS n_q, quantile_disc(record, 0.9) AS cut
    FROM per_wallet
    WHERE n_markets >= 20 AND usd >= 1000
    GROUP BY snap_day
)
SELECT
    c.snap_day::VARCHAR                                                 AS snap_day,
    d.n_q, c.n_q_main, d.cut, c.cut_main,
    d.n_q IS DISTINCT FROM c.n_q_main OR abs(d.cut - c.cut_main) > 1e-9 AS mismatch
FROM chk_days k
JOIN cuts c USING (snap_day)
LEFT JOIN direct d USING (snap_day)
ORDER BY 1;
