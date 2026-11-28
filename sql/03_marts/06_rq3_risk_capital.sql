-- Exploratory check (Section 8): RQ3 track-record and signal denominator invariance.
-- On Polymarket CTF, buying 1 token1 at p and splitting+selling 1 token2 at 1 - p have
-- identical P&L and capital at risk (p), but CLOB usd_amount records p for the buy and
-- 1 - p for the sell. This script builds risk-capital and share-notional denominators
-- from local int_wallet_trades.parquet and decomposes track-record vs. signal-weight
-- effects across all 351,535 primary 1-day snapshots.
-- Local Parquet only (08, 09, 01_mart_snapshots, 02_mart_wallet_signal, stg_market_resolution).


SET memory_limit = '12GB';

SET max_temp_directory_size = '500MB';

SET preserve_insertion_order = false;

SET TimeZone = 'UTC';


-- Q1 Resolved markets (date entering track record) and wallet ids.
CREATE OR REPLACE TEMP TABLE resolved AS
SELECT
    market_id,
    epoch(closed_time)::UBIGINT                                         AS close_unix,
    closed_time::DATE + 1                                               AS as_of_from
FROM 'data/processed/stg_market_resolution.parquet'
WHERE exclusion_reason IS NULL;

CREATE OR REPLACE TEMP TABLE wallets AS
SELECT wallet_id, wallet
FROM 'data/processed/int_wallets.parquet';


-- Q2 Per-(wallet_id, as_of_from) risk capital, share notional and sell shares, in 4
-- wallet-id slices (~10M groups per slice, well within 12 GB RAM).
-- Economic capital at risk per leg: token_amount * raw_price for BUY,
-- token_amount * (1 - raw_price) for SELL (invariant to buy-YES vs. split+sell-NO).
CREATE OR REPLACE TEMP MACRO rc_steps(k) AS TABLE
WITH legs AS (
    SELECT market_id, ts_unix, raw_price, token_amount,
           maker AS wallet, maker_direction AS direction
    FROM 'data/processed/int_wallet_trades.parquet'
    WHERE maker <> taker
    UNION ALL
    SELECT market_id, ts_unix, raw_price, token_amount,
           taker, taker_direction
    FROM 'data/processed/int_wallet_trades.parquet'
    WHERE maker <> taker
)
SELECT
    w.wallet_id,
    r.as_of_from,
    sum(l.token_amount * CASE l.direction
            WHEN 'BUY'  THEN l.raw_price
            WHEN 'SELL' THEN round(1 - l.raw_price, 6)
        END)                                                            AS d_risk_cap,
    sum(l.token_amount)                                                 AS d_tokens,
    count(*)                                                            AS d_legs,
    count(*) FILTER (WHERE l.direction = 'SELL')                        AS d_sell_legs,
    count(*) FILTER (WHERE l.direction = 'SELL' AND l.raw_price < 0.20) AS d_cheap_sell_legs
FROM legs l
JOIN wallets w
  ON w.wallet = l.wallet
 AND w.wallet_id % 4 = k
JOIN resolved r
  ON r.market_id = l.market_id
 AND l.ts_unix < r.close_unix
GROUP BY w.wallet_id, r.as_of_from;


-- Q2.1 Join onto existing mart_wallet_records and accumulate running totals per slice.
CREATE OR REPLACE TEMP MACRO rc_records(k) AS TABLE
WITH st AS (
    SELECT * FROM rc_steps(k)
),
base AS (
    SELECT
        m.wallet_id,
        m.as_of_from,
        m.as_of_to,
        m.n_markets,
        m.usd,
        m.pnl,
        m.record                                                        AS record_clob,
        st.d_risk_cap,
        st.d_tokens,
        st.d_legs,
        st.d_sell_legs,
        st.d_cheap_sell_legs
    FROM read_parquet('data/processed/mart_wallet_records_p*.parquet') m
    JOIN st USING (wallet_id, as_of_from)
    WHERE m.wallet_id % 4 = k
),
run AS (
    SELECT
        wallet_id,
        as_of_from,
        as_of_to,
        n_markets,
        usd,
        pnl,
        record_clob,
        sum(d_risk_cap) OVER w                                          AS risk_cap,
        sum(d_tokens) OVER w                                            AS tokens,
        sum(d_legs) OVER w                                              AS legs,
        sum(d_sell_legs) OVER w                                         AS sell_legs,
        sum(d_cheap_sell_legs) OVER w                                   AS cheap_sell_legs
    FROM base
    WINDOW w AS (PARTITION BY wallet_id ORDER BY as_of_from ROWS UNBOUNDED PRECEDING)
)
SELECT
    *,
    pnl / nullif(risk_cap, 0)                                           AS record_risk
