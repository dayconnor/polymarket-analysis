-- Section 7 resolution check with the D4 cell arm. Compares on-chain CTF payouts and
-- resolution times (pipeline/fetch_onchain_resolution.py) with the staged final payout
-- and Gamma closedTime, and tests the section 2 slot-to-token assumption.
-- Stop rules: random-arm payout agreement < 99%; >= 2 disagreements in any D4 cell.


-- Q1 One on-chain row per market. The fetcher appends on retry, so keep the error-free
-- row, latest first. Payouts normalized to numerator / denominator, as in final_payout.
CREATE OR REPLACE TEMP TABLE chain AS
SELECT
    market_id,
    error,
    state_denominator::HUGEINT                                              AS denom,
    list_transform(state_numerators,
        lambda x: x::DOUBLE / nullif(state_denominator::DOUBLE, 0))         AS chain_payout,
    list_transform(event_numerators,
        lambda x: x::DOUBLE / nullif(state_denominator::DOUBLE, 0))         AS event_payout,
    n_events,
    event_oracle,
    resolution_block,
    resolution_ts_unix
FROM read_json('data/raw/onchain_resolution.jsonl', format = 'newline_delimited',
               sample_size = -1)
QUALIFY row_number() OVER (
    PARTITION BY market_id ORDER BY (error IS NULL) DESC, fetched_at DESC) = 1;


-- Q2 Joined check table: sample arm and cell, staged payout, closedTime gap in seconds.
CREATE OR REPLACE TEMP TABLE res_check AS
SELECT
    s.market_id, s.subject, s.format, s.in_random, s.in_cell,
    r.final_payout,
    c.chain_payout,
    c.event_payout,
    c.denom,
    c.n_events,
    c.event_oracle,
    c.error,
    c.chain_payout = r.final_payout                                         AS payout_agree,
    s.closed_ts_unix - c.resolution_ts_unix::BIGINT                         AS closed_minus_chain_s
FROM read_csv('data/processed/res_check_sample.csv') s
JOIN 'data/processed/stg_market_resolution.parquet' r USING (market_id)
LEFT JOIN chain c USING (market_id);


-- Q3 Fetch integrity. Expect 470 fetched, 0 errors, 0 unresolved, 0 rows without exactly
-- one ConditionResolution event, 0 state/event payout mismatches.
SELECT
    count(*)                                                                AS n_sampled,
    count(*) FILTER (WHERE denom IS NOT NULL AND error IS NULL)             AS n_fetched,
    count(*) FILTER (WHERE error IS NOT NULL OR denom IS NULL)              AS n_error,
    count(*) FILTER (WHERE denom = 0)                                       AS n_unresolved_chain,
    count(*) FILTER (WHERE denom > 0 AND n_events IS DISTINCT FROM 1)       AS n_event_count_off,
    count(*) FILTER (WHERE denom > 0 AND event_payout IS DISTINCT FROM chain_payout)
                                                                            AS n_state_event_diff,
    count(DISTINCT event_oracle)                                            AS n_oracles
FROM res_check;


-- Q4 Primary rule: payout agreement on the 200-market random arm (stop below 99%).
SELECT
    count(*)                                                                AS n,
    sum(payout_agree::INTEGER)                                              AS n_agree,
    avg(payout_agree::INTEGER)                                              AS agreement,
    avg(payout_agree::INTEGER) < 0.99                                       AS stop_analysis
FROM res_check
WHERE in_random;


-- Q5 D4 rule: disagreements per subject x format cell (stop the cell at >= 2), with the
-- closedTime - chain resolution gap per cell.
SELECT
    subject, format,
    count(*)                                                                AS n,
    count(*) FILTER (WHERE NOT payout_agree OR payout_agree IS NULL)        AS n_disagree,
    count(*) FILTER (WHERE NOT payout_agree OR payout_agree IS NULL) >= 2   AS stop_cell,
    median(closed_minus_chain_s)                                            AS gap_p50_s,
    min(closed_minus_chain_s)                                               AS gap_min_s,
    max(closed_minus_chain_s)                                               AS gap_max_s,
    avg((closed_minus_chain_s = 0)::INTEGER)                                AS share_gap_zero
FROM res_check
WHERE in_cell
GROUP BY subject, format
ORDER BY subject, format;


-- Q6 closedTime - chain resolution gap on the random arm: positive means Gamma's
-- closedTime is later than the resolution block.
SELECT
    count(closed_minus_chain_s)                                             AS n,
    avg((closed_minus_chain_s = 0)::INTEGER)                                AS share_zero,
    avg((abs(closed_minus_chain_s) <= 60)::INTEGER)                         AS share_within_60s,
    quantile_cont(closed_minus_chain_s, [0, 0.01, 0.05, 0.5, 0.95, 0.99, 1]) AS gap_quantiles_s
FROM res_check
WHERE in_random;


-- Q7 Slot-to-token mapping (section 2): index set 1 should be token1 and index set 2
-- token2 for every market. Expect n_slot1_token1 = n_slot2_token2 = 470, others 0.
WITH tok AS (
    SELECT *
    FROM read_json('data/raw/onchain_tokens.jsonl', format = 'newline_delimited',
                   sample_size = -1)
)
SELECT
    neg_risk,
    count(*)                                                                AS n,
    count(*) FILTER (WHERE error IS NOT NULL)                               AS n_error,
    count(*) FILTER (WHERE list_contains(list_transform(slot1_matches,
        lambda m: split_part(m, ':', 2)), 'token1'))                        AS n_slot1_token1,
    count(*) FILTER (WHERE list_contains(list_transform(slot2_matches,
        lambda m: split_part(m, ':', 2)), 'token2'))                        AS n_slot2_token2,
    count(*) FILTER (WHERE list_contains(list_transform(slot1_matches,
        lambda m: split_part(m, ':', 2)), 'token2'))                        AS n_reversed,
    count(*) FILTER (WHERE error IS NULL AND len(slot1_matches) = 0)        AS n_no_match
FROM tok
GROUP BY neg_risk
ORDER BY neg_risk;


-- Q8 Every payout disagreement or failed fetch, for diagnosis.
SELECT market_id, subject, format, in_random, in_cell, final_payout, chain_payout,
       denom, n_events, error
FROM res_check
WHERE payout_agree IS NOT TRUE
ORDER BY market_id;
