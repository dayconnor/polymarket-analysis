-- Round-1 evaluation of the frozen classifier (31954db) against the author-reviewed labels
-- (479b10f). Metrics and acceptance follow hypotheses.md section 6 and codebook section 4.
-- D5: rows the author changed in review = git diff 7fa6cfb 479b10f -- labels/class_round1.csv
-- (3 rows: 17, 54, 325). Unsure rows are reported separately here, never dropped.


-- Q1 Frame and stratum sizes N_k, rebuilt exactly as in 03_class_validation_sample Q1.
CREATE OR REPLACE TEMP TABLE class_frame_n AS
SELECT c.subject, count(*) AS n_frame
FROM 'data/processed/int_market_class.parquet' c
SEMI JOIN (
    SELECT market_id
    FROM 'data/processed/mart_snapshots.parquet'
    WHERE within_cap AND volume_usd >= 1000
) p ON p.market_id = c.market_id
GROUP BY c.subject;


-- Q2 One row per labeled market: hand label, prediction, firing rules, stratum weight.
CREATE OR REPLACE TEMP TABLE class_eval AS
SELECT
    l.label_id::INTEGER                         AS label_id,
    l.market_id,
    l.question,
    l.label_subject,
    l.label_format,
    l.unsure::INTEGER = 1                       AS unsure,
    l.note,
    c.subject                                   AS pred_subject,
    c.format                                    AS pred_format,
    c.subject_rule,
    c.format_rule,
    n.n_frame
FROM read_csv('labels/class_round1.csv', header = true, all_varchar = true) l
JOIN 'data/processed/int_market_class.parquet' c ON c.market_id = l.market_id
JOIN class_frame_n n ON n.subject = c.subject;


-- Q2.1 400 rows, 80 per stratum, every label filled and in the codebook domain. Expect 0 rows.
SELECT 'total' AS check_name, count(*) AS n
FROM class_eval
HAVING count(*) <> 400
UNION ALL
SELECT 'stratum ' || pred_subject, count(*)
FROM class_eval
GROUP BY pred_subject
HAVING count(*) <> 80
UNION ALL
SELECT 'bad label', count(*)
FROM class_eval
WHERE label_subject NOT IN ('crypto', 'politics', 'sports', 'weather', 'other')
   OR label_format NOT IN ('template', 'event')
   OR label_subject IS NULL OR label_format IS NULL
HAVING count(*) > 0;


-- Q3 Per-stratum rates: p_crypto (share labeled crypto), subject and format accuracy.
SELECT
    pred_subject,
    n_frame                                                 AS n_k,
    count(*)                                                AS n_sample,
    sum((label_subject = 'crypto')::INTEGER)                AS n_label_crypto,
    avg((label_subject = 'crypto')::INTEGER)                AS p_crypto,
    avg((label_subject = pred_subject)::INTEGER)            AS subject_acc,
    avg((label_format = pred_format)::INTEGER)              AS format_acc,
    sum(unsure::INTEGER)                                    AS n_unsure
FROM class_eval
GROUP BY pred_subject, n_frame
ORDER BY pred_subject;


-- Q4 Headline metrics, all 400 rows (the pre-registered test) and the unsure = 0 subset.
-- Recall scales each stratum's labeled-crypto share by N_k, since strata were sampled
-- at 80 each regardless of size; precision needs no weight (one stratum).
WITH strata AS (
    SELECT
        'all rows'                                          AS label_set,
        pred_subject,
        n_frame,
        avg((label_subject = 'crypto')::INTEGER)            AS p_crypto,
        avg((label_subject = pred_subject)::INTEGER)        AS subject_acc,
        avg((label_format = pred_format)::INTEGER)          AS format_acc,
        count(*)                                            AS n
    FROM class_eval
    GROUP BY pred_subject, n_frame
    UNION ALL
    SELECT
        'unsure = 0',
        pred_subject,
        n_frame,
        avg((label_subject = 'crypto')::INTEGER),
        avg((label_subject = pred_subject)::INTEGER),
        avg((label_format = pred_format)::INTEGER),
        count(*)
    FROM class_eval
    WHERE NOT unsure
    GROUP BY pred_subject, n_frame
),
metrics AS (
    SELECT
        label_set,
        sum(n)                                                              AS n_rows,
        max(p_crypto) FILTER (WHERE pred_subject = 'crypto')                AS crypto_precision,
        max(n_frame * p_crypto) FILTER (WHERE pred_subject = 'crypto')
            / sum(n_frame * p_crypto)                                       AS crypto_recall,
        sum(n_frame * format_acc) / sum(n_frame)                            AS format_acc_w,
        sum(n_frame * subject_acc) / sum(n_frame)                           AS subject_acc_w
    FROM strata
    GROUP BY label_set
)
SELECT
    *,
    crypto_precision >= 0.95 AND crypto_recall >= 0.95 AND format_acc_w >= 0.95 AS accept
FROM metrics
ORDER BY label_set;


-- Q5 Subject confusion: predicted stratum x hand label.
PIVOT class_eval
ON label_subject IN ('crypto', 'politics', 'sports', 'weather', 'other')
USING count(*)
GROUP BY pred_subject
ORDER BY pred_subject;


-- Q5.1 Format confusion within each predicted stratum.
SELECT pred_subject, pred_format, label_format, count(*) AS n
FROM class_eval
GROUP BY ALL
ORDER BY pred_subject, pred_format, label_format;


-- Q6 Every disagreement with the rule that fired, for the error analysis.
SELECT
    label_id,
    pred_subject || '/' || pred_format                      AS predicted,
    label_subject || '/' || label_format                    AS labeled,
    subject_rule,
    format_rule,
    unsure,
    question
FROM class_eval
WHERE label_subject <> pred_subject OR label_format <> pred_format
ORDER BY pred_subject, label_id;


-- Q7 Unsure rows: how many, and whether the classifier agreed with the label on them.
SELECT
    unsure,
    count(*)                                                AS n,
    sum((label_subject = pred_subject)::INTEGER)            AS subject_agree,
    sum((label_format = pred_format)::INTEGER)              AS format_agree
FROM class_eval
GROUP BY unsure
ORDER BY unsure;
