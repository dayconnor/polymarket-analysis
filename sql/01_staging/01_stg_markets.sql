-- One row per market, typed and flagged.
-- Staging FLAGS problems; analysis thresholds (vol, lifetime, category) belong to the pre-reg.
-- Excludes only markets that are structurally unusable. Resolution status
-- (near_settled, half_half, undecided) is decided in 02 against Gamma.
-- Reads the local extract from 00_extract_markets.sql, not hf://.


-- Q1 Build staging table in memory.
CREATE OR REPLACE TEMP TABLE stg_markets AS
WITH base AS (
    SELECT
        id                                      AS market_id,
        condition_id,
        NULLIF(trim(event_id), '')              AS event_id,
        question, slug, event_slug, event_title,
        answer1, answer2,
        closed = 1                              AS is_closed,
        neg_risk = 1                            AS is_neg_risk,
        volume                                  AS volume_usd,
        created_at,
        end_date,
        TRY_CAST(TRY_CAST(replace(outcome_prices, '''', '"') AS JSON) AS DOUBLE[])      AS payout
    FROM 'data/raw/markets_subset.parquet'
),

classified AS (
    SELECT
        *,
        CASE
            WHEN NOT is_closed                              THEN 'open'
            WHEN payout IS NULL OR len(payout) <> 2         THEN 'unparseable'
            WHEN list_sort(payout) = [0.0, 1.0]             THEN 'clean'
            WHEN payout = [0.5, 0.5]                        THEN 'half_half'
            WHEN abs(payout[1] + payout[2] - 1) > 0.01      THEN 'non_unit_sum'
            WHEN greatest(payout[1], payout[2]) >= 0.99     THEN 'near_settled'
            ELSE                                            'undecided'
        END AS settlement_shape,
        -- Mostly in-play sports markets: end_date is the game start, market opened mid-game.
        -- A scope question for the pre-reg, not a data error, so flag only.
        end_date < created_at                       AS end_before_created
    FROM base
)

SELECT
    *,
    CASE
        WHEN settlement_shape IN ('open', 'unparseable', 'non_unit_sum')
                                                            THEN 'shape:' || settlement_shape
        WHEN event_id IS NULL                               THEN 'no_event_id'
        WHEN created_at < TIMESTAMPTZ '2022-11-21'          THEN 'pre_clob'
        ELSE NULL
    END AS exclusion_reason
FROM classified;


-- Q2 Drop count report: every market counted once, under its first failing rule.
SELECT coalesce(exclusion_reason, 'kept') AS reason, count(*) AS n_markets
FROM stg_markets
GROUP BY reason
ORDER BY n_markets DESC;


-- Q2.1 Flag counts among kept markets (not exclusions; carried to 02 and the pre-reg).
SELECT
    settlement_shape,
    count(*)                                            AS n_markets,
    count(*) FILTER (WHERE end_before_created)          AS n_end_before_created,
    count(*) FILTER (WHERE volume_usd > 0)              AS n_with_volume
FROM stg_markets
WHERE exclusion_reason IS NULL
GROUP BY settlement_shape
ORDER BY n_markets DESC;


-- Q3 Data-quality assertions. Every column should be 0.
SELECT
    count(*) - count(DISTINCT market_id)                                        AS dup_market_id,
    count(*) FILTER (WHERE settlement_shape IS NULL)                            AS n_unclassified,
    count(*) FILTER (WHERE exclusion_reason IS NULL AND event_id IS NULL)       AS kept_without_event_id,
    count(*) FILTER (WHERE exclusion_reason IS NULL AND NOT is_closed)          AS kept_open
FROM stg_markets;


-- Q4 Hand off to the next layer as Parquet.
COPY stg_markets TO 'data/processed/stg_markets.parquet' (FORMAT parquet, COMPRESSION zstd);


-- Q5 Ids to request from Gamma: every kept market that traded.
-- Includes near_settled / half_half / undecided, since 02 needs Gamma to decide them.
COPY (
    SELECT market_id
    FROM stg_markets
    WHERE exclusion_reason IS NULL AND volume_usd > 0
    ORDER BY market_id
) TO 'data/processed/gamma_request_ids.csv' (HEADER);
