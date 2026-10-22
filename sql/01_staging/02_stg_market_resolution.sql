-- One row per Gamma-requested market: final binary payout, resolution time, flags.
-- Sources: stg_markets.parquet (01) and the raw Gamma fetch (pipeline/fetch_gamma.py).
-- Gamma is the primary outcome source; the HF payout is the fallback and cross-check.
-- Decides resolution status only. Which side is "the probability", horizons and
-- scope thresholds belong to the pre-registration. Nothing here compares prices
-- with outcomes, and no query reports outcomes by winning side (hard rule 1).


-- Q1 Build resolution table: type Gamma, join to staged markets, classify.
CREATE OR REPLACE TEMP TABLE stg_market_resolution AS
WITH gamma AS (
    -- Every Gamma column was stored as a raw string; all typing happens here.
    -- Gamma arrays are valid JSON, so a direct cast works (unlike HF outcome_prices).
    SELECT
        id                                                  AS market_id,
        TRY_CAST(outcomePrices AS DOUBLE[])                 AS gamma_payout,
        TRY_CAST(closedTime AS TIMESTAMPTZ)                 AS closed_time,
        umaResolutionStatus                                 AS uma_status,
        TRY_CAST(umaResolutionStatuses AS VARCHAR[])        AS uma_history,
        automaticallyResolved = 'true'                      AS is_auto_resolved,
        series_slug,
        sportsMarketType                                    AS sports_market_type,
        TRY_CAST(gameStartTime AS TIMESTAMPTZ)              AS game_start_time,
        found,
        fetched_at
    FROM read_parquet('data/raw/gamma/*.parquet')
),

joined AS (
    -- LEFT JOIN so a market missing from Gamma stays and is counted as not_in_gamma.
    SELECT
        s.market_id, s.condition_id, s.event_id,
        s.question, s.slug, s.event_slug, s.answer1, s.answer2,
        s.is_neg_risk, s.volume_usd, s.created_at, s.end_date,
        s.settlement_shape, s.end_before_created,
        s.payout                                            AS hf_payout,
        g.* EXCLUDE (market_id)
    FROM 'data/processed/stg_markets.parquet' s
    LEFT JOIN gamma g ON g.market_id = s.market_id
    WHERE s.exclusion_reason IS NULL AND s.volume_usd > 0   -- same set as 01 Q5
),

resolved AS (
    SELECT
        *,
        coalesce(list_contains(uma_history, 'disputed'), false)    AS ever_disputed,
        list_sort(gamma_payout) = [0.0, 1.0]                        AS gamma_clean,
        list_sort(hf_payout) = [0.0, 1.0]                           AS hf_clean,
        -- HF leading slot when one side is >= 0.99 (clean or near_settled), else NULL.
        CASE WHEN greatest(hf_payout[1], hf_payout[2]) >= 0.99
             THEN CASE WHEN hf_payout[1] > hf_payout[2] THEN 1 ELSE 2 END
        END                                                         AS hf_lead_slot
    FROM joined
),

final AS (
    SELECT
        *,
        CASE
            WHEN gamma_clean THEN gamma_payout
            WHEN hf_clean    THEN hf_payout
        END                                                 AS final_payout,
        -- Gamma's winning slot differs from HF's leading slot: outcome unknowable,
        -- so excluded, not picked. Slots compared, so near_settled HF rows are checked too.
        coalesce(gamma_clean AND list_position(gamma_payout, 1.0) <> hf_lead_slot, false)
                                                            AS payout_conflict
    FROM resolved
)

SELECT
    *,
    -- Assumes payout slot 1 is token1 (same convention as the trade price rule).
    final_payout[1] = 1                                     AS token1_won,
    -- First failing rule wins: coverage, finality, timing, then payout shape.
    CASE
        WHEN NOT coalesce(found, false)                     THEN 'not_in_gamma'
        WHEN uma_status IS DISTINCT FROM 'resolved'         THEN 'not_finalized'
        WHEN ever_disputed                                  THEN 'disputed'
        WHEN closed_time IS NULL                            THEN 'no_closed_time'
        WHEN closed_time < created_at                       THEN 'closed_before_created'
        WHEN gamma_payout = [0.5, 0.5]                      THEN 'half_payout'
        WHEN payout_conflict                                THEN 'payout_conflict'
        WHEN final_payout IS NULL                           THEN 'no_binary_payout'
        ELSE NULL
    END                                                     AS exclusion_reason
FROM final;


-- Q2 Drop count report: every requested market counted once, under its first failing rule.
SELECT coalesce(exclusion_reason, 'kept') AS reason, count(*) AS n_markets
FROM stg_market_resolution
GROUP BY reason
ORDER BY n_markets DESC;


-- Q2.1 Kept markets by HF settlement shape and payout source (shape, not side).
SELECT
    settlement_shape,
    count(*) FILTER (WHERE gamma_clean)                     AS n_from_gamma,
    count(*) FILTER (WHERE NOT coalesce(gamma_clean, false)) AS n_from_hf,
    count(*) FILTER (WHERE closed_time < end_date)          AS n_closed_early
FROM stg_market_resolution
WHERE exclusion_reason IS NULL
GROUP BY settlement_shape
ORDER BY settlement_shape;


-- Q3 Data-quality assertions. Every column should be 0.
SELECT
    count(*) - count(DISTINCT market_id)                                    AS dup_market_id,
    count(*) - 2223448                                                      AS rows_vs_request_list,
    count(*) FILTER (WHERE exclusion_reason IS NULL AND closed_time IS NULL) AS kept_no_closed_time,
    count(*) FILTER (WHERE exclusion_reason IS NULL AND token1_won IS NULL)  AS kept_no_outcome,
    count(*) FILTER (WHERE exclusion_reason IS NULL AND ever_disputed)       AS kept_disputed
FROM stg_market_resolution;


-- Q4 Hand off to the next layer as Parquet.
COPY stg_market_resolution TO 'data/processed/stg_market_resolution.parquet' (FORMAT parquet, COMPRESSION zstd);
