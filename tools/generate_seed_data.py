#!/usr/bin/env python3
"""
Generate sql/02_seed_data.sql for the restoration analytics project.

The point of generating rather than hand-writing the data is that the *shape*
of the data has to be defensible. Real restoration work is seasonal (hail in
late spring, freeze breaks in January), close rates differ sharply by referral
vertical, carrier payment behaviour varies, and a meaningful slice of
receivables goes past due. A random dump would produce queries that run but
say nothing.

Deterministic: seeded RNG, so the committed .sql file is reproducible.

Usage:  python3 tools/generate_seed_data.py > sql/02_seed_data.sql
"""

import random
import sys
from datetime import date, datetime, timedelta

RNG = random.Random(20260902)

START = date(2024, 1, 1)
END = date(2026, 8, 31)

# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------

OFFICES = [
    (1, "Aurora", "Aurora", "CO", date(2016, 3, 1)),
    (2, "Longmont", "Longmont", "CO", date(2019, 7, 15)),
    (3, "Western Slope", "Grand Junction", "CO", date(2022, 4, 4)),
]

SALESPEOPLE = [
    (1, "Marcus Whitfield", 1, date(2018, 5, 14), None, 0.0450),
    (2, "Danielle Ortega", 1, date(2020, 2, 3), None, 0.0400),
    (3, "Brant Kessler", 1, date(2023, 8, 21), None, 0.0350),
    (4, "Priya Raghunathan", 2, date(2019, 9, 9), None, 0.0450),
    (5, "Tomas Lindqvist", 2, date(2021, 6, 28), date(2025, 11, 14), 0.0400),
    (6, "Alicia Boone", 2, date(2024, 1, 8), None, 0.0350),
    (7, "Grady Nolan", 3, date(2022, 4, 18), None, 0.0400),
    (8, "Renee Castellanos", 3, date(2024, 5, 6), None, 0.0350),
]

# vertical_id, name, group
VERTICALS = [
    (1, "Commercial Property Management", "Property Management"),
    (2, "Multifamily / Apartments", "Property Management"),
    (3, "HOA / Community Association", "Property Management"),
    (4, "Single Family Property Management", "Property Management"),
    (5, "Plumbing", "Trade Partner"),
    (6, "HVAC", "Trade Partner"),
    (7, "Roofing", "Trade Partner"),
    (8, "General Contractor", "Trade Partner"),
    (9, "Insurance Agent", "Insurance"),
    (10, "Independent Adjuster", "Insurance"),
    (11, "Carrier Program", "Insurance"),
    (12, "Past Customer", "Direct"),
    (13, "Web / Organic Search", "Direct"),
    (14, "Paid Search", "Direct"),
    (15, "Restaurant / Small Business", "Institutional"),
    (16, "Healthcare Facility", "Institutional"),
    (17, "School District", "Institutional"),
    (18, "Municipal / Government", "Institutional"),
]

# Close rate and typical job size differ enormously by vertical. These weights
# drive both how many leads a source sends and how well those leads convert.
VERTICAL_PROFILE = {
    1:  dict(weight=10, close=0.42, size=(18000, 145000)),
    2:  dict(weight=12, close=0.38, size=(9000, 110000)),
    3:  dict(weight=8,  close=0.35, size=(14000, 180000)),
    4:  dict(weight=7,  close=0.44, size=(4500, 38000)),
    5:  dict(weight=11, close=0.58, size=(3200, 42000)),
    6:  dict(weight=5,  close=0.51, size=(3800, 36000)),
    7:  dict(weight=6,  close=0.40, size=(11000, 95000)),
    8:  dict(weight=4,  close=0.46, size=(8000, 72000)),
    9:  dict(weight=7,  close=0.33, size=(6500, 68000)),
    10: dict(weight=3,  close=0.29, size=(9000, 88000)),
    11: dict(weight=4,  close=0.62, size=(5200, 51000)),
    12: dict(weight=6,  close=0.55, size=(3500, 44000)),
    13: dict(weight=9,  close=0.17, size=(2800, 33000)),
    14: dict(weight=8,  close=0.12, size=(2600, 29000)),
    15: dict(weight=4,  close=0.31, size=(7000, 62000)),
    16: dict(weight=2,  close=0.27, size=(22000, 210000)),
    17: dict(weight=2,  close=0.24, size=(19000, 165000)),
    18: dict(weight=2,  close=0.21, size=(24000, 195000)),
}