FROM run;

COPY (SELECT * FROM rc_records(0)) TO 'data/processed/mart_rc_records_p0.parquet' (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM rc_records(1)) TO 'data/processed/mart_rc_records_p1.parquet' (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM rc_records(2)) TO 'data/processed/mart_rc_records_p2.parquet' (FORMAT parquet, COMPRESSION zstd);

COPY (SELECT * FROM rc_records(3)) TO 'data/processed/mart_rc_records_p3.parquet' (FORMAT parquet, COMPRESSION zstd);

CREATE OR REPLACE VIEW rc_recs AS
SELECT * FROM read_parquet('data/processed/mart_rc_records_p*.parquet');


-- Q3 Completeness check: rc_recs must match mart_wallet_records row count exactly. Expect 0.
SELECT
    (SELECT count(*) FROM rc_recs)
      - (SELECT count(*) FROM read_parquet('data/processed/mart_wallet_records_p*.parquet'))
                                                                        AS n_row_diff;


-- Q4 Diagnostic profile at data end (latest row per wallet): compare CLOB-USD top decile
-- vs. other qualifying wallets on sell share, cheap-sell share, USD/risk ratio and overlap
-- with the risk-capital top decile.
COPY (
    WITH latest AS (
        SELECT
            wallet_id, n_markets, usd, risk_cap, pnl, record_clob, record_risk,
            sell_legs::DOUBLE / nullif(legs, 0)                         AS sell_share,
            cheap_sell_legs::DOUBLE / nullif(legs, 0)                   AS cheap_sell_share,
            usd / nullif(risk_cap, 0)                                   AS usd_to_risk
        FROM rc_recs
        WHERE as_of_to IS NULL
    ),
    cuts_end AS (
        SELECT
            quantile_disc(record_clob, 0.9) FILTER (WHERE n_markets >= 20 AND round(usd, 2) >= 1000)
                                                                        AS cut_clob,
            quantile_disc(record_risk, 0.9) FILTER (WHERE n_markets >= 20 AND round(risk_cap, 2) >= 1000)
                                                                        AS cut_risk
        FROM latest
    ),
    tagged AS (
        SELECT
            l.*,
            l.n_markets >= 20 AND round(l.usd, 2) >= 1000               AS qual_clob,
            l.n_markets >= 20 AND round(l.risk_cap, 2) >= 1000          AS qual_risk,
            l.n_markets >= 20 AND round(l.usd, 2) >= 1000
                AND l.record_clob >= c.cut_clob                         AS smart_clob,
            l.n_markets >= 20 AND round(l.risk_cap, 2) >= 1000
                AND l.record_risk >= c.cut_risk                         AS smart_risk
        FROM latest l
        CROSS JOIN cuts_end c
    )
    SELECT
        grp,
        count(*)                                                        AS n_wallets,
        round(median(record_clob), 5)                                   AS med_record_clob,
        round(median(record_risk), 5)                                   AS med_record_risk,
        round(median(usd_to_risk), 4)                                   AS med_usd_to_risk,
        round(avg(sell_share), 4)                                       AS mean_sell_share,
        round(avg(cheap_sell_share), 4)                                 AS mean_cheap_sell_share,
        round(avg(smart_risk::INTEGER), 4)                              AS share_smart_risk,
        round(avg(smart_clob::INTEGER), 4)                              AS share_smart_clob
    FROM (
        SELECT 'CLOB-USD top decile' AS grp, * FROM tagged WHERE smart_clob
        UNION ALL
        SELECT 'CLOB-USD non-smart qualifying', * FROM tagged WHERE qual_clob AND NOT smart_clob
        UNION ALL
        SELECT 'Risk-capital top decile', * FROM tagged WHERE smart_risk
        UNION ALL
        SELECT 'Risk-capital non-smart qualifying', * FROM tagged WHERE qual_risk AND NOT smart_risk
    )
    GROUP BY grp
    ORDER BY grp
) TO 'results/rq3_denominator_profile.csv' (HEADER);

SELECT * FROM read_csv('results/rq3_denominator_profile.csv');


