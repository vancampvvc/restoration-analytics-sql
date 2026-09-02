-- ============================================================================
-- Restoration Contracting Analytics — Schema
-- PostgreSQL 16
--
-- Models the operational core of a multi-location property restoration and
-- construction company: how a lead becomes a job, how an insurance claim funds
-- that job, what the job costs to deliver, and whether the money is collected
-- before the mechanic's lien deadline runs out.
--
-- Design notes:
--   * Money is NUMERIC(12,2). Never floating point.
--   * Every fact table carries the office_id so the model slices by location
--     without a join chain back through leads.
--   * Statuses are constrained with CHECK rather than lookup tables — small,
--     stable domains that belong in the DDL where a reader can see them.
--   * Lien deadlines are stored as generated columns derived from the last
--     day of work, so the deadline cannot drift out of sync with the job.
-- ============================================================================

DROP SCHEMA IF EXISTS restoration CASCADE;
CREATE SCHEMA restoration;
SET search_path TO restoration, public;

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------

CREATE TABLE offices (
    office_id       INT PRIMARY KEY,
    office_name     TEXT        NOT NULL UNIQUE,
    city            TEXT        NOT NULL,
    state           CHAR(2)     NOT NULL,
    opened_on       DATE        NOT NULL
);

CREATE TABLE salespeople (
    salesperson_id  INT PRIMARY KEY,
    full_name       TEXT        NOT NULL,
    office_id       INT         NOT NULL REFERENCES offices(office_id),
    hired_on        DATE        NOT NULL,
    terminated_on   DATE,
    commission_rate NUMERIC(5,4) NOT NULL DEFAULT 0.0400,
    CONSTRAINT salesperson_dates_ordered
        CHECK (terminated_on IS NULL OR terminated_on >= hired_on)
);

-- The referral vertical taxonomy is how the business actually thinks about
-- where work comes from: an HOA manager and a plumber both refer work, but
-- they refer different work, at different sizes, with different close rates.
CREATE TABLE referral_verticals (
    vertical_id     INT PRIMARY KEY,
    vertical_name   TEXT NOT NULL UNIQUE,
    vertical_group  TEXT NOT NULL
        CHECK (vertical_group IN ('Property Management','Trade Partner',
                                  'Insurance','Direct','Institutional'))
);