# All referral sources are invented. Same count per vertical as the original
# draft, so the seeded generator produces an identical data shape.
SOURCE_NAMES = {
    1: ["Waypoint Property Group", "Ridgeline Asset Management",
        "Brightleaf Commercial", "Stonegate Property Partners",
        "Cornerstone Commercial Realty"],
    2: ["Alder Creek Residential", "Vantage Living Communities",
        "Marlowe Apartment Group", "Windrose Residential"],
    3: ["Elkhorn Ridge HOA", "Juniper Hollow Community Assn",
        "Silverstone Bluffs HOA"],
    4: ["Front Door Property Management", "Anchor Residential Management"],
    5: ["Wren Plumbing", "Trailhead Rooter", "Millrace Plumbing & Drain",
        "Anvil Pipe Works"],
    6: ["Foxglove Heating & Air", "Compass Mechanical"],
    7: ["Gable Roofing Co", "Weathervane Roofing", "Slate & Shingle Exteriors"],
    8: ["Timberline Construction", "Marbury General Contracting"],
    9: ["Ambrose Insurance Agency", "Redstone Insurance Partners",
        "Wayfarer Risk Advisors"],
    10: ["Plumb Line Adjusters", "Fair Weather Claims Services"],
    11: ["Preferred Contractor Network", "Carrier Direct Assignment"],
    12: ["Past Customer Referral"],
    13: ["Organic Search", "Website Contact Form"],
    14: ["Paid Search", "Local Services Ads"],
    15: ["Copper Kettle Restaurant Group", "Riverbend Hospitality"],
    16: ["Aspen Ridge Medical", "Two Rivers Dental Partners"],
    17: ["Larkspur School District", "Cedar Valley School District"],
    18: ["City of Mill Creek", "Wheatland County Facilities"],
}

# Invented carriers. Every carrier figure in this repo -- cycle time, denial
# rate, supplement behaviour -- is simulated, and attaching simulated numbers to
# real insurers' names would be misleading regardless of intent.
CARRIERS = [
    (1, "Summit Mutual", 24),
    (2, "Cascade General", 31),
    (3, "Meridian Assurance", 19),
    (4, "Northstar Indemnity", 38),
    (5, "Bluewater Casualty", 27),
    (6, "Ironbridge Mutual", 34),
    (7, "Halcyon Insurance Group", 41),
    (8, "Vantage Property & Casualty", 22),
    (9, "Keystone Indemnity", 33),
    (10, "Larkspur Mutual", 26),
]

POSTAL_CODES = {
    1: ["80010", "80011", "80012", "80013", "80014", "80015", "80016", "80017",
        "80018", "80019", "80045", "80046", "80247"],
    2: ["80501", "80502", "80503", "80504", "80516", "80513", "80020", "80021",
        "80026", "80027", "80301", "80303"],
    3: ["81501", "81502", "81503", "81504", "81505", "81506", "81507", "81520"],
}

LOSS_TYPES = ["Water", "Fire", "Storm", "Mold", "Reconstruction", "Contents"]
PROPERTY_TYPES = ["Single Family", "Multifamily", "HOA", "Commercial", "Institutional"]

LOST_REASONS = [
    "Price - lost to competitor", "Below deductible", "Customer unresponsive",
    "Insurance denied claim", "Out of service area", "Scheduling conflict",
    "Customer chose to self-perform",
]

COST_MIX = {
    "Labor": 0.34, "Materials": 0.27, "Subcontractor": 0.26,
    "Equipment": 0.08, "Permits": 0.02, "Other": 0.03,
}

VENDORS = ["Highline Supply Co", "Cornerstone Building Products",
           "Rapid Dry Equipment Rental", "Boxelder Drywall LLC",
           "Lantern Electric", "Quarry Flooring Co", "Westward Paint Supply",
           "Blue Barrel Waste Services", "Aqua Dry Solutions"]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def q(v):
    """Render a Python value as a SQL literal."""
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, datetime):
        return "'" + v.strftime("%Y-%m-%d %H:%M:%S") + "'"
    if isinstance(v, date):
        return "'" + v.isoformat() + "'"
    return "'" + str(v).replace("'", "''") + "'"


def insert(table, columns, rows):
    """Emit a multi-row INSERT, chunked so no single statement gets absurd."""
    out = []
    for i in range(0, len(rows), 250):
        chunk = rows[i:i + 250]
        out.append(f"INSERT INTO {table} ({', '.join(columns)}) VALUES")
        out.append(",\n".join("  (" + ", ".join(q(v) for v in r) + ")" for r in chunk) + ";")
    return "\n".join(out)


