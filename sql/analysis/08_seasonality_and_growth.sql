-- ============================================================================
-- 08 — Seasonality, growth, and referral source retention
--
-- Business question
--   Restoration demand is weather-driven: freeze events in January and
--   February, hail from May through July. Staffing and equipment decisions are
--   made months ahead, so the planning question is how much of a given month's
--   swing is season and how much is real growth. Separately: are we keeping
--   the referral relationships we win, or replacing churned ones?
--
-- Technique
--   Monthly time series with LAG for year-over-year comparison, a centered
--   moving average to strip the seasonal component, and a cohort retention
--   matrix built from a generated month spine — the LEFT JOIN against a
--   generate_series spine is what stops a zero month from vanishing from the
--   chart instead of showing as zero.
-- ============================================================================

SET search_path TO restoration, public;

-- ---------------------------------------------------------------------------
-- Part 1 — Monthly volume with YoY and a de-seasonalised trend
-- ---------------------------------------------------------------------------
WITH spine AS (
    -- Every month in range, whether or not anything happened in it.
    SELECT generate_series(
        DATE_TRUNC('month', (SELECT MIN(received_at) FROM leads))::date,
        DATE_TRUNC('month', (SELECT MAX(received_at) FROM leads))::date,
        INTERVAL '1 month'
    )::date AS month
),
monthly AS (
    SELECT
        s.month,
        COUNT(l.lead_id)                                        AS leads,
        COUNT(*) FILTER (WHERE l.status = 'Won')                AS won,
        -- Leads still in flight cannot be scored. Dividing wins by ALL leads
        -- received makes the most recent months collapse toward zero purely
        -- because their leads have not been decided yet -- a truncation
        -- artifact that looks exactly like a business problem. Same definition
        -- as query 01.
        COUNT(*) FILTER (WHERE l.status IN ('Won','Lost','Dead')) AS decided,
        COUNT(j.job_id)                                         AS jobs_sold,
        COALESCE(SUM(f.total_contract_value), 0)                AS revenue_sold,
        COUNT(*) FILTER (WHERE l.loss_type = 'Water')           AS water_leads,
        COUNT(*) FILTER (WHERE l.loss_type = 'Storm')           AS storm_leads
    FROM spine s
    LEFT JOIN leads l ON DATE_TRUNC('month', l.received_at)::date = s.month
    LEFT JOIN jobs  j ON j.lead_id = l.lead_id
    LEFT JOIN v_job_financials f ON f.job_id = j.job_id
    GROUP BY s.month
)
SELECT
    month,
    TO_CHAR(month, 'Mon YYYY')                                  AS label,
    leads,
    won,
    decided,
    ROUND(100.0 * won / NULLIF(decided, 0), 1)                  AS close_rate_pct,
    revenue_sold::numeric(14,2),
    water_leads,
    storm_leads,

    -- Year over year. LAG 12 rows back only works because the spine
    -- guarantees twelve rows between the same month in adjacent years.
    LAG(leads, 12) OVER (ORDER BY month)                        AS leads_ly,
    ROUND(100.0 * (leads - LAG(leads, 12) OVER (ORDER BY month))
          / NULLIF(LAG(leads, 12) OVER (ORDER BY month), 0), 1) AS leads_yoy_pct,

    -- Centered 12-month moving average: with a full year inside the window the
    -- seasonal component cancels, so what is left is trend. NULL at the edges
    -- is correct and honest — a partial window would fake a trend line.
    CASE
        WHEN COUNT(*) OVER (ORDER BY month
                            ROWS BETWEEN 6 PRECEDING AND 5 FOLLOWING) = 12
        THEN ROUND(AVG(leads) OVER (ORDER BY month
                                    ROWS BETWEEN 6 PRECEDING AND 5 FOLLOWING), 1)
    END                                                         AS trend_12mo,

    -- Seasonal index: this month against the trend. Above 100 = busy season.
    CASE
        WHEN COUNT(*) OVER (ORDER BY month
                            ROWS BETWEEN 6 PRECEDING AND 5 FOLLOWING) = 12
        THEN ROUND(100.0 * leads
                   / NULLIF(AVG(leads) OVER (ORDER BY month
                                             ROWS BETWEEN 6 PRECEDING AND 5 FOLLOWING), 0), 0)
    END                                                         AS seasonal_index