-- Q5 Primary 1-day snapshots and daily cutoffs under both CLOB-USD and Risk-Capital.
CREATE OR REPLACE TEMP TABLE snaps AS
SELECT
    row_number() OVER (ORDER BY market_id)::UINTEGER                    AS snap_idx,
    market_id,
    epoch(snap_time)::UBIGINT                                           AS snap_ts,
    snap_block_number,
    snap_log_index,
    snap_time::DATE                                                     AS snap_day
FROM 'data/processed/mart_snapshots.parquet'
WHERE horizon = '1d'
  AND within_cap
  AND volume_usd >= 1000
  AND snap_block_number IS NOT NULL;

CREATE OR REPLACE TEMP TABLE days AS
SELECT snap_day, row_number() OVER (ORDER BY snap_day) AS day_idx
FROM (SELECT DISTINCT snap_day FROM snaps);

CREATE OR REPLACE TEMP MACRO cutoffs_rc(k) AS TABLE
WITH panel AS (
    SELECT
        d.snap_day,
        r.record_clob,
        r.record_risk,
        round(r.usd, 2) >= 1000                                         AS ok_clob,
        round(r.risk_cap, 2) >= 1000                                    AS ok_risk
    FROM rc_recs r
    JOIN days d
      ON d.snap_day >= r.as_of_from
     AND d.snap_day <= coalesce(r.as_of_to, DATE '9999-12-31')
    WHERE r.n_markets >= 20
      AND d.day_idx % 8 = k
)
SELECT
    snap_day,
    quantile_disc(record_clob, 0.9) FILTER (WHERE ok_clob)              AS cut_clob,
    quantile_disc(record_risk, 0.9) FILTER (WHERE ok_risk)              AS cut_risk
FROM panel
GROUP BY snap_day;

CREATE OR REPLACE TEMP TABLE cuts AS SELECT * FROM cutoffs_rc(0);

INSERT INTO cuts SELECT * FROM cutoffs_rc(1);

INSERT INTO cuts SELECT * FROM cutoffs_rc(2);

INSERT INTO cuts SELECT * FROM cutoffs_rc(3);

INSERT INTO cuts SELECT * FROM cutoffs_rc(4);

INSERT INTO cuts SELECT * FROM cutoffs_rc(5);

INSERT INTO cuts SELECT * FROM cutoffs_rc(6);

INSERT INTO cuts SELECT * FROM cutoffs_rc(7);


-- Q6 Window fills (7 days through snapshot trade) with CLOB USD, risk capital and shares.
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
    f.usd_amount                                                        AS usd,
    f.token_amount                                                      AS tokens,
    f.token_amount * CASE f.maker_direction
        WHEN 'BUY'  THEN f.raw_price
        WHEN 'SELL' THEN round(1 - f.raw_price, 6)
    END                                                                 AS maker_rc,
    f.token_amount * CASE f.taker_direction
        WHEN 'BUY'  THEN f.raw_price
        WHEN 'SELL' THEN round(1 - f.raw_price, 6)
    END                                                                 AS taker_rc
FROM 'data/processed/int_wallet_trades.parquet' f
JOIN snaps s
  ON s.market_id = f.market_id
 AND f.ts_unix >= s.snap_ts - 604800
 AND (f.block_number < s.snap_block_number
      OR (f.block_number = s.snap_block_number AND f.log_index <= s.snap_log_index))
JOIN wallets mw ON mw.wallet = f.maker
JOIN wallets tw ON tw.wallet = f.taker
WHERE f.maker <> f.taker;


