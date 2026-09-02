-- ============================================================================
-- Restoration Contracting Analytics — Reusable Views
--
-- Three things get recomputed in almost every downstream question: what a job
-- cost, what an invoice still owes, and how fast a lead was answered. Defining
-- them once here keeps the analysis queries about the business question
-- instead of about the arithmetic, and gives a BI tool a clean layer to import
-- rather than re-deriving margin in six different report definitions.
-- ============================================================================

SET search_path TO restoration, public;

-- ---------------------------------------------------------------------------
-- asof_date() — the reporting "today".
--
-- Aging and deadline queries need a reference date. Using CURRENT_DATE looks
-- natural and is wrong here: this is a fixed demo dataset, so every month that
-- passes after it was generated pushes more of the receivable into the 90+
-- bucket until the report is meaningless. Anchoring to the latest transaction
-- in the data keeps the output stable whenever someone clones and runs it.
--
-- In production this would be a parameter passed by the BI layer, and the
-- default would be CURRENT_DATE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION asof_date() RETURNS date
LANGUAGE sql STABLE AS $$
    SELECT GREATEST(
        (SELECT MAX(issued_on)   FROM invoices),
        (SELECT MAX(received_on) FROM payments),
        (SELECT MAX(work_completed_on) FROM jobs)
    );
$$;

COMMENT ON FUNCTION asof_date() IS
    'Reporting date for aging/deadline logic; anchored to the data, not the clock.';

-- ---------------------------------------------------------------------------
-- v_job_financials — one row per job with cost rolled up and margin derived.
--
-- The LEFT JOIN LATERAL keeps this to a single pass over job_costs per job and
-- avoids the classic fan-out bug: joining costs and invoices to jobs in one
-- query multiplies the rows and silently inflates every SUM.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_job_financials AS
SELECT
    j.job_id,
    j.job_number,
    j.office_id,
    j.salesperson_id,
    j.lead_id,
    j.sold_on,
    j.work_started_on,
    j.work_completed_on,
    j.status,
    j.is_insurance,
    j.total_contract_value,
    COALESCE(c.total_cost, 0)                                   AS total_cost,
    j.total_contract_value - COALESCE(c.total_cost, 0)          AS gross_profit,
    ROUND(
        (j.total_contract_value - COALESCE(c.total_cost, 0))
        / NULLIF(j.total_contract_value, 0) * 100
    , 2)                                                        AS gross_margin_pct,
    c.labor_cost,
    c.material_cost,
    c.subcontractor_cost,
    COALESCE(i.invoiced_amount, 0)                              AS invoiced_amount,
    COALESCE(i.collected_amount, 0)                             AS collected_amount,
    COALESCE(i.invoiced_amount, 0) - COALESCE(i.collected_amount, 0)
                                                                AS outstanding_amount,
    j.work_completed_on IS NOT NULL                             AS is_complete,
    j.lien_record_deadline,
    j.noi_serve_deadline
FROM jobs j
LEFT JOIN LATERAL (
    SELECT
        SUM(jc.amount)                                                   AS total_cost,
        SUM(jc.amount) FILTER (WHERE jc.cost_category = 'Labor')         AS labor_cost,
        SUM(jc.amount) FILTER (WHERE jc.cost_category = 'Materials')     AS material_cost,
        SUM(jc.amount) FILTER (WHERE jc.cost_category = 'Subcontractor') AS subcontractor_cost
    FROM job_costs jc
    WHERE jc.job_id = j.job_id
) c ON TRUE
LEFT JOIN LATERAL (
    SELECT
        SUM(inv.amount)      AS invoiced_amount,
        SUM(p.paid)          AS collected_amount
    FROM invoices inv
    LEFT JOIN LATERAL (
        SELECT COALESCE(SUM(pm.amount), 0) AS paid
        FROM payments pm
        WHERE pm.invoice_id = inv.invoice_id
    ) p ON TRUE
    WHERE inv.job_id = j.job_id
) i ON TRUE
WHERE j.status <> 'Cancelled';

COMMENT ON VIEW v_job_financials IS
    'Job-grain P&L: contract value, rolled-up cost, margin, and collection status.';


-- ---------------------------------------------------------------------------
-- v_invoice_balances — receivable position per invoice, as of a run date.
--
-- days_past_due is negative while the invoice is still within terms, which
-- makes a single CASE ladder able to express both "not yet due" and the aging
-- buckets without a separate branch.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_invoice_balances AS
SELECT
    inv.invoice_id,
    inv.job_id,
    inv.invoice_number,
    inv.issued_on,
    inv.due_on,
    inv.amount                                  AS invoiced,
    COALESCE(p.paid, 0)                         AS paid,
    inv.amount - COALESCE(p.paid, 0)            AS balance,
    inv.status,
    (asof_date() - inv.due_on)                  AS days_past_due,
    p.last_payment_on,
    CASE
        WHEN inv.status = 'Paid'                      THEN 'Paid'
        WHEN inv.status = 'Written Off'               THEN 'Written Off'
        WHEN asof_date() <= inv.due_on                THEN 'Current'
        WHEN asof_date() - inv.due_on <=  30          THEN '1-30'
        WHEN asof_date() - inv.due_on <=  60          THEN '31-60'
        WHEN asof_date() - inv.due_on <=  90          THEN '61-90'
        ELSE '90+'
    END                                          AS aging_bucket
FROM invoices inv
LEFT JOIN LATERAL (
    SELECT SUM(pm.amount) AS paid, MAX(pm.received_on) AS last_payment_on
    FROM payments pm
    WHERE pm.invoice_id = inv.invoice_id
) p ON TRUE;

COMMENT ON VIEW v_invoice_balances IS
    'Per-invoice receivable balance and aging bucket as of asof_date().';


-- ---------------------------------------------------------------------------
-- v_lead_response — speed-to-lead, the single most actionable sales metric
-- this dataset contains.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_lead_response AS
SELECT
    l.lead_id,
    l.office_id,
    l.salesperson_id,
    l.source_id,
    rs.vertical_id,
    l.received_at,
    l.first_contact_at,
    l.status,
    l.estimated_value,
    l.loss_type,
    l.property_type,
    (l.status = 'Won')                                          AS is_won,
    EXTRACT(EPOCH FROM (l.first_contact_at - l.received_at)) / 3600.0
                                                                AS response_hours,
    CASE
        WHEN l.first_contact_at IS NULL                                       THEN 'Never contacted'
        WHEN l.first_contact_at - l.received_at <= INTERVAL '1 hour'          THEN '0-1 hr'
        WHEN l.first_contact_at - l.received_at <= INTERVAL '4 hours'         THEN '1-4 hr'
        WHEN l.first_contact_at - l.received_at <= INTERVAL '24 hours'        THEN '4-24 hr'
        WHEN l.first_contact_at - l.received_at <= INTERVAL '72 hours'        THEN '1-3 days'
        ELSE '3+ days'
    END                                                         AS response_bucket
FROM leads l
JOIN referral_sources rs ON rs.source_id = l.source_id;

COMMENT ON VIEW v_lead_response IS
    'Lead grain with response latency bucketed for close-rate comparison.';
