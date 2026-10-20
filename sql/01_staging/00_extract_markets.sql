-- One-time local extract of the markets columns staging needs.
-- Run once; 01 reads the local copy, so re-runs do not depend on hf:// speed
-- (one earlier remote run of 01 took 36 min; this extract took 22 s).
-- Focused subset (15 of the source columns), git-ignored under data/raw.


-- Q0 Extract needed markets columns to local Parquet.
COPY (
    SELECT
        id, condition_id, event_id,
        question, slug, event_slug, event_title,
        answer1, answer2,
        closed, neg_risk, volume,
        created_at, end_date,
        outcome_prices
    FROM src_markets
) TO 'data/raw/markets_subset.parquet' (FORMAT parquet, COMPRESSION zstd);
