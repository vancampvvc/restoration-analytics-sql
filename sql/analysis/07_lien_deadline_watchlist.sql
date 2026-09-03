-- ============================================================================
-- 07 — Mechanic's lien deadline watchlist
--
-- Business question
--   Under Colorado law (C.R.S. 38-22) a contractor's lien statement must be
--   recorded within four months of the last day labor or materials were
--   furnished, and a Notice of Intent to Lien must be served at least ten days
--   before that recording. Miss the window and the debt is still owed but the
--   security is gone — it becomes an unsecured claim you chase in county court.
--
--   So the question is not "who owes us money" (query 06 answers that). It is
--   "which unpaid balances still have leverage attached, and how many days of
--   leverage are left".
--
-- Technique
--   Date arithmetic against generated columns, a CASE ladder that encodes the
--   statutory stages, and a summary that quantifies the balance already past
--   the point of no return.
--
-- This is decision support, not legal advice. Deadlines vary by role
-- (laborers get two months, not four), tolling and substantial-completion
-- questions are fact-specific, and the actual filing decision belongs with
-- counsel. The value of the query is that nothing falls off the radar
-- silently.
-- ============================================================================

SET search_path TO restoration, public;

-- ---------------------------------------------------------------------------
-- Part 1 — The watchlist
-- ---------------------------------------------------------------------------
WITH unpaid AS (
    SELECT
        f.job_id,
        f.job_number,
        f.office_id,
        f.work_completed_on,
        f.noi_serve_deadline,
        f.lien_record_deadline,
        f.total_contract_value,
        f.invoiced_amount,
        f.collected_amount,
        f.outstanding_amount,
        f.is_insurance
    FROM v_job_financials f
    WHERE f.work_completed_on IS NOT NULL
      AND f.outstanding_amount > 500          -- not worth a filing below this
),
staged AS (
    SELECT
        u.*,
        o.office_name,
        (u.noi_serve_deadline  - asof_date()) AS days_to_noi,
        (u.lien_record_deadline - asof_date()) AS days_to_record,
        COALESCE(car.carrier_name, 'Retail / Self-pay')          AS payer,
        ROUND(100.0 * u.collected_amount
              / NULLIF(u.invoiced_amount, 0), 1)                 AS pct_collected,
        CASE
            WHEN u.lien_record_deadline <  asof_date()      THEN '5. Expired'
            WHEN u.noi_serve_deadline   <  asof_date()      THEN '4. NOI window closed - record now'
            WHEN u.noi_serve_deadline   <= asof_date() + 14 THEN '1. Serve NOI immediately'
            WHEN u.noi_serve_deadline   <= asof_date() + 45 THEN '2. Prepare NOI'
            ELSE                                                 '3. Monitor'
        END                                                      AS action
    FROM unpaid u
    JOIN offices o                ON o.office_id = u.office_id
    LEFT JOIN insurance_claims c  ON c.job_id    = u.job_id
    LEFT JOIN carriers car        ON car.carrier_id = c.carrier_id
)
SELECT
    action,
    job_number,
    office_name,
    payer,
    work_completed_on,
    noi_serve_deadline,
    lien_record_deadline,
    days_to_noi,
    days_to_record,
    invoiced_amount::numeric(12,2)      AS invoiced,
    collected_amount::numeric(12,2)     AS collected,
    outstanding_amount::numeric(12,2)   AS at_risk,
    pct_collected
FROM staged
WHERE action <> '5. Expired'
ORDER BY action, days_to_noi NULLS LAST, outstanding_amount DESC;


-- ---------------------------------------------------------------------------
-- Part 2 — What the exposure adds up to
--
-- The bottom line an owner cares about: how much unsecured money is sitting in
-- each stage, and how much has already lost its lien rights entirely. That
-- last number is the business case for running this query on a schedule.
-- ---------------------------------------------------------------------------
WITH unpaid AS (
    SELECT f.*,
        CASE
            WHEN f.lien_record_deadline <  asof_date()      THEN '5. Expired - unsecured'
            WHEN f.noi_serve_deadline   <  asof_date()      THEN '4. NOI window closed'
            WHEN f.noi_serve_deadline   <= asof_date() + 14 THEN '1. Serve NOI immediately'
            WHEN f.noi_serve_deadline   <= asof_date() + 45 THEN '2. Prepare NOI'
            ELSE                                                 '3. Monitor'
        END AS action
    FROM v_job_financials f
    WHERE f.work_completed_on IS NOT NULL
      AND f.outstanding_amount > 500
)
SELECT
    action,
    COUNT(*)                                            AS jobs,
    SUM(outstanding_amount)::numeric(14,2)              AS balance_at_risk,
    ROUND(100.0 * SUM(outstanding_amount)
          / SUM(SUM(outstanding_amount)) OVER (), 1)    AS pct_of_at_risk_ar,
    ROUND(AVG(outstanding_amount), 0)                   AS avg_balance,
    MAX(outstanding_amount)::numeric(12,2)              AS largest_balance,
    COUNT(*) FILTER (WHERE is_insurance)                AS insurance_jobs,
    COUNT(*) FILTER (WHERE NOT is_insurance)            AS retail_jobs
FROM unpaid
GROUP BY action
ORDER BY action;
