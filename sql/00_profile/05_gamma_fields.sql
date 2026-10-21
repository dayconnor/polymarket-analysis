-- 05_gamma_fields.sql
-- Format profile of the Gamma fetch (data/raw/gamma, pipeline/fetch_gamma.py)
-- joined to staged markets. Informs the resolution rules in
-- sql/01_staging/02_stg_market_resolution.sql.
-- Format and consistency only: nothing is broken out by winning side and
-- no prices are compared to outcomes (hard rule 1).

SET TimeZone = 'UTC';

CREATE OR REPLACE VIEW gamma AS
SELECT * FROM read_parquet('data/raw/gamma/*.parquet');

CREATE OR REPLACE VIEW stg AS
SELECT * FROM 'data/processed/stg_markets.parquet';


-- Q5.1 Coverage: rows fetched, ids not found, ids that needed closed=false.
SELECT
    count(*)                                        AS n_rows,
    count(DISTINCT id)                              AS n_ids,
    count(*) FILTER (WHERE NOT found)               AS n_not_found,
    count(*) FILTER (WHERE query_closed = 'false')  AS n_via_closed_false,
    min(fetched_at)                                 AS first_fetch,
    max(fetched_at)                                 AS last_fetch
FROM gamma;


-- Q5.2 umaResolutionStatus values, with automaticallyResolved and resolvedBy presence.
SELECT
    umaResolutionStatus,
    automaticallyResolved,
    resolvedBy IS NOT NULL                          AS has_resolved_by,
    count(*)                                        AS n
FROM gamma
WHERE found
GROUP BY ALL
ORDER BY n DESC;


-- Q5.3 umaResolutionStatuses history shapes (proposal/dispute trail).
SELECT umaResolutionStatuses, count(*) AS n
FROM gamma
WHERE found
GROUP BY ALL
ORDER BY n DESC
LIMIT 15;


-- Q5.4 closedTime: nulls and parse rate, by year the market was created.
SELECT
    year(s.created_at)                                                  AS created_year,
    count(*)                                                            AS n,
    count(*) FILTER (WHERE g.closedTime IS NULL)                        AS n_null_closed_time,
    count(*) FILTER (WHERE g.closedTime IS NOT NULL
                       AND TRY_CAST(g.closedTime AS TIMESTAMPTZ) IS NULL) AS n_unparsed
FROM gamma g
JOIN stg s ON s.market_id = g.id
WHERE g.found
GROUP BY ALL
ORDER BY created_year;


-- Q5.5 Resolution status by staged settlement shape (shape, not side).
SELECT
    s.settlement_shape,
    g.umaResolutionStatus,
    count(*)                                        AS n
FROM gamma g
JOIN stg s ON s.market_id = g.id
WHERE g.found
GROUP BY ALL
ORDER BY s.settlement_shape, n DESC;


-- Q5.6 Timing sanity: closedTime relative to created_at and end_date.
SELECT
    count(*)                                                                        AS n,
    count(*) FILTER (WHERE TRY_CAST(g.closedTime AS TIMESTAMPTZ) < s.created_at)    AS closed_before_created,
    count(*) FILTER (WHERE TRY_CAST(g.closedTime AS TIMESTAMPTZ) < s.end_date)      AS closed_before_end_date,
    median(TRY_CAST(g.closedTime AS TIMESTAMPTZ) - s.end_date)                      AS med_closed_minus_end
FROM gamma g
JOIN stg s ON s.market_id = g.id
WHERE g.found;


-- Q5.7 Consistency: does Gamma outcomePrices match the HF payout array?
-- Counts agreement only; which slot is 1 is not reported.
SELECT
    s.settlement_shape,
    count(*)                                                                    AS n,
    count(*) FILTER (WHERE TRY_CAST(g.outcomePrices AS DOUBLE[]) = s.payout)    AS n_identical,
    count(*) FILTER (WHERE TRY_CAST(g.outcomePrices AS DOUBLE[]) IS NULL)       AS n_unparsed
FROM gamma g
JOIN stg s ON s.market_id = g.id
WHERE g.found
GROUP BY ALL
ORDER BY n DESC;
