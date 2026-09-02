-- ============================================================================
-- 02 — Which referral relationships actually carry the business?
--
-- Business question
--   The company nurtures ~40 referral relationships across 18 verticals.
--   Marketing spend and relationship time are finite. Which sources produce
--   revenue, which produce noise, and how concentrated is the risk if a top
--   referrer walks?
--
-- Technique
--   Aggregation to source grain, then a running total window function to build
--   a Pareto curve — the cumulative share column is what turns a leaderboard
--   into a concentration-risk answer.
-- ============================================================================

SET search_path TO restoration, public;

WITH source_perf AS (
    SELECT
        rs.source_id,
        rs.source_name,
        rv.vertical_name,
        rv.vertical_group,
        COUNT(l.lead_id)                                        AS leads,
        COUNT(*) FILTER (WHERE l.status = 'Won')                AS jobs_won,
        ROUND(100.0 * COUNT(*) FILTER (WHERE l.status = 'Won')
              / NULLIF(COUNT(*) FILTER (WHERE l.status IN ('Won','Lost','Dead')), 0), 1)
                                                                AS close_rate_pct,
        COALESCE(SUM(f.total_contract_value), 0)                AS revenue,
        COALESCE(SUM(f.gross_profit), 0)                        AS gross_profit,
        ROUND(AVG(f.total_contract_value), 0)                   AS avg_job_size
    FROM referral_sources  rs
    JOIN referral_verticals rv ON rv.vertical_id = rs.vertical_id
    LEFT JOIN leads l            ON l.source_id = rs.source_id
    LEFT JOIN jobs  j            ON j.lead_id   = l.lead_id
    LEFT JOIN v_job_financials f ON f.job_id    = j.job_id
    GROUP BY rs.source_id, rs.source_name, rv.vertical_name, rv.vertical_group
),
ranked AS (
    SELECT
        *,
        SUM(revenue) OVER ()                                    AS total_revenue,
        SUM(revenue) OVER (ORDER BY revenue DESC,
                                    source_id)                  AS running_revenue,
        ROW_NUMBER() OVER (ORDER BY revenue DESC, source_id)     AS revenue_rank,
        RANK() OVER (PARTITION BY vertical_group
                     ORDER BY revenue DESC)                     AS rank_in_group
    FROM source_perf
)
SELECT
    revenue_rank,
    source_name,
    vertical_name,
    vertical_group,
    leads,
    jobs_won,
    close_rate_pct,
    revenue::numeric(12,2),
    gross_profit::numeric(12,2),
    ROUND(100.0 * gross_profit / NULLIF(revenue, 0), 1)         AS margin_pct,
    avg_job_size,
    ROUND(100.0 * revenue / NULLIF(total_revenue, 0), 1)        AS pct_of_revenue,
    ROUND(100.0 * running_revenue / NULLIF(total_revenue, 0), 1) AS cumulative_pct,
    rank_in_group
FROM ranked
ORDER BY revenue_rank;

-- ---------------------------------------------------------------------------
-- The headline number: how few sources it takes to reach 80% of revenue.
-- ---------------------------------------------------------------------------
WITH source_rev AS (
    SELECT rs.source_id,
           COALESCE(SUM(f.total_contract_value), 0) AS revenue
    FROM referral_sources rs
    LEFT JOIN leads l            ON l.source_id = rs.source_id
    LEFT JOIN jobs  j            ON j.lead_id   = l.lead_id
    LEFT JOIN v_job_financials f ON f.job_id    = j.job_id
    GROUP BY rs.source_id
),
cume AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY revenue DESC) AS n,
        SUM(revenue) OVER (ORDER BY revenue DESC
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
            / NULLIF(SUM(revenue) OVER (), 0)     AS cume_share
    FROM source_rev
)
SELECT
    MIN(n) FILTER (WHERE cume_share >= 0.50) AS sources_for_50pct,
    MIN(n) FILTER (WHERE cume_share >= 0.80) AS sources_for_80pct,
    COUNT(*)                                 AS total_sources
FROM cume;
