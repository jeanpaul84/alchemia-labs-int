# Assumptions — Thameswood Iowa target accounts

CRM snapshot **2026-05-02**; market window **Jan 2025 – Apr 2026**. Every lever below is a `var`
in `transform/dbt_project.yml` or a list in `extract/config.py` — all reversible without editing SQL.

### What I assumed

| | Assumption | Why, and what it costs |
|---|---|---|
| 1 | **The CRM is the universe; the market data only scores it.** | I initially took the approach of the other way around, after confirmation with Friscian, it was decided that the focus of this exercise was to scope only the non-closed-won accounts that are present in the CRM. |
| 2 | **Closed Won excluded (15). Closed Lost kept but demoted (8).** | Won accounts are customers; nothing to approach. A previous loss is harder work than a live prospect but not worthless, one that demonstrably buys premium gin still beats an open prospect that buys none, deprioritized. |
| 3 | **"Premium gin" is a price tier, not an origin.** | Iowa's `category_name` splits on origin; Thameswood competes on price. I measured $/bottle rather than trusting the label: `IMPORTED DRY GINS` $25.41, `FLAVORED GIN(S)` $24.89, `IMPORTED GINS` $22.13 → premium; `AMERICAN DRY GINS` $9.16 → value; `AMERICAN SLOE GINS` $8.34 → excluded (after research, I excluded this category because its not comparable to a *London Dry Gin*). **Bimodal at ~$25 vs ~$9 with nothing between**, so the boundary is a feature of the market. Flavoured gin is also Iowa's only *growing* gin category. Matched by explicit list, never `LIKE '%GIN%'` — that also catches `PUERTO RICO & VIRGIN ISLANDS RUM`. Gift pack categories are not counted towards Gin sells. |
| 4 | **A 16-month window, and it is not a trend.** | The *same* 16 months are taken for every store, which is what makes it fair to rank on (equal time grounds). If a YoY comparison is wanted in the future then additional monthly grain has to be extracted. |
| 5 | **A \$600 materiality floor guards tier 1.** | Without it, \$65 of premium gin (two bottles) outranks \$1,800 of gin purely on category. It is important to mention that this is a threshold that I picked purely based on data exploration. Sub-floor accounts fall to tier 2, never out. |
| 6 | **Ranking is a tiered ordinal sort, not a weighted score.** | `evidence_tier` → `relationship_penalty` → `tier_measure` → `open_pipeline_gbp`. Because tier sorts first, dollars are only ever compared like-for-like. A score of 0.73 is harder to explain non-technically. |
| 7 | **Nightly CRM files are full snapshots, not deltas.** | Nothing is inserted or deleted between them, attributes drift "silently" between files. So every snapshot is kept and one model (`int_crm__accounts_current`) decides what "now" means. For this model it increases the used storage slightly. |
| 8 | **Data-handling calls**, each guarded by a test. | 3 accounts are duplicated in *every* snapshot (the difference is trailing whitespace only), from these only 1 is kept. `store_number` is STRING on both sides; a STRING/INT64 key is the quietest way to get zero rows and no error. Dates are day-first in some columns, ISO in others, in the same file. `RINV-` returns net off. The decision of keeping `store_number` as a STRING is intentional, no arithmetic is meant to be operated over this column (it just identifies). |
| 9 | Currently, **store-number** cannot be obtained. | If the number could be obtained then it would be stored in the CRM data but it isn't so I built around that. This is a data-missing problem, not a ranking one. |
| 10 | Previous losses are counted as **more work to be done**. | Penalized. A cold or warm approach is easier to perform than one that went badly in the past. |
| 11 | There is **no minimum viable order size**. | Thameswood Distillers is looking to expand its business, all opportunities that bring company grow are on the table. |
| 12 | **value_gbp** is deal kickstarter money. | **value_gbp** is money Thameswood will receive as a deal kickstarter. |


### What I would do differently with more time

1. **Fix the match rate before touching the model.** 47 of 85 accounts (55%) cannot be scored — **40 carry no `store_number`**, 7 carry one absent from the market data. Populating that field moves them up the ladder *immediately, with no model change* and real-performance data of those accounts can be studied. If these values can't be obtained at all, an approach would be to use fuzzy matching (or use AI to match them using context and similarity).
2. **Run YoY comparisons additionally.** This way stores can be compared across time with a monthly granularity. Even QoQ comparisons could be extracted.
3. **Make the floor empirical** — a natural break or a percentile of stocking stores, instead of a round figure.
4. **Create a Power BI dashboard:** rather than delivering an unpolished dashboard, I focused on correctly finalizing the notebook and logic.
