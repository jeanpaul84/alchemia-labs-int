# Thameswood Distillers — Iowa target accounts

Which accounts should Thameswood Distillers Ltd approach next in Iowa, and why.

The client's CRM knows who they talk to but not who buys gin. The Iowa public
liquor dataset knows who buys gin but not who the client talks to. This repo
joins the two and produces a **ranked, reasoned list of 25 accounts**.

**The deliverable is [`notebooks/01_target_accounts.ipynb`](notebooks/01_target_accounts.ipynb)** —
open it and read section 1. Everything else here is how it gets built.

The judgement calls behind it are in **[`ASSUMPTIONS.md`](ASSUMPTIONS.md)**
([PDF](ASSUMPTIONS.pdf)), and the AI-use write-up is in
**[`ai-usage.md`](ai-usage.md)**.

---

## The answer

- **85 accounts are approachable** — the whole CRM except the 15 already Closed Won.
- **Only 6 clear the evidence bar.** Ranks 7–25 are the best of what remains. The
  client's book does not contain 25 strong candidates, and the notebook says so.
- **47 of 85 cannot be matched to the market data at all** — 40 carry no
  `store_number`. Fixing that is worth more than any modelling change.
- **The category is premiumising, not dying.** Premium-tier gin dollars are flat
  since 2021 while the value tier fell 21%, and premium spend *per stocking
  store* is up 24%.

---

## Running it

```bash
python -m venv .venv && .venv/bin/pip install -r requirements.txt

cp .env.example .env      # point it at your own project + service-account key
source .env

bash scripts/create-datasets-raw.txt        # raw_iowa, raw_crm, analytics (US)

python -m extract.extract_crm               # GCS -> raw_crm.*      (incremental)
python -m extract.extract_market            # public BQ -> raw_iowa.* (guarded)

dbt deps  --project-dir transform --profiles-dir transform
dbt build --project-dir transform --profiles-dir transform

pytest                                      # extract-layer unit tests
```

Then run the notebook top to bottom. It reads only from `analytics`, so it is
cheap and needs no access to the 34M-row public table.

Current state of a clean run:

| | |
|---|---|
| `dbt build` | **PASS=74** — 1 table, 8 views, **65 data tests**, 0 errors |
| `pytest` | **17 passed** |
| `mart_target_accounts` | 85 rows, one per account |
| Market rollup | 31,011 rows from 34M, 3.92 GB scanned |

---

## Layout

```
extract/     config.py          the gin-category decision + all project settings
             extract_crm.py     GCS nightly CRM snapshots -> raw_crm.*
             extract_market.py  Iowa public dataset -> raw_iowa.store_category_yearly
transform/   dbt project        staging -> intermediate -> marts
notebooks/   01_target_accounts.ipynb   <- THE DELIVERABLE
tests/       test_extract.py    pytest over the extraction layer's pure logic
scripts/     dataset creation commands
data/        local copies of the source files, for inspection only
```

Lineage:

```
raw_crm.*   ─┐
             ├─ stg_* (clean/type) ─ int_* (current state, pivot) ─ mart_target_accounts
raw_iowa.*  ─┘                                                       85 rows, 1 per account
```

---

## Design decisions

### The universe is the CRM, not the market

`mart_target_accounts` reads **from** the CRM and joins market data **onto** it.
Iowa stores with no CRM record are out of scope: the market data *scores*
accounts, it does not *supply* them.

This is enforced, not just intended — `account_id` carries a `relationships`
test back to `int_crm__accounts_current`, so nothing can enter the ranked list
that is not already an account the client holds.

### Ranking is a tiered ordinal sort, not a weighted score

Nothing is multiplied by a coefficient anyone has to defend. Four keys in order:

1. **`evidence_tier`** — what the market data proves. `1` buys premium-tier gin
   at scale · `2` gin demand below the floor · `3` no gin traction · `4` no
   market match.
2. **`relationship_penalty`** — a Closed Lost account sits at the bottom of its
   own tier. Demoted, never deleted: a lost account that demonstrably buys
   premium gin still beats a live prospect that buys none.
3. **`tier_measure`** — the dollar measure for that tier. Because tier sorts
   first, this is only ever compared **like for like**.
4. **`open_pipeline_gbp`**, then `account_id` — decides tier 4, and makes the
   order reproducible run to run.

Every business lever lives in `dbt_project.yml` as a `var`, not buried in SQL:
`market_window_years`, `exclude_closed_lost`, `demote_closed_lost`,
`premium_gin_materiality_floor`, `target_list_size`.

### "Premium" is a price tier, not an origin

Iowa's `category_name` classifies gin by origin (`IMPORTED…` vs `AMERICAN…`).
Thameswood competes on price. Taking Iowa's wording at face value is a trap, so
the boundary was set by **measuring dollars per bottle** (2021–2026):

