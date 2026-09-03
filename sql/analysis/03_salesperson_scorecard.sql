-- ============================================================================
-- 03 — Salesperson scorecard, normalized against the office
--
-- Business question
--   Raw revenue ranks whoever has been here longest and works the biggest
--   market. A fair scorecard has to compare a rep against their own office's
--   norm and separate "sells a lot" from "sells profitably".
--
-- Technique
--   PARTITION BY window aggregates to compute office-relative deltas without
--   a self-join, NTILE for quartile placement, and a deliberate exclusion of
--   reps below a minimum lead count so a rep with four leads does not top the
--   close-rate column.
-- ============================================================================

SET search_path TO restoration, public;

WITH rep_leads AS (
    SELECT
        sp.salesperson_id,
        sp.full_name,
        sp.office_id,
        o.office_name,
        sp.terminated_on IS NULL                              AS is_active,
        COUNT(l.lead_id)                                      AS leads_assigned,
        COUNT(*) FILTER (WHERE l.status = 'Won')              AS leads_won,
        COUNT(*) FILTER (WHERE l.status IN ('Won','Lost','Dead')) AS leads_decided,
        AVG(EXTRACT(EPOCH FROM (l.first_contact_at - l.received_at)) / 3600.0)
                                                              AS avg_response_hrs
    FROM salespeople sp
    JOIN offices o ON o.office_id = sp.office_id
    LEFT JOIN leads l ON l.salesperson_id = sp.salesperson_id
    GROUP BY sp.salesperson_id, sp.full_name, sp.office_id, o.office_name,
             sp.terminated_on
),
rep_jobs AS (
    SELECT
        f.salesperson_id,
        COUNT(*)                            AS jobs,
        SUM(f.total_contract_value)         AS revenue,
        SUM(f.gross_profit)                 AS gross_profit,
        AVG(f.total_contract_value)         AS avg_job_size,
        SUM(f.outstanding_amount)           AS outstanding
    FROM v_job_financials f
    GROUP BY f.salesperson_id
),
combined AS (
    SELECT
        rl.*,
        COALESCE(rj.jobs, 0)                                   AS jobs,
        COALESCE(rj.revenue, 0)                                AS revenue,
        COALESCE(rj.gross_profit, 0)                           AS gross_profit,
        COALESCE(rj.avg_job_size, 0)                           AS avg_job_size,
        COALESCE(rj.outstanding, 0)                            AS outstanding,
        ROUND(100.0 * rl.leads_won / NULLIF(rl.leads_decided, 0), 1)
                                                               AS close_rate_pct,
        ROUND(100.0 * COALESCE(rj.gross_profit, 0)
              / NULLIF(rj.revenue, 0), 1)                      AS margin_pct
    FROM rep_leads rl
    LEFT JOIN rep_jobs rj ON rj.salesperson_id = rl.salesperson_id
),
scored AS (
    SELECT
        c.*,
        -- Office-relative context: the same window frame gives both the peer
        -- average and the peer count, so a one-rep office reads as such
        -- instead of silently comparing a rep to themselves.
        ROUND(AVG(close_rate_pct) OVER (PARTITION BY office_id), 1)
                                                        AS office_avg_close_rate,
        ROUND(AVG(margin_pct)     OVER (PARTITION BY office_id), 1)
                                                        AS office_avg_margin,
        COUNT(*) OVER (PARTITION BY office_id)          AS reps_in_office,
        NTILE(4) OVER (ORDER BY revenue DESC)           AS revenue_quartile,
        DENSE_RANK() OVER (ORDER BY gross_profit DESC)  AS profit_rank
    FROM combined c
    WHERE leads_decided >= 25          -- minimum sample for a fair rate
)
SELECT
    office_name,
    full_name,
    CASE WHEN is_active THEN 'Active' ELSE 'Departed' END      AS employment,
    leads_assigned,
    jobs,
    close_rate_pct,
    reps_in_office,
    ROUND(close_rate_pct - office_avg_close_rate, 1)           AS vs_office_close,
    revenue::numeric(12,2),
    gross_profit::numeric(12,2),
    margin_pct,
    ROUND(margin_pct - office_avg_margin, 1)                   AS vs_office_margin,
    ROUND(avg_job_size, 0)                                     AS avg_job_size,
    ROUND(avg_response_hrs::numeric, 1)                        AS avg_response_hrs,
    outstanding::numeric(12,2)                                 AS ar_outstanding,
    revenue_quartile,
    profit_rank
FROM scored
ORDER BY office_name, gross_profit DESC;
