-- ============================================================================
-- 01 — Does response speed actually change the close rate?
--
-- Business question
--   Sales leadership believes "call them fast" matters but has never
--   quantified it. If the effect is real, response time becomes a managed
--   metric with a target; if it is noise, we stop nagging the team about it.
--
-- Technique
--   Bucketed cohort comparison, window functions for share-of-total, and a
--   revenue-at-risk estimate that translates the rate difference into dollars.
--
-- Caveat that belongs on the dashboard, not buried in a footnote:
--   This is observational. Leads that are easy to reach are also easier to
--   close, so part of this gap is selection, not causation. The honest claim
--   is "response time is strongly associated with conversion", and the
--   experiment that would prove causation is a randomised routing test.
-- ============================================================================

SET search_path TO restoration, public;

WITH decided AS (
    -- Only leads that have reached a terminal state can be scored. Including
    -- in-flight leads would drag every close rate down by an arbitrary amount
    -- that depends on when the query happens to run.
    SELECT *
    FROM v_lead_response
    WHERE status IN ('Won', 'Lost', 'Dead')
),
bucketed AS (
    SELECT
        response_bucket,
        COUNT(*)                                        AS leads,
        COUNT(*) FILTER (WHERE is_won)                  AS won,
        ROUND(100.0 * COUNT(*) FILTER (WHERE is_won) / COUNT(*), 1)
                                                        AS close_rate_pct,
        ROUND(AVG(estimated_value), 0)                  AS avg_lead_value,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY response_hours)::numeric, 1)
                                                        AS median_response_hrs
    FROM decided
    GROUP BY response_bucket
),
benchmark AS (
    -- The fastest bucket is the benchmark every other bucket is measured
    -- against. Pulling it out as a scalar keeps the comparison readable.
    SELECT close_rate_pct AS best_rate
    FROM bucketed
    WHERE response_bucket = '0-1 hr'
)
SELECT
    b.response_bucket,
    b.leads,
    b.won,
    b.close_rate_pct,
    ROUND(100.0 * b.leads / SUM(b.leads) OVER (), 1)    AS pct_of_all_leads,
    b.median_response_hrs,
    b.avg_lead_value,
    ROUND(bm.best_rate - b.close_rate_pct, 1)           AS pts_below_fastest,
    -- Dollars left on the table: leads in this bucket that would have closed
    -- had they converted at the one-hour rate, valued at this bucket's own
    -- average job size.
    ROUND(
        b.leads * (bm.best_rate - b.close_rate_pct) / 100.0 * b.avg_lead_value
    , 0)                                                AS est_revenue_gap
FROM bucketed b
CROSS JOIN benchmark bm
ORDER BY
    CASE b.response_bucket
        WHEN '0-1 hr'          THEN 1
        WHEN '1-4 hr'          THEN 2
        WHEN '4-24 hr'         THEN 3
        WHEN '1-3 days'        THEN 4
        WHEN '3+ days'         THEN 5
        WHEN 'Never contacted' THEN 6
    END;
