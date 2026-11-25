-- One-off regression check for the D9.4 changes to 02_mart_wallet_signal.sql: the 5.1 /
-- 5.4 rows and the cent-rounded USD floor. Run once, after copying the pre-change outputs
-- to mart_smart_signal_v1.parquet and mart_wallet_cutoffs_v1.parquet, running 02 with
-- run_day=all, copying that run's two outputs to *_runA.parquet, and running 02 again.
-- The old float floor let a wallet at exactly $1,000.00 in or out with summation order,
-- so v1 can differ from the fix only through such wallets; Q3 and Q4 attribute each
-- difference. Local Parquet only; no outcome column. Expect every n_unexplained = 0.


-- Q0 Inputs: v1 (before both changes), run A and the current run (after both).
CREATE OR REPLACE VIEW v1_sig AS SELECT * FROM 'data/processed/mart_smart_signal_v1.parquet';

CREATE OR REPLACE VIEW a_sig AS SELECT * FROM 'data/processed/mart_smart_signal_runA.parquet';

CREATE OR REPLACE VIEW new_sig AS SELECT * FROM 'data/processed/mart_smart_signal.parquet';

CREATE OR REPLACE VIEW v1_cut AS SELECT * FROM 'data/processed/mart_wallet_cutoffs_v1.parquet';

CREATE OR REPLACE VIEW a_cut AS SELECT * FROM 'data/processed/mart_wallet_cutoffs_runA.parquet';

CREATE OR REPLACE VIEW new_cut AS SELECT * FROM 'data/processed/mart_wallet_cutoffs.parquet';

-- Floats are sums whose order can change between runs, so equal means within 1e-9
-- relative; NULLs must match exactly.
CREATE OR REPLACE TEMP MACRO differs(a, b) AS
    (a IS NULL) <> (b IS NULL) OR abs(a - b) > 1e-9 * (1 + abs(b));

-- o and n are whole signal rows (table aliases as structs).
CREATE OR REPLACE TEMP MACRO sig_differs(o, n) AS
    o.snap_day <> n.snap_day
    OR o.n_window_legs <> n.n_window_legs
    OR o.n_smart_wallets <> n.n_smart_wallets
    OR differs(n.window_usd, o.window_usd)
    OR differs(n.signal, o.signal)               OR differs(n.smart_usd, o.smart_usd)
    OR differs(n.signal_maker, o.signal_maker)   OR differs(n.smart_usd_maker, o.smart_usd_maker)
    OR differs(n.signal_taker, o.signal_taker)   OR differs(n.smart_usd_taker, o.smart_usd_taker)
    OR differs(n.signal_nofloor, o.signal_nofloor)
    OR differs(n.smart_usd_nofloor, o.smart_usd_nofloor)
    OR differs(n.signal_nobot, o.signal_nobot)   OR differs(n.smart_usd_nobot, o.smart_usd_nobot)
    OR differs(n.signal_no_mm, o.signal_no_mm)   OR differs(n.smart_usd_no_mm, o.smart_usd_no_mm)
    OR differs(n.signal_no_tk, o.signal_no_tk)   OR differs(n.smart_usd_no_tk, o.smart_usd_no_tk)
    OR differs(n.signal_no_mx, o.signal_no_mx)   OR differs(n.smart_usd_no_mx, o.smart_usd_no_mx);

-- Variant columns of the cutoff file, compared as a list per day.
CREATE OR REPLACE TEMP MACRO n_qs(c) AS
    [c.n_q_main, c.n_q_nofloor, c.n_q_nobot, c.n_q_no_mm, c.n_q_no_tk, c.n_q_no_mx];

CREATE OR REPLACE TEMP MACRO cut_differs(o, n) AS
    differs(n.cut_main, o.cut_main)     OR differs(n.cut_nofloor, o.cut_nofloor)
    OR differs(n.cut_nobot, o.cut_nobot) OR differs(n.cut_no_mm, o.cut_no_mm)
    OR differs(n.cut_no_tk, o.cut_no_tk) OR differs(n.cut_no_mx, o.cut_no_mx);


