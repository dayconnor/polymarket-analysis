-- Subject and format for every resolved market (Section 6), from text fields only:
-- question, slug, event_slug, series_slug, sports_market_type. No price or outcome input.
-- Operational definitions: docs/classifier_codebook.md. First matching rule wins, and
-- the rule name is kept so validation errors can be traced to a rule.
-- Frozen at commit, before the validation sample is drawn.


-- Q1 Inputs.
CREATE OR REPLACE TEMP TABLE class_input AS
SELECT
    market_id,
    question,
    series_slug,
    sports_market_type,
    lower(concat_ws(' ', question, slug, event_slug, series_slug))  AS txt,
    lower(question)                                                 AS q
FROM 'data/processed/stg_market_resolution.parquet'
WHERE exclusion_reason IS NULL;


-- Q2 Rule flags, then subject and format.
CREATE OR REPLACE TEMP TABLE int_market_class AS
WITH sports_series AS (
    -- A series is sports if any of its markets carries a sports market type.
    SELECT series_slug
    FROM class_input
    WHERE series_slug IS NOT NULL
    GROUP BY series_slug
    HAVING count(sports_market_type) > 0
),

flags AS (
    SELECT
        i.*,
        regexp_matches(i.txt, '(highest|lowest) temperature|temperature in |\bprecipitation\b|\brainfall\b|\bsnowfall\b|will it (rain|snow)\b|\bhurricane\b|\btornado|named storm|daily-weather|rain-daily')
                                                                    AS f_weather,
        i.sports_market_type IS NOT NULL OR s.series_slug IS NOT NULL
                                                                    AS f_sports_field,
        regexp_matches(i.q, '\b(say|says|said|mention|mentions|mentioned|post|posts|tweet|tweets)\b')
            OR regexp_matches(coalesce(i.series_slug, ''), 'mentions|tweets|posts')
                                                                    AS f_mention,
        -- Exchange-traded tickers: "Apple (AAPL) close above", "Gold (XAUUSD) hit (HIGH)".
        regexp_matches(i.question, '\([A-Z]{2,6}\)')
            AND regexp_extract(i.question, '\(([A-Z]{2,6})\)', 1)
                NOT IN ('BTC', 'ETH', 'SOL', 'XRP', 'DOGE', 'BNB', 'HYPE', 'ZEC', 'HIGH', 'LOW')
            AND regexp_matches(i.q, '\b(close|closes|closed|finish week|up or down|earnings)\b|hit \((high|low)\)')
                                                                    AS f_equity,
        -- Short tickers count only in upper case in the question (slugs abbreviate countries).
        regexp_matches(i.txt, '\b(bitcoin|btc|ethereum|solana|xrp|ripple|dogecoin|bnb|binance|hyperliquid|cardano|zcash|litecoin|chainlink|polkadot|avalanche|shiba|memecoin|memecoins|crypto|cryptocurrency|stablecoin|stablecoins|tether|usdt|usdc|coinbase|microstrategy|opensea|nft|nfts|airdrop|fdv|pump\.fun|blockchain|defi|altcoin|megaeth|monad|kraken|token)\b')
            OR regexp_matches(i.question, '\b(ETH|SOL|HYPE|BTC)\b')
            OR regexp_matches(i.q, 'committed to the .* public sale|launch (a|another) coin|\bsatoshi\b')
                                                                    AS f_crypto,
        regexp_matches(i.txt, '\b(election|elections|elected|electoral|president|presidential|senate|senator|congress|congressional|governor|gubernatorial|mayor|mayoral|prime minister|parliament|parliamentary|referendum|nominee|nomination|primary|cabinet|impeach|impeached|impeachment|supreme court|trump|biden|harris|kamala|vance|obama|putin|zelensky|zelenskyy|netanyahu|khamenei|xi jinping|ceasefire|invade|invasion|sanctions|tariff|tariffs|nato|democrat|democrats|democratic|republican|republicans|gop|approval rating|white house|executive order|government shutdown|chancellor|minister|coalition|doge|epstein|legislation|bill pass)\b')
                                                                    AS f_politics,
        regexp_matches(i.txt, '\b(vs|vs\.|nfl|nba|mlb|nhl|wnba|ncaa|ufc|mma|f1|formula 1|grand prix|premier league|champions league|europa league|la liga|serie a|bundesliga|ligue 1|world cup|fifa|uefa|atp|wta|wimbledon|us open|french open|australian open|roland garros|pga|lpga|golf|tennis|soccer|football|basketball|baseball|hockey|cricket|ipl|rugby|nascar|boxing|olympic|olympics|esports|league of legends|dota|counter-strike|cs2|valorant|pickleball|chess|titled tuesday|super bowl|stanley cup|playoffs|mvp|starting 11|squad|goalscorer|touchdown|home run|grand slam|heisman|ballon d.or|transfer)\b|finish in the top \d+')
                                                                    AS f_sports_text
    FROM class_input i
    LEFT JOIN sports_series s ON s.series_slug = i.series_slug
),

