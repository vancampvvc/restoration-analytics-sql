-- ============================================================================
-- 05 — Where does margin actually come from, and where does it leak?
--
-- Business question
--   Company-wide gross margin is a single number that hides everything. Cut it
--   by job size band, loss type, and funding source to find the segments that
--   are quietly subsidising the rest.
--
-- Technique
--   Explicit size bands (a CASE ladder rather than WIDTH_BUCKET, because the
--   boundaries are the ones the business already uses for pricing, not evenly
--   spaced), conditional aggregation with FILTER to pivot the cost mix into
--   columns, and GROUPING SETS to return segment detail and subtotals from one
--   pass instead of three UNION'd queries.
-- ============================================================================

SET search_path TO restoration, public;

WITH sized AS (
    SELECT
        f.*,
        l.loss_type,
        l.property_type,
        CASE
            WHEN f.total_contract_value <   10000 THEN '1. Under $10k'
            WHEN f.total_contract_value <   25000 THEN '2. $10k-$25k'
            WHEN f.total_contract_value <   50000 THEN '3. $25k-$50k'
            WHEN f.total_contract_value <  100000 THEN '4. $50k-$100k'
            ELSE                                       '5. $100k+'
        END AS size_band
    FROM v_job_financials f
    JOIN leads l ON l.lead_id = f.lead_id
    WHERE f.total_cost > 0            -- exclude jobs not yet costed
)
SELECT
    COALESCE(size_band, 'ALL SIZES')                          AS size_band,
    COALESCE(loss_type, 'ALL LOSS TYPES')                     AS loss_type,
    COUNT(*)                                                  AS jobs,
    SUM(total_contract_value)::numeric(14,2)                  AS revenue,
    SUM(gross_profit)::numeric(14,2)                          AS gross_profit,
    ROUND(100.0 * SUM(gross_profit) / NULLIF(SUM(total_contract_value), 0), 1)
                                                              AS margin_pct,

    -- Cost mix as a share of revenue. Reading these three columns across a row
    -- is how you tell a subcontractor-heavy segment from a labor-heavy one,
    -- which is a different management problem with a different fix.
    ROUND(100.0 * SUM(labor_cost)         / NULLIF(SUM(total_contract_value), 0), 1)
                                                              AS labor_pct,
    ROUND(100.0 * SUM(material_cost)      / NULLIF(SUM(total_contract_value), 0), 1)
                                                              AS material_pct,
    ROUND(100.0 * SUM(subcontractor_cost) / NULLIF(SUM(total_contract_value), 0), 1)
                                                              AS subcontractor_pct,

    -- Insurance work is priced off a carrier's estimating platform rather than
    -- our own; splitting margin by funding source tests whether that pricing
    -- is keeping up with our costs.
    ROUND(100.0 * SUM(gross_profit) FILTER (WHERE is_insurance)
          / NULLIF(SUM(total_contract_value) FILTER (WHERE is_insurance), 0), 1)
                                                              AS insurance_margin_pct,
    ROUND(100.0 * SUM(gross_profit) FILTER (WHERE NOT is_insurance)
          / NULLIF(SUM(total_contract_value) FILTER (WHERE NOT is_insurance), 0), 1)
                                                              AS retail_margin_pct,

    -- How many jobs in this segment lost money outright.
    COUNT(*) FILTER (WHERE gross_profit < 0)                  AS jobs_underwater
FROM sized
GROUP BY GROUPING SETS (
    (size_band, loss_type),
    (size_band),
    (loss_type),
    ()
)
ORDER BY
    GROUPING(size_band), size_band,
    GROUPING(loss_type), loss_type;
