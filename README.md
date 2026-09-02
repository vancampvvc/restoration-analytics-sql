# Restoration Contracting Analytics (PostgreSQL)

A working analytical database for a multi-location property restoration and
construction company: how a lead becomes a job, how an insurance claim funds
that job, what the job costs to deliver, and whether the money gets collected
before the mechanic's lien deadline expires.

Eleven tables, three reusable views, eight analysis queries, and ~12,900 rows
of generated-but-plausible operating data covering January 2024 through August
2026.

```bash
createdb restoration_demo
./run_all.sh            # builds the database and runs every query
```

---

## Why this domain

Restoration contracting is an unusually good subject for an analytical model,
because the money moves through three parties who do not agree with each other.
A homeowner has a loss; a carrier decides what it is worth and pays on its own
schedule; the contractor funds labour and materials in between. Almost every
interesting question in the business lives in that gap.

The model reflects things that are not obvious from outside the industry:

- **Insurance-funded and retail work are different businesses.** They price
  differently, carry different margins, and get collected differently. A single
  blended margin number hides both.
- **Supplements, not carrier slowness, drive cycle time.** A claim file that
  needs two supplements takes 50–100% longer to approve than one that does not,
  across every carrier in the model.
- **An unpaid balance changes character on a specific, calculable date.** Under
  Colorado's mechanic's lien statute a contractor has four months from the last
  day of work to record a lien. Before that date it is a collections problem;
  after it, the debt is unsecured and the leverage is gone. That deadline is a
  generated column in the schema, not a spreadsheet someone maintains.

The questions in this repo come from operating experience in the industry —
accounts receivable, collections, vendor compliance and contract review — rather
than from a public dataset. The data itself is entirely synthetic: every
company, carrier, salesperson and job below is invented, and no real
organisation's data appears anywhere in this repository.

---

## What's in it

```
sql/
  01_schema.sql                    DDL: 11 tables, constraints, generated columns, indexes
  02_seed_data.sql                 Generated seed data (rebuild with tools/generate_seed_data.py)
  03_views.sql                     3 reusable views + an as-of date function
  analysis/
    01_speed_to_lead.sql           Does response time change the close rate?
    02_referral_source_concentration.sql   Pareto analysis of referral revenue
    03_salesperson_scorecard.sql   Rep performance normalised against their office
    04_carrier_cycle_time.sql      Which carriers are slow, and why
    05_job_margin_analysis.sql     Margin by size band and loss type
    06_ar_aging_and_dso.sql        Aging, collections worklist, DSO trend
    07_lien_deadline_watchlist.sql Statutory deadline exposure
    08_seasonality_and_growth.sql  Seasonality, YoY, referral cohort retention
tools/
  generate_seed_data.py            Deterministic data generator
run_all.sh                         Build + execute everything
results/                           Committed output of every query
```

### Data model

```
offices ──┬── salespeople ──┐
          │                 │
          └──────────────┐  │
                         ▼  ▼
referral_verticals ── referral_sources ──► leads ──► jobs ──┬──► insurance_claims ──► carriers
                                                            ├──► job_costs
                                                            └──► invoices ──► payments
```

`leads` is the grain that makes conversion analysis possible: every
opportunity is a row whether it was won or not, so the denominator is real.
`jobs` has a `UNIQUE` constraint on `lead_id`, which is what stops a lead from
quietly becoming two jobs and double-counting revenue.

### Techniques used

| | |
|---|---|
| Window functions | `SUM() OVER` running totals for Pareto curves, `LAG(n, 12)` for YoY, centred moving averages with explicit frames, `NTILE`, `RANK`, `DENSE_RANK` |
| Aggregation | `FILTER` clauses for conditional pivots, `GROUPING SETS` and `ROLLUP` for subtotals in one pass, `PERCENTILE_CONT` for medians and p90 |
| Joins | `LEFT JOIN LATERAL` to pre-aggregate before joining and avoid fan-out |
| Schema design | `GENERATED ALWAYS AS ... STORED` columns for statutory deadlines, `CHECK` constraints encoding business rules, partial indexes on the filtered columns queries actually use |
| Time series | `generate_series` month spine so empty periods appear as zero instead of disappearing |

One definitional note, because inconsistency here is a common way two reports
disagree: **close rate is wins over *decided* leads** (`Won`/`Lost`/`Dead`)
everywhere it appears, never wins over all leads received. Leads still in flight
have no outcome yet, and including them makes the most recent months collapse
toward zero for reasons that have nothing to do with sales performance.

---

## Findings

Every number below comes from the committed output in `results/`.

**Response time tracks conversion, hard.** Leads contacted within an hour close
at 44.8%. Past three days it is 19.3%, and leads never contacted at all close at
4.2%. The middle of the distribution is where the money is: 41% of all leads sit
in the 4–24 hour bucket, and closing the gap between that bucket and the
one-hour bucket is worth roughly $2.2M in contract value across the period.