FROM monthly
ORDER BY month;


-- ---------------------------------------------------------------------------
-- Part 2 — Average seasonal shape, pooled across years
--
-- One year of a seasonal pattern is an anecdote. Pooling by calendar month
-- across all available years is the smallest honest version of the claim.
-- ---------------------------------------------------------------------------
SELECT
    EXTRACT(MONTH FROM received_at)::int                        AS month_num,
    TO_CHAR(received_at, 'Mon')                                 AS month_name,
    COUNT(DISTINCT EXTRACT(YEAR FROM received_at))              AS years_observed,
    COUNT(*)                                                    AS total_leads,
    ROUND(COUNT(*)::numeric
          / COUNT(DISTINCT EXTRACT(YEAR FROM received_at)), 1)  AS avg_leads_per_year,
    ROUND(100.0 * COUNT(*) FILTER (WHERE loss_type = 'Water') / COUNT(*), 1)
                                                                AS pct_water,
    ROUND(100.0 * COUNT(*) FILTER (WHERE loss_type = 'Storm') / COUNT(*), 1)
                                                                AS pct_storm,
    ROUND(
        100.0 * (COUNT(*)::numeric / COUNT(DISTINCT EXTRACT(YEAR FROM received_at)))
        / AVG(COUNT(*)::numeric / COUNT(DISTINCT EXTRACT(YEAR FROM received_at))) OVER ()
    , 0)                                                        AS index_vs_avg_month
FROM leads
GROUP BY 1, 2
ORDER BY month_num;


-- ---------------------------------------------------------------------------
-- Part 3 — Referral source retention by acquisition cohort
--
-- Group sources by the quarter they first sent us a lead, then measure how
-- many were still sending leads in each following quarter. A source that
-- referred once and never again is not a relationship, and counting it as one
-- is how a referral program reports growth while quietly shrinking.
-- ---------------------------------------------------------------------------
WITH source_first AS (
    SELECT
        source_id,
        DATE_TRUNC('quarter', MIN(received_at))::date AS cohort_quarter
    FROM leads
    GROUP BY source_id
),
-- The cohort size must be fixed BEFORE joining to activity. Counting it after
-- the join is the classic cohort bug: the denominator then contains only
-- sources that were active in that quarter, so it always equals the numerator
-- and every cell reads 100%. A retention curve that is flat at 100% is not a
-- good result, it is a broken query.
cohort_size AS (
    SELECT cohort_quarter, COUNT(*) AS sources_in_cohort
    FROM source_first
    GROUP BY cohort_quarter
),
source_activity AS (
    SELECT DISTINCT
        source_id,
        DATE_TRUNC('quarter', received_at)::date AS active_quarter
    FROM leads
),
max_q AS (
    SELECT DATE_TRUNC('quarter', MAX(received_at))::date AS q FROM leads
)
SELECT
    cs.cohort_quarter,
    cs.sources_in_cohort,
    t.quarters_since_first,
    COUNT(DISTINCT sa.source_id)                                AS still_active,
    ROUND(100.0 * COUNT(DISTINCT sa.source_id)
          / cs.sources_in_cohort, 1)                            AS retention_pct
FROM cohort_size cs
-- Only emit quarters the cohort has actually lived through, so an immature
-- cohort shows fewer columns rather than a false zero.
CROSS JOIN LATERAL (
    SELECT generate_series(
        0,
        (EXTRACT(YEAR  FROM AGE((SELECT q FROM max_q), cs.cohort_quarter)) * 4
       + EXTRACT(MONTH FROM AGE((SELECT q FROM max_q), cs.cohort_quarter)) / 3)::int
    ) AS quarters_since_first
) t
LEFT JOIN source_first sf ON sf.cohort_quarter = cs.cohort_quarter
LEFT JOIN source_activity sa
       ON sa.source_id = sf.source_id
      AND sa.active_quarter = cs.cohort_quarter
           + (t.quarters_since_first * INTERVAL '3 months')
GROUP BY cs.cohort_quarter, cs.sources_in_cohort, t.quarters_since_first
ORDER BY cs.cohort_quarter, t.quarters_since_first;
