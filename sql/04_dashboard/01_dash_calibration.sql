-- Dashboard export: calibration bins per (horizon, format, subject) for the primary
-- population. The notebooks only split crypto vs. non-crypto, so this is the one
-- breakdown the dashboard cannot take from results/. Descriptive only, no test.
-- At most 3 horizons x 2 formats x 5 subjects x 10 bins = 300 rows (27 cells occur).
-- Local Parquet only (03_mart_analysis). Writes a small CSV that is committed, so the
-- hosted app never reads data/processed.


-- Q1 Bin each primary snapshot (ten equal-width bins, D7.4), sum within clusters, then
-- take the bin mean and its cluster-robust (CR1) standard error:
-- se^2 = G/(G-1) * sum_c (S_c - n_c * ybar)^2 / n^2. This is the analytic analogue of
-- the notebooks' cluster bootstrap, so CIs differ slightly from results/rq1_curves.csv.
COPY (
    WITH snaps AS (
        SELECT
            horizon, format, subject, cluster_id,
            snap_price                                  AS p,
            token1_won::INTEGER                         AS y,
            least(floor(snap_price * 10), 9)::INTEGER   AS bin
        FROM 'data/processed/mart_analysis.parquet'
        WHERE is_primary
    ),
    by_cluster AS (
        SELECT horizon, format, subject, bin, cluster_id,
               count(*) AS n_c, sum(y) AS s_c, sum(p) AS p_c
        FROM snaps
        GROUP BY ALL
    ),
    by_bin AS (
        SELECT horizon, format, subject, bin,
               sum(n_c)                 AS n,
               count(*)                 AS clusters,
               sum(p_c) / sum(n_c)      AS mean_price,
               sum(s_c) / sum(n_c)      AS win_rate
        FROM by_cluster
        GROUP BY ALL
    ),
    se AS (
        SELECT b.horizon, b.format, b.subject, b.bin,
               sqrt(sum((c.s_c - c.n_c * b.win_rate) ^ 2)
                    * b.clusters / nullif(b.clusters - 1, 0)) / b.n AS se
        FROM by_bin b
        JOIN by_cluster c USING (horizon, format, subject, bin)
        GROUP BY b.horizon, b.format, b.subject, b.bin, b.n, b.clusters
    )
    SELECT
        b.horizon, b.format, b.subject, b.bin, b.n, b.clusters,
        round(b.mean_price, 6)                              AS mean_price,
        round(b.win_rate, 6)                                AS win_rate,
        -- NULL when clusters = 1 (se IS NULL) or win_rate is 0/1 (degenerate Wald SE = 0).
        -- Avoids DuckDB's NULL-skipping greatest(NULL, 0) / least(NULL, 1) fabricating [0, 1].
        CASE WHEN s.se IS NOT NULL AND b.win_rate > 0 AND b.win_rate < 1
             THEN round(greatest(b.win_rate - 1.96 * s.se, 0), 6)
        END                                                 AS ci_low,
        CASE WHEN s.se IS NOT NULL AND b.win_rate > 0 AND b.win_rate < 1
             THEN round(least(b.win_rate + 1.96 * s.se, 1), 6)
        END                                                 AS ci_high
    FROM by_bin b
    JOIN se s USING (horizon, format, subject, bin)
    ORDER BY b.horizon, b.format, b.subject, b.bin
) TO 'app/data/calibration_by_subject.csv' (HEADER);

CREATE OR REPLACE VIEW dash AS
SELECT * FROM read_csv('app/data/calibration_by_subject.csv');


-- Q2 Completeness: bin counts must add up to the primary population per horizon
-- (1w 78,156 / 1d 351,535 / 1h 371,676).
SELECT
    d.horizon,
    sum(d.n)                    AS binned,
    any_value(f.primary_n)      AS primary_n,
    count(*)                    AS rows
FROM dash d
JOIN (
    SELECT horizon, count(*) AS primary_n
    FROM 'data/processed/mart_analysis.parquet'
    WHERE is_primary
    GROUP BY horizon
) f USING (horizon)
GROUP BY d.horizon
ORDER BY d.horizon;


-- Q3 Agreement with notebook 01: the crypto rows must reproduce results/rq1_curves.csv
-- (same population, same bins) in n, mean price and win rate. Expect 0 mismatches.
SELECT
    count(*)                                                        AS crypto_bins,
    count(*) FILTER (
        WHERE d.n <> r.n
           OR abs(d.mean_price - r.mean_price) > 1e-6
           OR abs(d.win_rate - r.freq) > 1e-6
    )                                                               AS mismatches
FROM dash d
JOIN read_csv('results/rq1_curves.csv') r
  ON r.horizon = d.horizon AND r.format = d.format AND r.bin = d.bin AND r.crypto
WHERE d.subject = 'crypto';