| Iowa category | $/bottle | group |
|---|---|---|
| `IMPORTED DRY GINS` | $25.41 | GIN_PREMIUM |
| `FLAVORED GIN(S)` | **$24.89** | GIN_PREMIUM |
| `IMPORTED GINS` | $22.13 | GIN_PREMIUM (dormant — no sales since May 2022) |
| `AMERICAN DRY GINS` | $9.16 | GIN_OTHER |
| `AMERICAN SLOE GINS` | $8.34 | excluded — a ~15–25% ABV liqueur |

The split is **bimodal at ~$25 vs ~$9 with nothing in between**, so the boundary
is a feature of the market rather than a judgement call. Flavoured gin sits in
the premium tier despite not being "imported" — it is also the only growing gin
category in Iowa, and where Thameswood's own Elderflower Expression would shelf.

`PUERTO RICO & VIRGIN ISLANDS RUM` is why the code uses an explicit category
list and never `LIKE '%GIN%'`. There is a test for that.

### A $600 materiality floor guards tier 1

Without it, an account that bought $65 of premium gin in sixteen months — two
bottles — outranks one moving $1,800 of gin, purely because the $65 landed in
the right category. Sub-floor accounts fall to tier 2; they are never dropped.

### Cost control

The free sandbox allows 1 TB/month and the source table is 34M rows.

- `extract_market.py` **dry-runs every query first** and refuses to execute
  above `MAX_QUERY_BYTES` (10 GB). The real rollup scans 3.92 GB.
- It aggregates 34M order lines to 31,011 rows **once**. Nothing downstream ever
  touches the public table again — the notebook's queries hit tables of 85 and
  31k rows.
- It skips if the table exists; `--force` rebuilds, `--estimate` prices without
  running.

### Re-runnable, not a one-off copy

`extract_crm.py` keeps its state **in the warehouse, not a manifest file**: each
run asks the destination table which `snapshot_date`s it already holds and loads
only the gap. A run that dies halfway leaves the next run able to work out
exactly what is outstanding. Re-running is always safe.

Every source column loads as `STRING`. The CSVs mix `"GBP 76,503.29"`,
`dd/mm/yyyy` and ISO dates, and empty strings; autodetection guesses wrong and
can guess *differently on different files*. A byte-faithful raw layer means
ingestion never fails on a data-quality problem — it surfaces downstream as a
failing dbt test instead. Parsing happens in `transform/macros/parsing.sql` and
is asserted by singular tests.

---

## Testing

**65 dbt data tests.** Beyond the usual uniqueness/not-null/accepted-values,
four singular tests guard the things that would otherwise fail *silently*:

| test | what it catches |
|---|---|
| `assert_no_closed_accounts_in_targets` | a broken universe filter — output still looks like a perfect ranked list, but it is people who already buy. Asserted against the CRM directly, not trusted from the `WHERE` clause. |
| `assert_closed_lost_demoted` | one misplaced `ORDER BY` key silently promoting previously-lost accounts back up the list |
| `assert_account_duplicates_agree` | three accounts are double-listed in *every* snapshot; left in, they fan out every downstream join |
| `assert_crm_dates_parse` / `assert_gbp_amounts_parse` | mixed date formats and GBP strings failing to parse into NULL |

**17 pytest tests** over the extraction layer's pure logic — filename parsing,
the incremental set arithmetic, the cost guard, and the gin-category decision.
No BigQuery or GCS connection needed to run them.

---

## Known weaknesses

Written up properly in **[`ASSUMPTIONS.md`](ASSUMPTIONS.md)** and section 7 of
the notebook. The short version:

1. The book does not contain 25 strong candidates — six clear the floor.
2. 47 accounts cannot be scored at all (a CRM data gap, not a modelling flaw).
3. No momentum or recency signal — both need the market extract re-run at month
   grain, since calendar years cannot express a trailing twelve months.
4. The $600 floor is my human-stated threshold, not written in stone.

---

## Notes

- Transforms are **dbt on BigQuery**, as recommended.
- **Reviewer access is granted.** `local-dev@alchemialabs-sbx.iam.gserviceaccount.com`
  has `READER` (BigQuery Data Viewer) on the **`analytics` dataset**, and
  `roles/bigquery.jobUser` on the **project**. The brief asks for both on the
  dataset; Job User cannot go there — `bigquery.jobs.create` is a project-scoped
  permission and a dataset ACL only accepts dataset-scoped roles. It carries no
  data-read permission of any kind, so `raw_crm` and `raw_iowa` stay private:
  read access is scoped to `analytics` alone.
- All datasets are in the **US multi-region** — BigQuery cannot join across
  locations, and the public Iowa dataset lives there.
- Raw CRM tables are **clustered, not partitioned**, on `snapshot_date`. A
  sandbox project forces a 60-day partition expiry that cannot be removed, and
  every snapshot here is 94–273 days old — date partitions would be born already
  expired and swept away moments after a load reported success.
- AI-assisted development is documented in [`ai-usage.md`](ai-usage.md).