def seasonal_weight(d):
    """
    Restoration demand is not uniform. Two real drivers on the Front Range:
      * January/February freeze events -> burst pipes -> water losses
      * May through July hail season   -> storm and roof-driven losses
    """
    m = d.month
    base = 1.0
    if m in (1, 2):
        base = 1.65
    elif m in (5, 6, 7):
        base = 1.80
    elif m in (11, 12):
        base = 0.78
    elif m in (3, 4):
        base = 1.10
    return base


def business_days_after(d, n):
    cur = d
    added = 0
    while added < n:
        cur += timedelta(days=1)
        if cur.weekday() < 5:
            added += 1
    return cur


# ---------------------------------------------------------------------------
# Build the reference rows
# ---------------------------------------------------------------------------

sources = []
source_id = 1
for vid, names in SOURCE_NAMES.items():
    for name in names:
        first = START + timedelta(days=RNG.randint(-900, 300))
        sources.append((source_id, name, vid, first, RNG.random() > 0.06))
        source_id += 1

sources_by_vertical = {}
for s in sources:
    sources_by_vertical.setdefault(s[2], []).append(s[0])

# Weighted pool for picking which source a lead came from.
source_pool = []
for s in sources:
    source_pool.extend([s[0]] * VERTICAL_PROFILE[s[2]]["weight"])

vertical_of_source = {s[0]: s[2] for s in sources}

salespeople_by_office = {}
for sp in SALESPEOPLE:
    salespeople_by_office.setdefault(sp[2], []).append(sp)


# ---------------------------------------------------------------------------
# Generate leads
# ---------------------------------------------------------------------------

leads = []
lead_id = 1
day = START
while day <= END:
    # Baseline volume grows as the company grows; Northern Colorado ramps late.
    months_in = (day.year - START.year) * 12 + (day.month - START.month)
    growth = 1.0 + 0.016 * months_in
    expected = 1.55 * growth * seasonal_weight(day)
    if day.weekday() >= 5:
        expected *= 0.35

    n = 0
    while RNG.random() < expected - n and n < 12:
        n += 1
    if expected >= 1 and n == 0:
        n = 1 if RNG.random() < 0.5 else 0

    for _ in range(n):
        office_id = RNG.choices([1, 2, 3], weights=[46, 38, 16])[0]
        if office_id == 3 and day < date(2024, 6, 1) and RNG.random() < 0.5:
            office_id = 1

        sid = RNG.choice(source_pool)
        vid = vertical_of_source[sid]
        profile = VERTICAL_PROFILE[vid]

        received = datetime.combine(
            day, datetime.min.time()
        ) + timedelta(hours=RNG.randint(6, 20), minutes=RNG.randint(0, 59))

        # Response time: the majority same-day, a long tail that is exactly the
        # thing an operations dashboard is built to surface.
        if RNG.random() < 0.72:
            contact_lag_h = RNG.uniform(0.2, 6)
        elif RNG.random() < 0.8:
            contact_lag_h = RNG.uniform(6, 30)
        else:
            contact_lag_h = RNG.uniform(30, 190)
        first_contact = received + timedelta(hours=contact_lag_h)

        # 4% of leads are never contacted at all.
        never_contacted = RNG.random() < 0.04
        if never_contacted:
            first_contact = None

        roster = [s for s in salespeople_by_office[office_id]
                  if s[3] <= day and (s[4] is None or s[4] >= day)]
        salesperson_id = RNG.choice(roster)[0] if roster else None

        lo, hi = profile["size"]
        # Log-normal-ish: many small jobs, a few very large ones.
        est = round(lo * (hi / lo) ** (RNG.random() ** 1.9), 2)

        if vid in (1, 15, 16, 17, 18):
            prop = RNG.choices(["Commercial", "Institutional", "Multifamily"],
                               weights=[60, 28, 12])[0]
        elif vid == 2:
            prop = "Multifamily"
        elif vid == 3:
            prop = RNG.choices(["HOA", "Multifamily"], weights=[82, 18])[0]
        else:
            prop = RNG.choices(PROPERTY_TYPES, weights=[58, 12, 8, 19, 3])[0]

        if day.month in (1, 2):
            loss = RNG.choices(LOSS_TYPES, weights=[54, 8, 9, 6, 18, 5])[0]
        elif day.month in (5, 6, 7):
            loss = RNG.choices(LOSS_TYPES, weights=[26, 7, 38, 5, 19, 5])[0]
        else:
            loss = RNG.choices(LOSS_TYPES, weights=[38, 11, 14, 9, 23, 5])[0]

        # Conversion. Never-contacted leads essentially never close, and slow
        # response materially depresses the close rate -- that relationship is
        # what query 02 is designed to measure.
        close_p = profile["close"]
        if never_contacted:
            close_p *= 0.05
        elif contact_lag_h > 24:
            close_p *= 0.55
        elif contact_lag_h > 6:
            close_p *= 0.82
        if est > 100000:
            close_p *= 0.72

        # Leads received in the last few weeks are still in flight.
        days_old = (END - day).days
        if days_old < 21:
            status = RNG.choices(["New", "Contacted", "Inspected", "Estimated"],
                                 weights=[30, 30, 22, 18])[0]
            won = False
        else:
            won = RNG.random() < close_p
            if won:
                status = "Won"
            else:
                status = RNG.choices(["Lost", "Dead"], weights=[68, 32])[0]

        inspected_on = None
        if status in ("Inspected", "Estimated", "Won") or (
                status in ("Lost", "Dead") and RNG.random() < 0.6):
            if first_contact:
                inspected_on = business_days_after(day, RNG.randint(1, 6))
                if inspected_on > END:
                    inspected_on = None

        lost_reason = RNG.choice(LOST_REASONS) if status in ("Lost", "Dead") else None

        leads.append(dict(
            lead_id=lead_id, office_id=office_id, salesperson_id=salesperson_id,
            source_id=sid, received_at=received, first_contact_at=first_contact,
            inspected_on=inspected_on, loss_type=loss, property_type=prop,
            postal_code=RNG.choice(POSTAL_CODES[office_id]),
            estimated_value=est, status=status, lost_reason=lost_reason,
            _won=won, _day=day,
        ))
        lead_id += 1
    day += timedelta(days=1)


