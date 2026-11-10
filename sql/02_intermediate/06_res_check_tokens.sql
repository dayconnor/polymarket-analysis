-- Token ids for the Section 7 sample, so the fetcher can test the section 2 assumption
-- that payout slot 1 is token1 (the token behind nonusdc_side = 'token1' trades).
-- Needs 00_sources.sql first. Reads id, token1, token2 for all 4,049,900 markets
-- (id filters do not prune; ~0.3 GB), keeps the 470 sampled.


-- Q1 Sampled markets with their CTF token ids.
COPY (
    SELECT m.id AS market_id, m.condition_id, m.token1, m.token2, m.neg_risk
    FROM src_markets m
    SEMI JOIN read_csv('data/processed/res_check_sample.csv', all_varchar = true) s
        ON s.market_id = m.id
    ORDER BY m.id
) TO 'data/processed/res_check_tokens.csv' (HEADER);


-- Q2 Expect 0 rows: one row per sampled market, decimal token ids, condition ids agree.
SELECT 'rows' AS check_name, count(*) AS n
FROM read_csv('data/processed/res_check_tokens.csv', all_varchar = true)
HAVING count(*) <> 470
UNION ALL
SELECT 'bad token', count(*)
FROM read_csv('data/processed/res_check_tokens.csv', all_varchar = true)
WHERE NOT regexp_full_match(token1, '[0-9]{1,78}') OR NOT regexp_full_match(token2, '[0-9]{1,78}')
HAVING count(*) > 0
UNION ALL
SELECT 'condition mismatch', count(*)
FROM read_csv('data/processed/res_check_tokens.csv', all_varchar = true) t
JOIN read_csv('data/processed/res_check_sample.csv', all_varchar = true) s USING (market_id)
WHERE t.condition_id <> s.condition_id
HAVING count(*) > 0;
