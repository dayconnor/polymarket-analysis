-- Round-1 validation sample for the frozen classifier (31954db): 80 markets per predicted
-- subject from the primary population at any horizon (codebook section 4).
-- Writes a blind labeling sheet: text fields only, no prediction, price or outcome.
-- md5 ordering instead of random(), so the draw is reproducible across DuckDB versions.


-- Q1 Frame: classified markets with at least one primary snapshot.
CREATE OR REPLACE TEMP TABLE class_frame AS
SELECT c.market_id, c.subject
FROM 'data/processed/int_market_class.parquet' c
SEMI JOIN (
    SELECT market_id
    FROM 'data/processed/mart_snapshots.parquet'
    WHERE within_cap AND volume_usd >= 1000
) p ON p.market_id = c.market_id;


-- Q1.1 Stratum sizes N_k, the weights for recall and format accuracy.
SELECT subject, count(*) AS n_frame
FROM class_frame
GROUP BY subject
ORDER BY subject;


-- Q2 Draw 80 per predicted subject.
CREATE OR REPLACE TEMP TABLE class_sample AS
SELECT market_id, subject
FROM class_frame
QUALIFY row_number() OVER (PARTITION BY subject ORDER BY md5(market_id || ':class-round1')) <= 80;


-- Q3 Blind sheet in shuffled order, so strata cannot be read off the row position.
COPY (
    SELECT
        row_number() OVER (ORDER BY md5(s.market_id || ':class-round1-order'))  AS label_id,
        s.market_id,
        r.question,
        r.slug,
        r.event_slug,
        r.series_slug,
        r.sports_market_type,
        NULL::VARCHAR                                                           AS label_subject,
        NULL::VARCHAR                                                           AS label_format,
        NULL::INTEGER                                                           AS unsure,
        NULL::VARCHAR                                                           AS note
    FROM class_sample s
    JOIN 'data/processed/stg_market_resolution.parquet' r ON r.market_id = s.market_id
    ORDER BY label_id
) TO 'labels/class_round1.csv' (HEADER);


-- Q4 400 distinct markets, 80 per stratum, all with question text. Expect 0 rows.
SELECT subject, count(*) AS n, count(DISTINCT market_id) AS n_distinct
FROM class_sample
GROUP BY subject
HAVING count(*) <> 80 OR count(DISTINCT market_id) <> 80
UNION ALL
SELECT 'sheet', count(*), count(DISTINCT market_id)
FROM read_csv('labels/class_round1.csv')
HAVING count(*) <> 400 OR count(DISTINCT market_id) <> 400 OR count(question) <> 400;