# ---------------------------------------------------------------------------
# Generate jobs, claims, costs, invoices, payments
# ---------------------------------------------------------------------------

jobs, claims, costs, invoices, payments = [], [], [], [], []
job_id = claim_id = invoice_id = 1
cost_id = payment_id = 1

for ld in leads:
    if ld["status"] != "Won":
        continue

    sold_on = business_days_after(ld["_day"], RNG.randint(3, 24))
    if sold_on > END:
        continue

    # Contract lands near the estimate but rarely exactly on it.
    contract = round(float(ld["estimated_value"]) * RNG.uniform(0.86, 1.14), 2)
    contract = max(contract, 750.0)

    is_insurance = RNG.random() < (0.82 if ld["loss_type"] in
                                   ("Water", "Fire", "Storm", "Mold") else 0.34)

    start = business_days_after(sold_on, RNG.randint(1, 15))
    # Duration scales with size: a $4k water mitigation is days, a $150k
    # rebuild is months.
    dur = int(6 + (contract / 1000) ** 0.72 * RNG.uniform(0.8, 1.5))
    completed = start + timedelta(days=dur)

    change_orders = 0.0
    if RNG.random() < 0.38:
        change_orders = round(contract * RNG.uniform(0.03, 0.28), 2)

    if completed > END:
        completed = None
        status = "In Progress" if start <= END else "Sold"
        if start > END:
            start = None
    else:
        status = RNG.choices(["Complete", "Invoiced", "Closed"],
                             weights=[14, 26, 60])[0]

    if RNG.random() < 0.022:
        status = "Cancelled"

    jobs.append(dict(
        job_id=job_id,
        job_number=f"{ld['office_id']}{sold_on.strftime('%y%m')}-{job_id:05d}",
        lead_id=ld["lead_id"], office_id=ld["office_id"],
        salesperson_id=ld["salesperson_id"], sold_on=sold_on,
        work_started_on=start, work_completed_on=completed,
        contract_amount=contract, change_orders=change_orders,
        status=status, is_insurance=is_insurance,
    ))

    total_value = contract + change_orders

    # ---- insurance claim -------------------------------------------------
    if is_insurance and status != "Cancelled":
        carrier = RNG.choice(CARRIERS)
        dol = ld["_day"] - timedelta(days=RNG.randint(0, 5))
        reported = dol + timedelta(days=RNG.randint(0, 4))
        est_sub = business_days_after(sold_on, RNG.randint(2, 18))
        rcv = round(total_value * RNG.uniform(0.94, 1.09), 2)
        depreciation = round(rcv * RNG.uniform(0.06, 0.24), 2)
        acv = round(rcv - depreciation, 2)
        deductible = float(RNG.choice([500, 1000, 1000, 2500, 2500, 5000, 10000]))
        supplements = RNG.choices([0, 1, 2, 3], weights=[46, 32, 16, 6])[0]

        approved = None
        cstatus = "Estimate Submitted"
        if est_sub <= END:
            approve_lag = int(carrier[2] * RNG.uniform(0.55, 1.6)) + supplements * 9
            approved = est_sub + timedelta(days=approve_lag)
            if approved > END:
                approved = None
            elif RNG.random() < 0.045:
                cstatus, approved = "Denied", None
            else:
                cstatus = "Approved"
        else:
            est_sub = None
            cstatus = "Open"

        claims.append(dict(
            claim_id=claim_id, job_id=job_id, carrier_id=carrier[0],
            claim_number=f"{carrier[1][:3].upper()}-{dol.year}-{RNG.randint(100000, 999999)}",
            date_of_loss=dol, reported_on=reported,
            estimate_submitted_on=est_sub, approved_on=approved,
            deductible=deductible, rcv_amount=rcv, acv_amount=acv,
            depreciation_recovered=0.0, supplement_count=supplements,
            status=cstatus,
        ))
        claim_id += 1

    if status == "Cancelled":
        job_id += 1
        continue

    # ---- costs -----------------------------------------------------------
    # Gross margin centres near 34% but varies; large jobs run tighter.
    target_margin = RNG.gauss(0.34, 0.085)
    if total_value > 90000:
        target_margin -= 0.045
    target_margin = min(max(target_margin, 0.02), 0.58)
    total_cost = total_value * (1 - target_margin)

    cost_start = start or sold_on
    cost_end = completed or END
    for category, share in COST_MIX.items():
        amount = total_cost * share * RNG.uniform(0.78, 1.24)
        n_entries = 1 if category in ("Permits", "Other") else RNG.randint(1, 4)
        for _ in range(n_entries):
            span = max((cost_end - cost_start).days, 1)
            costs.append((
                cost_id, job_id, category,
                cost_start + timedelta(days=RNG.randint(0, span)),
                round(amount / n_entries, 2),
                RNG.choice(VENDORS) if category != "Labor" else None,
            ))
            cost_id += 1

    # ---- invoices and payments ------------------------------------------
    if status in ("Invoiced", "Closed") and completed:
        n_inv = 1 if total_value < 25000 else RNG.choice([1, 2, 2, 3])
        remaining = total_value
        for k in range(n_inv):
            amt = round(remaining / (n_inv - k), 2) if k < n_inv - 1 else round(remaining, 2)
            remaining = round(remaining - amt, 2)
            if amt <= 0:
                continue
            issued = completed - timedelta(days=RNG.randint(0, 25) if n_inv > 1 else 0)
            issued = max(issued, start or sold_on)
            terms = RNG.choice([30, 30, 30, 45, 60])
            due = issued + timedelta(days=terms)

            inv_status = "Open"
            invoices.append(dict(
                invoice_id=invoice_id, job_id=job_id,
                invoice_number=f"INV-{issued.strftime('%Y%m')}-{invoice_id:06d}",
                issued_on=issued, due_on=due, amount=amt, status=inv_status,
            ))

            # Collection behaviour. Insurance-funded work pays slower, in
            # pieces, and a real slice ages badly past terms.
            if is_insurance:
                pay_lag = int(RNG.gauss(46, 26))
                payer = RNG.choices(["Carrier", "Mortgage Company", "Homeowner"],
                                    weights=[68, 17, 15])[0]
            else:
                pay_lag = int(RNG.gauss(27, 18))
                payer = RNG.choices(["Homeowner", "Property Manager"],
                                    weights=[58, 42])[0]
            pay_lag = max(pay_lag, 2)

            # Collection outcome depends on how long the invoice has had to be
            # collected. Without this the aging report is nonsense: a random
            # 10% of invoices would sit unpaid forever regardless of age, and
            # the 90+ bucket would swallow most of the receivable.
            age_days = (END - issued).days
            if age_days < 30:
                cuts = (0.24, 0.44, 0.995)     # mostly still in flight
            elif age_days < 60:
                cuts = (0.56, 0.78, 0.995)
            elif age_days < 120:
                cuts = (0.80, 0.93, 0.988)
            else:
                cuts = (0.905, 0.955, 0.984)   # old and still open = a problem

            roll = RNG.random()
            if roll < cuts[0]:           # paid in full
                parts = 1 if RNG.random() < 0.72 else 2
                paid_total = amt
            elif roll < cuts[1]:         # partially paid
                parts = RNG.choice([1, 2])
                paid_total = round(amt * RNG.uniform(0.35, 0.88), 2)
            elif roll < cuts[2]:         # nothing yet
                parts, paid_total = 0, 0.0
            else:                        # written off
                parts, paid_total = 0, 0.0
                invoices[-1]["status"] = "Written Off"

            got = 0.0
            for p in range(parts):
                pay_date = issued + timedelta(days=pay_lag + p * RNG.randint(12, 55))
                if pay_date > END:
                    break
                amount_p = round(paid_total / parts, 2) if p < parts - 1 \
                    else round(paid_total - got, 2)
                if amount_p <= 0:
                    break
                got = round(got + amount_p, 2)
                payments.append((payment_id, invoice_id, pay_date, amount_p, payer,
                                 RNG.choices(["Check", "ACH", "Card", "Wire"],
                                             weights=[52, 33, 9, 6])[0]))
                payment_id += 1

            if invoices[-1]["status"] != "Written Off":
                if got >= amt - 0.01:
                    invoices[-1]["status"] = "Paid"
                elif got > 0:
                    invoices[-1]["status"] = "Partially Paid"

            invoice_id += 1

    job_id += 1


# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------

def main():
    w = sys.stdout.write
    w("-- " + "=" * 74 + "\n")
    w("-- Restoration Contracting Analytics — Seed Data\n")
    w("--\n")
    w("-- GENERATED FILE. Do not edit by hand.\n")
    w("-- Regenerate with:  python3 tools/generate_seed_data.py > sql/02_seed_data.sql\n")
    w("--\n")
    w(f"-- Period covered: {START} through {END}\n")
    w(f"-- {len(leads):,} leads | {len(jobs):,} jobs | {len(claims):,} claims | "
      f"{len(invoices):,} invoices | {len(payments):,} payments\n")
    w("-- " + "=" * 74 + "\n\n")
    w("SET search_path TO restoration, public;\n\n")

    w(insert("offices", ["office_id", "office_name", "city", "state", "opened_on"],
             OFFICES) + "\n\n")
    w(insert("salespeople",
             ["salesperson_id", "full_name", "office_id", "hired_on",
              "terminated_on", "commission_rate"], SALESPEOPLE) + "\n\n")
    w(insert("referral_verticals", ["vertical_id", "vertical_name", "vertical_group"],
             VERTICALS) + "\n\n")
    w(insert("referral_sources",
             ["source_id", "source_name", "vertical_id", "first_referral_on",
              "is_active"], sources) + "\n\n")
    w(insert("carriers", ["carrier_id", "carrier_name", "typical_approval_days"],
             CARRIERS) + "\n\n")

    lead_cols = ["lead_id", "office_id", "salesperson_id", "source_id",
                 "received_at", "first_contact_at", "inspected_on", "loss_type",
                 "property_type", "postal_code", "estimated_value", "status",
                 "lost_reason"]
    w(insert("leads", lead_cols, [[l[c] for c in lead_cols] for l in leads]) + "\n\n")

    job_cols = ["job_id", "job_number", "lead_id", "office_id", "salesperson_id",
                "sold_on", "work_started_on", "work_completed_on",
                "contract_amount", "change_orders", "status", "is_insurance"]
    w(insert("jobs", job_cols, [[j[c] for c in job_cols] for j in jobs]) + "\n\n")

    claim_cols = ["claim_id", "job_id", "carrier_id", "claim_number", "date_of_loss",
                  "reported_on", "estimate_submitted_on", "approved_on", "deductible",
                  "rcv_amount", "acv_amount", "depreciation_recovered",
                  "supplement_count", "status"]
    w(insert("insurance_claims", claim_cols,
             [[c[k] for k in claim_cols] for c in claims]) + "\n\n")

    w(insert("job_costs",
             ["cost_id", "job_id", "cost_category", "incurred_on", "amount",
              "vendor_name"], costs) + "\n\n")

    inv_cols = ["invoice_id", "job_id", "invoice_number", "issued_on", "due_on",
                "amount", "status"]
    w(insert("invoices", inv_cols, [[i[c] for c in inv_cols] for i in invoices]) + "\n\n")

    w(insert("payments",
             ["payment_id", "invoice_id", "received_on", "amount", "payer_type",
              "method"], payments) + "\n\n")

    w("ANALYZE;\n")


if __name__ == "__main__":
    main()