-- Q7 Five decomposed signal variants across 4 wallet partitions:
--   clob:         CLOB-USD wallets, CLOB-USD weights (must match mart_smart_signal.signal)
--   clob_w_risk:  CLOB-USD wallets, risk-capital weights
--   risk_w_clob:  risk-capital wallets, CLOB-USD weights
--   risk:         risk-capital wallets, risk-capital weights (fully invariant)
--   shares:       risk-capital wallets, share-notional weights (fully invariant)
CREATE OR REPLACE TEMP MACRO sig_rc_part(k) AS TABLE
WITH legs AS (
    SELECT snap_idx, snap_day, maker_id AS wallet_id, maker_d AS d, usd, maker_rc AS rc, tokens
    FROM win_fills WHERE maker_id % 4 = k
    UNION ALL
    SELECT snap_idx, snap_day, taker_id, taker_d, usd, taker_rc, tokens
    FROM win_fills WHERE taker_id % 4 = k
),
tagged AS (
    SELECT
        l.snap_idx, l.d, l.usd, l.rc, l.tokens,
        coalesce(r.n_markets >= 20 AND round(r.usd, 2) >= 1000 AND r.record_clob >= c.cut_clob, false)
                                                                        AS s_clob,
        coalesce(r.n_markets >= 20 AND round(r.risk_cap, 2) >= 1000 AND r.record_risk >= c.cut_risk, false)
                                                                        AS s_risk
    FROM legs l
    ASOF LEFT JOIN (SELECT * FROM rc_recs WHERE wallet_id % 4 = k) r
      ON r.wallet_id = l.wallet_id AND l.snap_day >= r.as_of_from
    LEFT JOIN cuts c ON c.snap_day = l.snap_day
)
SELECT
    snap_idx,
    sum(d * usd)    FILTER (WHERE s_clob) AS dv_clob,        sum(usd)    FILTER (WHERE s_clob) AS v_clob,
    sum(d * rc)     FILTER (WHERE s_clob) AS dv_clob_w_risk, sum(rc)     FILTER (WHERE s_clob) AS v_clob_w_risk,
    sum(d * usd)    FILTER (WHERE s_risk) AS dv_risk_w_clob, sum(usd)    FILTER (WHERE s_risk) AS v_risk_w_clob,
    sum(d * rc)     FILTER (WHERE s_risk) AS dv_risk,        sum(rc)     FILTER (WHERE s_risk) AS v_risk,
    sum(d * tokens) FILTER (WHERE s_risk) AS dv_shares,      sum(tokens) FILTER (WHERE s_risk) AS v_shares
FROM tagged
GROUP BY snap_idx;

CREATE OR REPLACE TEMP TABLE parts AS SELECT * FROM sig_rc_part(0);

INSERT INTO parts SELECT * FROM sig_rc_part(1);

INSERT INTO parts SELECT * FROM sig_rc_part(2);

INSERT INTO parts SELECT * FROM sig_rc_part(3);


-- Q8 Write mart_rq3_risk_capital.parquet ordered by market_id.
CREATE OR REPLACE TEMP MACRO sig(dv, v) AS CASE WHEN v > 0 THEN dv / v ELSE 0 END;

COPY (
    WITH t AS (
        SELECT
            snap_idx,
            sum(dv_clob) AS dv_clob,               sum(v_clob) AS v_clob,
            sum(dv_clob_w_risk) AS dv_clob_w_risk, sum(v_clob_w_risk) AS v_clob_w_risk,
            sum(dv_risk_w_clob) AS dv_risk_w_clob, sum(v_risk_w_clob) AS v_risk_w_clob,
            sum(dv_risk) AS dv_risk,               sum(v_risk) AS v_risk,
            sum(dv_shares) AS dv_shares,           sum(v_shares) AS v_shares
        FROM parts
        GROUP BY snap_idx
    )
    SELECT
        s.market_id,
        sig(t.dv_clob, t.v_clob)                                        AS signal_clob_chk,
        coalesce(t.v_clob, 0)                                           AS smart_usd_clob,
        sig(t.dv_clob_w_risk, t.v_clob_w_risk)                          AS signal_clob_w_risk,
        sig(t.dv_risk_w_clob, t.v_risk_w_clob)                          AS signal_risk_w_clob,
        sig(t.dv_risk, t.v_risk)                                        AS signal_risk,
        coalesce(t.v_risk, 0)                                           AS smart_risk_cap,
        sig(t.dv_shares, t.v_shares)                                    AS signal_shares,
        coalesce(t.v_shares, 0)                                         AS smart_shares
    FROM snaps s
    LEFT JOIN t USING (snap_idx)
    ORDER BY s.market_id
) TO 'data/processed/mart_rq3_risk_capital.parquet' (FORMAT parquet, COMPRESSION zstd);


-- Q9 Reconciliation against mart_smart_signal.parquet: signal_clob_chk must match signal. Expect 0.
SELECT
    count(*)                                                            AS n_checked,
    count(*) FILTER (WHERE abs(r.signal_clob_chk - m.signal) > 1e-9)    AS n_mismatch,
    max(abs(r.signal_clob_chk - m.signal))                              AS max_abs_diff
FROM 'data/processed/mart_rq3_risk_capital.parquet' r
JOIN 'data/processed/mart_smart_signal.parquet' m USING (market_id)
WHERE m.is_primary;