The honest caveat, which is in the query header too: this is observational.
Leads that are easy to reach are also easier to close, so some of that gap is
selection rather than causation. The claim the data supports is a strong
association; the thing that would prove causation is a randomised routing test.

**Referral revenue is dangerously concentrated.** 9 of 45 referral sources
produce half the revenue; 21 produce 80%. Nine of the top ten are property
management companies. That is a real single-point-of-failure: losing the top two
relationships would take out 14.6% of revenue, and there is no marketing
channel in the data capable of replacing it quickly — paid search converts at
a third the rate of a property-management referral.

**Carrier cycle time varies by nearly a factor of two.** Median
estimate-to-approval runs 26.5 days at the fastest carrier in the model and 48
at the two slowest. Supplements
are the mechanism: across every carrier, files with two or more supplements
take 49–99% longer to approve than files with none. That is an argument for
getting the first estimate right rather than for chasing the carrier.

**Margin thins sharply on the largest jobs.** Overall gross margin is 32.2% and
holds near 33–34% in every size band up to $100k — then drops to 26.8% above it.
The cost mix does not single out one culprit: from the smallest band to the
largest, labour rises 22.8% → 25.0% of revenue, materials 17.6% → 19.6%, and
subcontractor 17.1% → 18.9%. All three lines drift up by roughly two points
together, which points at systematic underpricing of large jobs rather than one
runaway cost category. The largest jobs are the ones the sales team is proudest
of and the ones the company earns least on.

The 26 jobs above $100k are a thin sample, so this is a hypothesis to test on
more data before repricing anything — but it is the segment worth testing.

**A third of receivables are over 90 days.** $1.62M outstanding, 32.6% of it
past 90 days. In the two largest offices, retail balances age worse than
insurance balances — 39.7% vs 30.8% over 90 in Aurora, 78.1% vs 10.6%
in Longmont. Counterintuitive until you remember that a carrier eventually pays
and a homeowner in a dispute may not. The Western Slope office inverts the pattern, on
a book too small — 12 open invoices in total — to read as anything but noise.

**DSO runs 60–95 days and is not trending down.** Ending receivables against
monthly billings puts days sales outstanding in the 60s and 90s through 2026,
with the three-month average flat around 70–78. For work that is funded by
carriers approving estimates on a 26-to-48-day median cycle, that is a company financing
roughly two months of its own labour and materials continuously.

**$632,000 has already lost its lien rights.** 49 completed jobs with unpaid
balances are past the four-month recording deadline — 37% of the at-risk
receivable, now unsecured. Only two jobs are inside the urgent window today,
which is the point: the exposure was created months ago by nobody watching the
date. This query run monthly would have caught every one of them.

---

## Notes on the data

It is generated by `tools/generate_seed_data.py` with a fixed seed, so the
committed `02_seed_data.sql` is reproducible. The generator deliberately
encodes real structure rather than uniform randomness:

- **Seasonality** — freeze-driven water losses in January and February, hail in
  May through July, a November trough. Front Range weather, roughly.
- **Conversion that depends on response time** and differs by referral
  vertical, so query 01 has something real to find.
- **Collection behaviour that depends on invoice age**, so the aging report is
  not nonsense. An earlier version made payment outcome independent of age and
  produced a 60%-over-90-days receivable, which would describe a company in
  distress rather than a normal one. That bug is why the generator now buckets
  outcomes by age.
- **Long-tailed cycle times**, so the median and p90 in query 04 tell different
  stories — as they do in real claim data.

### One design decision worth calling out

Aging and deadline logic uses an `asof_date()` function that anchors to the
latest transaction in the data, not `CURRENT_DATE`. Using the wall clock would
mean that six months after generating this dataset, every invoice in it appears
90+ days late and the report becomes meaningless to anyone who clones the repo.
In production this would be a parameter supplied by the BI layer with
`CURRENT_DATE` as the default.

### On the invented names

Every carrier, referral source, vendor and salesperson in this dataset is
fictional, and the office locations do not correspond to any real company's
footprint. Colorado is kept because the lien deadlines are state-specific and
that logic is a large part of the point; nothing else about the geography is
meaningful. Attaching simulated cycle-time and denial-rate figures to real
insurers' names would be misleading no matter how clearly the data was labelled
synthetic, so the model does not do it.

### Scope

This is a single-schema analytical model, not a data warehouse. There is no
slowly-changing-dimension handling, no incremental load, and no orchestration —
a job's salesperson is stored as a current value, so reassigning a rep would
rewrite history. Real dimensional modelling is the obvious next step and is
deliberately out of scope here.

Nothing in this repo is legal advice. Colorado lien deadlines vary by role and
circumstance, and the filing decision belongs with counsel; the query exists so
that no deadline passes unnoticed.

---

## Running it

Requires PostgreSQL 13 or later.

```bash
./run_all.sh                    # default database name: restoration_demo
./run_all.sh my_database        # or name your own
SAVE=1 ./run_all.sh             # also refresh results/*.txt
python3 tools/generate_seed_data.py > sql/02_seed_data.sql   # regenerate data
```
