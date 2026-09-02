-- ============================================================================
-- 04 — Carrier cycle time: who pays, and how long do they make us wait?
--
-- Business question
--   Insurance-funded work is most of the revenue and all of the cash-flow
--   pain. Estimate-to-approval time varies by carrier, and supplements make it
--   worse. Which carriers are structurally slow, and what does that cost us in
--   working capital?
--
-- Technique
--   PERCENTILE_CONT for a median and p90 that a mean would hide (cycle-time
--   distributions have long right tails, so the average is always wrong),
--   FILTER aggregates to split the supplement effect, and a comparison against
--   the carrier's own published-typical benchmark.
-- ============================================================================

SET search_path TO restoration, public;

WITH claim_cycle AS (
    SELECT
        c.claim_id,
        c.carrier_id,
        car.carrier_name,
        car.typical_approval_days,
        c.status,
        c.supplement_count,
        c.rcv_amount,
        c.deductible,
        (c.reported_on - c.date_of_loss)                AS days_loss_to_report,
        (c.estimate_submitted_on - c.reported_on)       AS days_report_to_estimate,
        (c.approved_on - c.estimate_submitted_on)       AS days_estimate_to_approval,
        f.total_contract_value,
        f.outstanding_amount
    FROM insurance_claims c
    JOIN carriers          car ON car.carrier_id = c.carrier_id
    JOIN v_job_financials  f   ON f.job_id       = c.job_id
)
SELECT
    carrier_name,
    COUNT(*)                                                    AS claims,
    SUM(rcv_amount)::numeric(14,2)                              AS total_rcv,
    ROUND(AVG(days_loss_to_report), 1)                          AS avg_days_to_report,

    -- Approval cycle. Median first, because that is the number an operations
    -- manager can plan around; p90 second, because that is the one that
    -- breaks the cash forecast.
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
              ORDER BY days_estimate_to_approval)::numeric, 1)  AS median_approval_days,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (
              ORDER BY days_estimate_to_approval)::numeric, 1)  AS p90_approval_days,
    MAX(days_estimate_to_approval)                              AS worst_approval_days,

    -- Benchmark drift: positive means this carrier is running slower than its
    -- own historical norm.
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
              ORDER BY days_estimate_to_approval)::numeric
          - MAX(typical_approval_days), 1)                           AS vs_benchmark_days,

    -- Supplements are the single biggest driver of a slow file.
    ROUND(AVG(supplement_count), 2)                             AS avg_supplements,
    ROUND(AVG(days_estimate_to_approval)
          FILTER (WHERE supplement_count = 0), 1)               AS approval_days_no_supp,
    ROUND(AVG(days_estimate_to_approval)
          FILTER (WHERE supplement_count >= 2), 1)              AS approval_days_2plus_supp,

    COUNT(*) FILTER (WHERE status = 'Denied')                   AS denied,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'Denied') / COUNT(*), 1)
                                                                AS denial_rate_pct,
    SUM(outstanding_amount)::numeric(14,2)                      AS ar_outstanding
FROM claim_cycle
GROUP BY carrier_name
HAVING COUNT(*) >= 10                -- suppress carriers too thin to rank
ORDER BY median_approval_days DESC NULLS LAST;