subjects AS (
    SELECT
        *,
        CASE
            -- Sports fields first: team names such as "Golden Hurricane" hit the weather words.
            WHEN f_sports_field                 THEN 'sports:field'
            WHEN f_weather                      THEN 'weather:keyword'
            -- Mention markets are never crypto (Section 3).
            WHEN f_mention AND f_politics       THEN 'politics:mention'
            WHEN f_mention                      THEN 'other:mention'
            WHEN f_equity                       THEN 'other:equity'
            WHEN f_crypto                       THEN 'crypto:keyword'
            WHEN f_politics                     THEN 'politics:keyword'
            WHEN f_sports_text                  THEN 'sports:keyword'
            ELSE                                     'other:default'
        END                                                         AS subject_rule
    FROM flags
)

SELECT
    market_id,
    split_part(subject_rule, ':', 1)                                AS subject,
    split_part(format_rule, ':', 1)                                 AS format,
    subject_rule,
    format_rule
FROM (
    SELECT
        *,
        CASE
            -- Sports games are events by definition (Section 3).
            WHEN subject_rule LIKE 'sports:%'   THEN 'event:sports'
            WHEN regexp_matches(q, '\bup or down\b')
                                                THEN 'template:up_or_down'
            -- Recurring families: cadence or ladder words in the series slug.
            WHEN regexp_matches(coalesce(series_slug, ''), 'up-or-down|multi-strikes|neg-risk|hit-price|daily|weekly|hourly|monthly|-4h|-5m|-15m|brackets|etf-flows|tweets|posts|views-day|box-office|free-app|paid-app|temperature|weather')
                                                THEN 'template:series'
            -- Pre-series ladders: a threshold on a quantity at a stated date.
            WHEN subject_rule NOT LIKE 'politics:%'
             AND regexp_matches(q, '\b(above|below|less than|greater than|between|reach|hit|dip to)\b.*\bon (january|february|march|april|may|june|july|august|september|october|november|december) \d')
                                                THEN 'template:dated_threshold'
            WHEN regexp_matches(q, '(highest|lowest) temperature')
                                                THEN 'template:temperature'
            ELSE                                     'event:default'
        END                                                         AS format_rule
    FROM subjects
);


-- Q3 Rule counts: every resolved market assigned once.
SELECT subject_rule, format_rule, count(*) AS n_markets
FROM int_market_class
GROUP BY ALL
ORDER BY n_markets DESC;


-- Q3.1 Subject x format, all resolved markets and the primary population at any horizon.
SELECT
    c.subject,
    c.format,
    count(*)                                                        AS n_resolved,
    count(*) FILTER (WHERE p.market_id IS NOT NULL)                 AS n_primary_any_horizon
FROM int_market_class c
LEFT JOIN (
    SELECT DISTINCT market_id
    FROM 'data/processed/mart_snapshots.parquet'
    WHERE within_cap AND volume_usd >= 1000
) p ON p.market_id = c.market_id
GROUP BY ALL
ORDER BY c.subject, c.format;


-- Q4 Every resolved market classified exactly once. Expect 0 rows.
SELECT count(*) AS n_rows, count(DISTINCT market_id) AS n_markets
FROM int_market_class
HAVING count(*) <> (SELECT count(*) FROM class_input)
    OR count(*) <> count(DISTINCT market_id)
    OR count(*) FILTER (WHERE subject IS NULL OR format IS NULL) > 0;


-- Q5 Hand off to the next layer as Parquet.
COPY int_market_class TO 'data/processed/int_market_class.parquet' (FORMAT parquet, COMPRESSION zstd);