-- Q1 Determinism: run A and the current run agree on every signal row and every day.
-- Expect n_sig_mismatch = n_cut_mismatch = 0 and the row counts equal.
SELECT
    (SELECT count(*) FROM a_sig)                                        AS n_sig_a,
    (SELECT count(*) FROM new_sig)                                      AS n_sig_new,
    (SELECT count(*) FROM a_sig FULL JOIN new_sig n USING (market_id)
     WHERE a_sig.market_id IS NULL OR n.market_id IS NULL
        OR a_sig.is_primary <> n.is_primary OR sig_differs(a_sig, n))   AS n_sig_mismatch,
    (SELECT count(*) FROM a_cut FULL JOIN new_cut n USING (snap_day)
     WHERE a_cut.snap_day IS NULL OR n.snap_day IS NULL
        OR n_qs(a_cut) IS DISTINCT FROM n_qs(n) OR cut_differs(a_cut, n)) AS n_cut_mismatch;


-- Q2 Row sets: the v1 primary markets are exactly the new primary rows; extended rows
-- (5.1 / 5.4 only) are counted. Expect n_missing = n_unexpected_primary = 0.
SELECT
    (SELECT count(*) FROM v1_sig)                                       AS n_v1,
    (SELECT count(*) FROM new_sig WHERE is_primary)                     AS n_new_primary,
    (SELECT count(*) FROM new_sig WHERE NOT is_primary)                 AS n_new_extended,
    (SELECT count(*) FROM v1_sig ANTI JOIN (SELECT * FROM new_sig WHERE is_primary) n
       USING (market_id))                                               AS n_missing,
    (SELECT count(*) FROM (SELECT * FROM new_sig WHERE is_primary) n ANTI JOIN v1_sig
       USING (market_id))                                               AS n_unexpected_primary;


-- Q2.1 Records that sit at exactly $1,000.00 after rounding, the only ones whose floor
-- status the fix can change, with their validity ranges.
CREATE OR REPLACE TEMP TABLE exact_1k AS
SELECT wallet_id, as_of_from, coalesce(as_of_to, DATE '9999-12-31') AS as_of_to
FROM read_parquet('data/processed/mart_wallet_records_p*.parquet')
WHERE n_markets >= 20 AND round(usd, 2) = 1000;

CREATE OR REPLACE TEMP TABLE exact_days AS
SELECT d.snap_day, count(e.wallet_id) AS n_exact
FROM (SELECT snap_day FROM new_cut) d
LEFT JOIN exact_1k e ON d.snap_day BETWEEN e.as_of_from AND e.as_of_to
GROUP BY d.snap_day;


-- Q3 Primary values vs v1. A changed row is explained only if its snapshot day has an
-- exact-$1,000.00 wallet in the record panel. Expect n_unexplained = 0.
SELECT
    count(*)                                                            AS n_compared,
    count(*) FILTER (WHERE sig_differs(o, n))                           AS n_changed,
    count(*) FILTER (WHERE sig_differs(o, n) AND x.n_exact = 0)         AS n_unexplained,
    max(abs(n.signal - o.signal))                                       AS max_abs_signal_diff
FROM v1_sig o
JOIN new_sig n USING (market_id)
JOIN exact_days x ON x.snap_day = n.snap_day;


-- Q4 Cutoffs vs v1 on every v1 day. No-floor counts and cutoffs must match outright; a
-- floored count may only rise, by at most the day's exact-$1,000.00 wallets; a cutoff
-- may move only on a day whose counts moved. Expect n_days_missing = n_unexplained = 0.
SELECT
    (SELECT count(*) FROM v1_cut)                                       AS n_v1_days,
    (SELECT count(*) FROM new_cut)                                      AS n_new_days,
    (SELECT count(*) FROM v1_cut ANTI JOIN new_cut USING (snap_day))    AS n_days_missing,
    count(*) FILTER (WHERE n_qs(o) IS DISTINCT FROM n_qs(n) OR cut_differs(o, n))
                                                                        AS n_changed,
    count(*) FILTER (WHERE o.n_q_nofloor IS DISTINCT FROM n.n_q_nofloor
                        OR differs(n.cut_nofloor, o.cut_nofloor)
                        OR list_min(list_transform(list_zip(n_qs(n), n_qs(o)),
                               p -> coalesce(p[1], 0) - coalesce(p[2], 0))) < 0
                        OR list_max(list_transform(list_zip(n_qs(n), n_qs(o)),
                               p -> coalesce(p[1], 0) - coalesce(p[2], 0))) > x.n_exact
                        OR (n_qs(o) IS NOT DISTINCT FROM n_qs(n) AND cut_differs(o, n)))
                                                                        AS n_unexplained,
    sum(n.n_q_main - o.n_q_main)                                        AS total_gain_main
FROM v1_cut o
JOIN new_cut n USING (snap_day)
JOIN exact_days x USING (snap_day);