CREATE TABLE referral_sources (
    source_id       INT PRIMARY KEY,
    source_name     TEXT NOT NULL,
    vertical_id     INT  NOT NULL REFERENCES referral_verticals(vertical_id),
    first_referral_on DATE,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE carriers (
    carrier_id      INT PRIMARY KEY,
    carrier_name    TEXT NOT NULL UNIQUE,
    -- Observed average days from estimate submission to APPROVAL for this
    -- carrier. A benchmark to measure against, not a forecast. Approval is a
    -- deliberately different milestone from payment; mixing the two is how a
    -- cycle-time report ends up comparing numbers that were never comparable.
    typical_approval_days INT NOT NULL
);

-- ---------------------------------------------------------------------------
-- The funnel: lead -> job
-- ---------------------------------------------------------------------------

CREATE TABLE leads (
    lead_id         INT PRIMARY KEY,
    office_id       INT  NOT NULL REFERENCES offices(office_id),
    salesperson_id  INT  REFERENCES salespeople(salesperson_id),
    source_id       INT  NOT NULL REFERENCES referral_sources(source_id),
    received_at     TIMESTAMP NOT NULL,
    first_contact_at TIMESTAMP,
    inspected_on    DATE,
    loss_type       TEXT NOT NULL
        CHECK (loss_type IN ('Water','Fire','Storm','Mold','Reconstruction','Contents')),
    property_type   TEXT NOT NULL
        CHECK (property_type IN ('Single Family','Multifamily','HOA','Commercial','Institutional')),
    postal_code     CHAR(5) NOT NULL,
    estimated_value NUMERIC(12,2),
    status          TEXT NOT NULL
        CHECK (status IN ('New','Contacted','Inspected','Estimated','Won','Lost','Dead')),
    lost_reason     TEXT,
    CONSTRAINT lead_contact_after_receipt
        CHECK (first_contact_at IS NULL OR first_contact_at >= received_at),
    CONSTRAINT lost_reason_only_when_lost
        CHECK ((status IN ('Lost','Dead')) = (lost_reason IS NOT NULL))
);

CREATE TABLE jobs (
    job_id          INT PRIMARY KEY,
    job_number      TEXT NOT NULL UNIQUE,
    lead_id         INT  NOT NULL UNIQUE REFERENCES leads(lead_id),
    office_id       INT  NOT NULL REFERENCES offices(office_id),
    salesperson_id  INT  REFERENCES salespeople(salesperson_id),
    sold_on         DATE NOT NULL,
    work_started_on DATE,
    work_completed_on DATE,
    contract_amount NUMERIC(12,2) NOT NULL CHECK (contract_amount > 0),
    change_orders   NUMERIC(12,2) NOT NULL DEFAULT 0,
    status          TEXT NOT NULL
        CHECK (status IN ('Sold','In Progress','Complete','Invoiced','Closed','Cancelled')),
    is_insurance    BOOLEAN NOT NULL,

    -- Total contract value, maintained by the database rather than by whoever
    -- remembers to add the change orders.
    total_contract_value NUMERIC(12,2)
        GENERATED ALWAYS AS (contract_amount + change_orders) STORED,

    -- Colorado mechanic's lien statute (C.R.S. 38-22): the lien statement must
    -- be recorded within 4 months of the last day labor or materials were
    -- furnished, and a Notice of Intent must be served at least 10 days before
    -- recording. Deriving both from work_completed_on means the watchlist can
    -- never disagree with the job record.
    lien_record_deadline DATE
        GENERATED ALWAYS AS (work_completed_on + INTERVAL '4 months') STORED,
    noi_serve_deadline DATE
        GENERATED ALWAYS AS (work_completed_on + INTERVAL '4 months' - INTERVAL '10 days') STORED,

    CONSTRAINT job_dates_ordered
        CHECK (work_completed_on IS NULL OR work_started_on IS NULL
               OR work_completed_on >= work_started_on)
);

CREATE TABLE insurance_claims (
    claim_id        INT PRIMARY KEY,
    job_id          INT  NOT NULL UNIQUE REFERENCES jobs(job_id),
    carrier_id      INT  NOT NULL REFERENCES carriers(carrier_id),
    claim_number    TEXT NOT NULL,
    date_of_loss    DATE NOT NULL,
    reported_on     DATE NOT NULL,
    estimate_submitted_on DATE,
    approved_on     DATE,
    deductible      NUMERIC(10,2) NOT NULL DEFAULT 0,
    rcv_amount      NUMERIC(12,2),   -- replacement cost value
    acv_amount      NUMERIC(12,2),   -- actual cash value (RCV less depreciation)
    depreciation_recovered NUMERIC(12,2) NOT NULL DEFAULT 0,
    supplement_count INT NOT NULL DEFAULT 0,
    status          TEXT NOT NULL
        CHECK (status IN ('Open','Estimate Submitted','Approved','Partially Paid','Paid','Denied')),
    CONSTRAINT acv_not_above_rcv
        CHECK (acv_amount IS NULL OR rcv_amount IS NULL OR acv_amount <= rcv_amount)
);

-- ---------------------------------------------------------------------------
-- Cost and cash
-- ---------------------------------------------------------------------------

CREATE TABLE job_costs (
    cost_id         BIGINT PRIMARY KEY,
    job_id          INT  NOT NULL REFERENCES jobs(job_id),
    cost_category   TEXT NOT NULL
        CHECK (cost_category IN ('Labor','Materials','Subcontractor','Equipment','Permits','Other')),
    incurred_on     DATE NOT NULL,
    amount          NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    vendor_name     TEXT
);

CREATE TABLE invoices (
    invoice_id      INT PRIMARY KEY,
    job_id          INT  NOT NULL REFERENCES jobs(job_id),
    invoice_number  TEXT NOT NULL UNIQUE,
    issued_on       DATE NOT NULL,
    due_on          DATE NOT NULL,
    amount          NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    status          TEXT NOT NULL
        CHECK (status IN ('Open','Partially Paid','Paid','Written Off')),
    CONSTRAINT invoice_due_after_issue CHECK (due_on >= issued_on)
);

CREATE TABLE payments (
    payment_id      BIGINT PRIMARY KEY,
    invoice_id      INT  NOT NULL REFERENCES invoices(invoice_id),
    received_on     DATE NOT NULL,
    amount          NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    payer_type      TEXT NOT NULL
        CHECK (payer_type IN ('Carrier','Homeowner','Property Manager','Mortgage Company')),
    method          TEXT NOT NULL
        CHECK (method IN ('Check','ACH','Card','Wire'))
);

-- ---------------------------------------------------------------------------
-- Indexes
--
-- Chosen for the access patterns the analysis queries actually use, not
-- sprayed across every column: date-range scans on the funnel, and the
-- foreign-key side of the joins that fan out per job.
-- ---------------------------------------------------------------------------

CREATE INDEX idx_leads_received     ON leads (received_at);
CREATE INDEX idx_leads_source       ON leads (source_id);
CREATE INDEX idx_leads_office_status ON leads (office_id, status);
CREATE INDEX idx_jobs_sold          ON jobs (sold_on);
CREATE INDEX idx_jobs_completed     ON jobs (work_completed_on) WHERE work_completed_on IS NOT NULL;
CREATE INDEX idx_job_costs_job      ON job_costs (job_id);
CREATE INDEX idx_invoices_job       ON invoices (job_id);
CREATE INDEX idx_invoices_open      ON invoices (due_on) WHERE status <> 'Paid';
CREATE INDEX idx_payments_invoice   ON payments (invoice_id);

COMMENT ON TABLE  leads IS 'Every inbound opportunity, won or not. The denominator for all conversion analysis.';
COMMENT ON TABLE  jobs  IS 'A lead that was sold. One row per lead at most, enforced by the UNIQUE on lead_id.';
COMMENT ON COLUMN jobs.lien_record_deadline IS 'C.R.S. 38-22-109: 4 months from last day of work.';
COMMENT ON COLUMN jobs.noi_serve_deadline   IS 'Notice of Intent must be served 10+ days before recording.';
