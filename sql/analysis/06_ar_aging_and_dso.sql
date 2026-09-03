-- ============================================================================
-- 06 — Accounts receivable aging and days sales outstanding
--
-- Business question
--   Restoration is cash-flow sensitive: the company funds labor and materials
--   before the carrier pays. This is the collections worklist and the DSO
--   trend that tells us whether collections are getting better or worse.
--
-- Technique
--   Aging buckets from the shared view, a crosstab built with FILTER, and a
--   rolling three-month DSO computed with a window frame — the moving average
--   is what separates a trend from a lumpy month.
-- ============================================================================

SET search_path TO restoration, public;

-- ---------------------------------------------------------------------------
-- Part 1 — Aging summary by office and funding source
-- ---------------------------------------------------------------------------
SELECT
    o.office_name,
    CASE WHEN j.is_insurance THEN 'Insurance' ELSE 'Retail' END AS funding,
    COUNT(*)                                                    AS open_invoices,
    SUM(b.balance)::numeric(14,2)                               AS total_ar,
    SUM(b.balance) FILTER (WHERE b.aging_bucket = 'Current')::numeric(14,2) AS current_ar,
    SUM(b.balance) FILTER (WHERE b.aging_bucket = '1-30')::numeric(14,2)    AS days_1_30,
    SUM(b.balance) FILTER (WHERE b.aging_bucket = '31-60')::numeric(14,2)   AS days_31_60,
    SUM(b.balance) FILTER (WHERE b.aging_bucket = '61-90')::numeric(14,2)   AS days_61_90,
    SUM(b.balance) FILTER (WHERE b.aging_bucket = '90+')::numeric(14,2)     AS days_90_plus,
    ROUND(100.0 * SUM(b.balance) FILTER (WHERE b.aging_bucket = '90+')
          / NULLIF(SUM(b.balance), 0), 1)                       AS pct_over_90
FROM v_invoice_balances b
JOIN jobs    j ON j.job_id    = b.job_id
JOIN offices o ON o.office_id = j.office_id
WHERE b.balance > 0.01
  AND b.status <> 'Written Off'
GROUP BY ROLLUP (o.office_name, CASE WHEN j.is_insurance THEN 'Insurance' ELSE 'Retail' END)
ORDER BY o.office_name NULLS LAST, funding NULLS LAST;


-- ---------------------------------------------------------------------------
-- Part 2 — The collections worklist: worst 25 balances, with context
--
-- An aging report nobody can act on is decoration. This one names the job, the
-- payer, how long since anyone sent money, and whether the lien window is
-- still open — which is the only leverage that exists on an old balance.
-- ---------------------------------------------------------------------------
SELECT
    b.invoice_number,
    j.job_number,
    o.office_name,
    b.issued_on,
    b.due_on,
    b.days_past_due,
    b.aging_bucket,
    b.invoiced::numeric(12,2),
    b.paid::numeric(12,2),
    b.balance::numeric(12,2),
    b.last_payment_on,
    COALESCE(car.carrier_name, 'Retail / Self-pay')             AS payer,
    j.lien_record_deadline,
    CASE
        WHEN j.lien_record_deadline IS NULL              THEN 'Work not complete'
        WHEN j.lien_record_deadline < asof_date()        THEN 'EXPIRED - lien rights lost'
        WHEN j.lien_record_deadline < asof_date() + 30   THEN 'URGENT - under 30 days'
        ELSE 'Open'
    END                                                         AS lien_status
FROM v_invoice_balances b
JOIN jobs j     ON j.job_id = b.job_id
JOIN offices o  ON o.office_id = j.office_id
LEFT JOIN insurance_claims c ON c.job_id = j.job_id
LEFT JOIN carriers car       ON car.carrier_id = c.carrier_id
WHERE b.balance > 0.01
  AND b.status <> 'Written Off'
  AND b.days_past_due > 0
ORDER BY b.balance DESC
LIMIT 25;


-- ---------------------------------------------------------------------------
-- Part 3 — Monthly DSO with a 3-month rolling average
--
-- DSO = ending receivables / period billings x days in period.
--
-- The trap is "ending receivables". It is the balance STANDING at month end —
-- every invoice issued up to that date, less every payment received up to that
-- date — not this month's invoices less their own payments. Those two are very
-- different numbers: the second ignores the prior book entirely and looks
-- ahead to payments that had not happened yet at month end. An earlier version
-- of this query made exactly that mistake and reported a DSO of 0 for eight
-- months on a book that never fell below $1.3M.
--
-- Written-off balances are excluded: they are a bad-debt event, not a
-- collection-speed problem, and leaving them in makes DSO drift upward forever.
-- ---------------------------------------------------------------------------
WITH spine AS (
    SELECT generate_series(
        DATE_TRUNC('month', (SELECT MIN(issued_on) FROM invoices))::date,
        DATE_TRUNC('month', asof_date())::date,
        INTERVAL '1 month'
    )::date AS month
),
monthly AS (
    SELECT
        s.month,
        (s.month + INTERVAL '1 month - 1 day')::date            AS month_end,
        -- Billings raised inside the month.
        COALESCE((
            SELECT SUM(i.amount) FROM invoices i
            WHERE i.issued_on >= s.month
              AND i.issued_on <  s.month + INTERVAL '1 month'
              AND i.status <> 'Written Off'
        ), 0)                                                   AS billings,
        -- Balance standing at month end: everything invoiced to date, less
        -- everything collected to date.
        COALESCE((
            SELECT SUM(i.amount) FROM invoices i
            WHERE i.issued_on < s.month + INTERVAL '1 month'
              AND i.status <> 'Written Off'
        ), 0)
        - COALESCE((
            SELECT SUM(pm.amount)
            FROM payments pm
            JOIN invoices i2 ON i2.invoice_id = pm.invoice_id
            WHERE pm.received_on < s.month + INTERVAL '1 month'
              AND i2.status <> 'Written Off'
        ), 0)                                                   AS ending_ar
    FROM spine s
),
with_dso AS (
    SELECT
        month,
        billings,
        ending_ar,
        ending_ar / NULLIF(billings, 0)
            * EXTRACT(DAY FROM month_end)                       AS dso
    FROM monthly
)
SELECT
    month,
    billings::numeric(14,2),
    ending_ar::numeric(14,2),
    ROUND(dso, 1)                                               AS dso,
    ROUND(AVG(dso) OVER (ORDER BY month
                         ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1)
                                                                AS dso_3mo_avg,
    ROUND(dso - LAG(dso) OVER (ORDER BY month), 1)              AS dso_change
FROM with_dso
ORDER BY month;
