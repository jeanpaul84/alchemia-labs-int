# AI use on this assessment

> **Completeness note.** The only part 
> summarised rather than
> quoted is the GCP sandbox and service-account setup, for which I hold no
> transcript. Where I am summarising rather than quoting I say so rather than
> inventing a prompt.

## How I worked

I used **Claude Code** (Claude Opus) throughout, on the model that the assistant
writes and I decide. In practice that meant a loop of:

1. I state the goal and the constraint, not the implementation.
2. It proposes; I read every line before it lands.
3. **I make it prove claims against data**, not against its own reasoning.
4. I run the thing — `dbt build`, `pytest`, execute the notebook, look at the
   rendered charts — and treat the output as the source of truth.

The most useful habit I developed was step 3. The assistant is fluent and
confident, which makes plausible-but-wrong output the real risk, not obvious
errors. Almost every problem below was caught by asking *"where does that come
from?"* or by running the thing and looking at it.

---

## Challenges I hit, and how I got past them


### The warehouse emptied itself after every successful load

**Every load job was green, every row count was right, and the tables were
empty.** Nothing in the pipeline's own output said so.

`extract_crm.py` wrote the CRM snapshots partitioned by `snapshot_date`. What
happened is that a BigQuery **sandbox** (no billing account) forces
a 60-day default *partition* expiration onto every dataset and refuses to let
you remove it. The CRM history runs **2025-11-04 → 2026-05-02**. Not one of the
180 snapshot dates falls within 60 days of the current calendar days.

So every partition was **born already expired**. BigQuery accepted the load,
reported `DONE`, wrote the correct rows to the correct table — and then swept
all of them.

| what the pipeline said | what was true |
|---|---|
| `accounts: loaded 18,540 rows` | 8 LOAD jobs, all `DONE`, no errors — genuinely written |
| next run: `180 new snapshot(s)` | `num_rows = 0`; nothing to find, so it reloaded everything |
| `job.output_rows == len(rows)` ✅ | the guard passed, correctly |

That last row is the part worth sitting with. I had added an assertion
specifically to catch *"a load that reports success but writes nothing"* — and
it passed, because the job really did write them. **The guard was aimed one step
too early: it verified the write, not the persistence.**

**How I found it:** not by reading anything. I ran

```sql
select count(distinct snapshot_date) as snapshots, count(*) as row_amounts
from `gin-accounts-recommendation.raw_crm.accounts_snapshots`;
```

and got **0 and 0** against a script that had just printed `loaded 18,540 rows`.
Confirming the cause took two free metadata reads: the job history
(`INFORMATION_SCHEMA.JOBS_BY_PROJECT` — 8 loads, all `DONE`, right destination,
no errors) and `get_table`, which showed `expiration_ms = 5184000000` on all
three tables. Trying to clear it returns `403 billingNotEnabled: Datasets must
have a default expiration time and default partition expiration time of less
than 60 days while in sandbox mode.`

**Solution:** I decided to cluster on `snapshot_date` instead of partitioning by
ingestion time (it was all ingested at once).

---

## Where the assistant was wrong, and how I caught it

### 1. It classified gin by origin when the client competes on price



Claude defined the target category as Iowa's `IMPORTED DRY GINS` +
`IMPORTED GINS`, reasoning that Thameswood is a London producer so its products
are imports. That is true but it is not the same question.

I caught it by reading the client's own product catalogue against the source
taxonomy. Thameswood sells **"London Dry Gin"** and **"Contemporary Gin"**,
those are *styles* of Gins, not origins (London Dry can legally be produced anywhere).
Iowa's taxonomy splits on **origin**; Thameswood competes on **price**. The two
are different axes and the assistant had silently equated them.

So I asked it to price every gin category rather than purely categorize by name. Result,
2021–2026, from the raw public table:

| Iowa category | $/bottle | was classified as |
|---|---|---|
| `IMPORTED DRY GINS` | $25.41 | premium ✅ |
| `FLAVORED GIN` | **$24.89** | **value ❌** |
| `IMPORTED GINS` | $22.13 | premium (dormant — no sales since May 2022) |
| `AMERICAN DRY GINS` | $9.16 | value ✅ |
| `AMERICAN SLOE GINS` | $8.34 | excluded ✅ |

Flavoured gin sells at **98% of imported dry gin's price** and had been binned
as "not our market". It is also the only *growing* gin category in Iowa, and
where Thameswood's own Elderflower Expression (£35, 42% ABV) would be shelved.

After reclassifying,
the market trend inverted:

| | before (origin) | after (price) |
|---|---|---|
| Thameswood's category, 2021→2025 | **−13% — "declining"** | **+2% — flat** |
| Value tier | "flat" | **−21%** |

The notebook had been about to tell the client their category was dying. The
truth is the opposite: the premium tier is holding while the value tier
collapses, and premium spend per stocking store is **up 24%**.


### 3. Store-number missingness (Direction)

I asked about the volume of missing `store_number`s and options for those
accounts. The assistant offered exclusion *or* fuzzy name/address matching as
equally reasonable. I ruled fuzzy matching out of scope given the deadline, and
we went with explicit handling plus documentation.

I also worked out — and confirmed against the data rather than taking its word —
that the missing store numbers were concentrated on **Prospect** accounts rather
than Active ones, which is what made exclusion defensible at the time. In the
final version these accounts are not excluded: they land in **tier 4**.


### 4. It gave me a confident wrong diagnosis before the right one

This is the assistant's half of the empty-warehouse challenge above. Three
attempts at the same bug:

1. I brought it a debugger traceback — `ValueError: Iterator has already
   started` on `rows.pages` inside `loaded_snapshots()` — and asked *"could this
   be it?"* It said no, it explained the re-runs as **interrupted debug
   sessions**, but this was wrong, I didn't stop previous executions.
2. Only when I ran the count and reported **0 and 0** did it stop reasoning from
   the code and go to the job history and the table metadata, where the 60-day
   expiration was sitting in plain sight. It withdrew the interrupted-session
   explanation explicitly rather than letting it stand.


### 5. It pattern-matched a column it had never enumerated (3 August)

The first draft of the market rollup selected gin with
`where upper(category_name) like '%GIN%'`. 

Before running it I pulled `select distinct category_name` — one column, cheap in terms of scan GBs
and checked the pattern against the actual 104 values. `LIKE '%GIN%'` matches
**`PUERTO RICO & VIRGIN ISLANDS RUM`**.

Nothing about that failure is visible from outside: no error, no odd row count,
no null. Every store selling Caribbean rum would have had its "gin volume"
silently inflated, and the ranking would have reshuffled around a number wrong
for a reason nobody would think to look for.

The same enumeration turned up **`FLAVORED GIN` and `FLAVORED GINS` as two
spellings of one category** — a defect a substring match papers over and an
explicit list forces you to confront. That category is used for the ranking itself.

Fixed with an explicit allow-list in `extract/config.py`, the exclusions and
their reasons written beside it, and two tests
(`test_virgin_islands_rum_is_not_matched`, `test_sloe_gin_is_excluded`) so the
decision cannot quietly regress to a `LIKE`.


### 6. Two defects it could not see, found by pasting raw rows at it (3 August)

Claude initially used `ANY_VALUE(store_name)` in order to get (in a sort of
aggregate manner), the store name of a single `store_number` across several
rows. 

After inspecting the Iowa sales original table using the free BigQuery **preview tab**. 
I found an issue with the mentioned approach.

The same `store_number` appears under different names across years:

```
2528   HY-VEE FOOD STORE #3 / DES MOINES          (2021-02-04)
2528   HY-VEE FOOD STORE #3 (1142) / DES MOINES   (2025-03-03)
```

`ANY_VALUE` picks arbitrarily, and BigQuery guarantees nothing about stability
between runs — so the same query could hand back a different store name each
time. For a deliverable that is a list of stores to phone, that is a real
defect, and it would never raise an error. Replaced with
`array_agg(store_name order by date desc limit 1)[offset(0)]`: the most recent
name, deterministically.

**I also noticed that the data contains returns.** Rows whose invoice is prefixed `RINV-` carry
negative bottles and negative dollars. `SUM()`
nets them against purchases, which is defensible, but it was happening by
accident rather than by decision. The rollup now computes net, gross and returns
separately so the choice is explicit and reversible.

### 7. Smaller slip

- The first `dbt build` of the staging layer would not parse. It had written
  `description: One full snapshot ... Grain: account_id x snapshot_date.` into
  `_sources.yml`, and an unquoted colon-space inside a YAML scalar opens a
  nested mapping. dbt rejected the file with a line number; the fix was quotes.

---

## Some of the verifications

- `dbt build` — run to completion after every change (**PASS=74, 65 data tests**).
- `pytest` — **17 passed**.
- The notebook — executed end to end from a clean kernel, every cell, zero errors.
- Every rendered chart, inspected visually, which is how the error in Section 3 was caught.
- The queries from the big table that it suggested I checked by dry-running first.
- **That the raw tables actually contain rows**, counted out of BigQuery rather
  than read off the extract's own success message. This is the check that found
  the emptied warehouse.
- The extract's re-runnability, after the fix: a second run reports `up to date
  (180 snapshots)` for all three feeds and `0 new snapshot(s) loaded`, which is
  the brief's "safe to run more than once" requirement demonstrated rather than
  claimed.
- My own free-tier consumption, from the job history rather than from a feeling
  about it.



---

## How the scope changed mid-way

Recorded because the prompt log below turns on it.

The first working version ranked the **market side**: every Iowa store that
bought gin in the scoring window and was not closed in the CRM. It built, and
its tests passed. What killed it was its own output — none of the top 25 were
accounts Thameswood had any record of, and most of them were individual branches
of national grocery and wholesale chains, which is one central buying decision
rather than a list of calls.

Both observations are real, and neither is a bug. Together, though, they meant
the deliverable was a list of strangers that a small London distiller mostly
cannot approach store by store: a correct answer to the question I had asked,
and the wrong answer to the client's. That is where *"The mart creation has to
be changed"* below comes from. The tiered design, the materiality floor and the
Closed Lost demotion all follow from that rescope.

The choice itself was made on 4 August, on an argument I found persuasive at the
time and would now push back on — §6 covers how it was reached.

---

## Prompts

Verbatim, 3–6 August, in order. Trimmed only where noted.

### 3 August — CRM profiling, the gin categories, the extraction layer

*(This session opened with the framing instruction used throughout — act as a
senior engineer guiding a junior analyst, and explain terms I might not know —
trimmed here as it repeats.)*

> I have some data in bigquery (34M rows, I am in the free account mode of max
> 1tb transfer) about liquor sales and the stores in which the sales are made.
> The user (in this case "Thameswood Distillers Ltd") wants to grow the market
> and approach accounts. The problem is described in @candidate_brief.md . I have
> data of the CRM from several days, does the data
> change at all regarding some primary key or does the data truly change between
> days? If the data doesn't change, then what use is it of the other days' data?
>
> I have noticed that there's a category column in the product_catalogue but it
> mentions things like "London Gin" but I guess that the product category in
> bigquery could be "Irish Gin"
>
> As for the business objective, I was thinking that maybe an "account to
> approach" is one that isn't a client already (seems that account is the synonym
> of client here) and it isn't a client that the distillery "tried" to gain but
> couldn't previously.

*(This was purely the kickstart query of the project.)*


> The 3 duplicated accounts in CRM Accounts (I checked in 2026-05-02) seem to
> have the exact same values as their previous "original" appearances (you
> mentioned about the trailing space in account_name) Are they directly droppable
> duplicates? […] How would this be used for ranking? Is this a conversation to
> be held right now or later? […] Do I initially need to map this? […] Remember
> that Today is Tuesday and this is Due Thursday so I need to map out and deliver
> an MVP. […] As of the store_number being null on
> 40 rows and around the 40% (it should be the 40% after deleting duplicates,
> right?). I will need to analyze a possible exclusion here due to data nature and time (trying to fuzzy match with
> this short deadline could be a bad approach considering that the rest isn't
> done yet). […] Map out next steps

> As for the SELECT DISTINCT category_name, I got the results in
> @data/bq-results-distinct-category_name.csv It seems that there is a match with
> "GIN" also with "VIRGIN" and there's "FLAVORED GINS" and "FLAVORED GIN". I
> extracted @gins-categories.md but don't use that as the final source of truth
> for extracting gin-like categories.
>
> Regarding the big-rollup, when I paste it into the BigQuery Console I get:
> `Not found: Dataset gin-accounts-recommendation:raw_iowa was not found in
> location US`

*(I ran the enumeration before trusting the `LIKE '%GIN%'` it had
written, and the false positive was mine to find.)*

> Verify that what I extracted in the @gins-categories.md is the thorough list of
> gin-related categories that is in the csv
> @data/bq-results-distinct-category_name.csv

> The big rollup costs 3.6 GB. I was able to pull some rows from the preview tab
> (unrelated to the query or amount I just mentioned): [~180 rows of the sales
> table pasted in full]

*(This is §9 — the paste it did not ask for, which found the non-deterministic
`ANY_VALUE` and the `RINV-` return rows.)*

> It'll now be 4.17 GB, Is the Address, city, county and zip code really needed?
> Also I am being cautious towards the 1 tb because won't the upload of GCS to
> BigQuery count towards that? And won't I need to test my pipeline several
> times?

> As this should be a pipeline as per @candidate_brief.md , should it be in my
> current Python project Also regarding the loader, give me the plan of how it
> will be and what it will do, where, how and why it makes sense.

> Shouldn't I add this into .env? `export GOOGLE_APPLICATION_CREDENTIALS=…` […]
> Also, I will start with the extract_market execution and then move onto the crm
> extraction execution and code understanding

> I ran extract_market and understood it. Now let's move to extract_crm,
> understanding it and next steps

*(The session ends with the `0 and 0` report quoted in the next block — the same
conversation, continued after the extract had run.)*

### 4 August, early — the empty warehouse

> I get this error when trying to run the @extract/extract_crm.py through vscode
> debugging
>
> `Exception has occurred: ModuleNotFoundError` / `No module named 'extract'` …

> When debugging in vscode why @extract/extract_crm.py executed completely even
> after just executing it previously, I found that the rows.pages in
> loaded_snapshots() has this
>
> `ValueError: ('Iterator has already started', <google.cloud.bigquery.table.RowIterator object …>)`
>
> Could this be it?


> how can I know how much billing per query I already have wasted?


> that get_table won't waste space out of my free 1tb right?


> The prints out of @extract/extract_crm.py seem to print out well and seem to
> be saying that it is inserting, but after it finishes, I try to re-run it and
> it runs everything again. But when I run I get 0 and 0
>
> ```sql
> select count(distinct snapshot_date) as snapshots, count(*) as row_amounts
> from `gin-accounts-recommendation.raw_crm.accounts_snapshots`;
> ```

*(This is the prompt that solved it.)*

### 4 August — raw-layer review, staging build, the snapshot question

*(This session also opened with the framing instruction described above — act as
a senior engineer guiding a junior analyst, and explain terms I might not know —
trimmed here as it repeats.)*

> I have some data in bigquery (34M rows, I am in the free account mode of max
> 1tb transfer) about liquor sales and the stores in which the sales are made.
> The user (in this case "Thameswood Distillers Ltd") wants to grow the market
> and approach accounts. The problem is described in @candidate_brief.md . I
> have created, run and verified @extract/extract_market.py and
> @extract/extract_crm.py . These files are getting the data from GCS, or
> aggregating the 34M-row table into my project's dataset tables. Now that I
> have my raw data, I need to proceed with the assessment. Confirm my knowledge
> and description up until now.

> Also, regarding elegibility, I want to go with B if doable for the deadline.
> That is sort of the same as C but without the source column, so I technically
> want B but with the source column described in C. Let's move forward with the
> next step, which you mention that is staging

> shouldn't I use snapshots/ in dbt for my incremental tables of crm?

### 5 August — staging review, mart design, first (market-side) notebook

*(The first prompt also carried a framing instruction — act as a senior engineer
guiding a junior analyst, and explain terms I might not know — trimmed here.)*

> I have some data in bigquery (34M rows, I am in the free account mode of max
> 1tb transfer) about liquor sales and the stores in which the sales are made.
> The user (in this case "Thameswood Distillers Ltd") wants to grow the market
> and approach accounts. The problem is described in @candidate_brief.md . I
> have created the dbt transform part of the staging (middle section). Explain
> what all files do and why they do what they do, why it makes sense.

> Yes I want us to sketch out the mart layer next.
>
> About the candidate universes: I think that the universe should be all of the
> gin-selling stores in Iowa which aren't closed in the CRM.
>
> The ranking should take into consideration: net_sale_dollars, cat_group

> About the month grain, can't we use 2025 and 2026 data initially? As a first
> version and then I can add the month grain if time allows?
>
> Closed Lost is meant to be excluded on purpose. Re-writing or revisiting a
> store that already said no seems time consuming and we already have a "bad
> past" with them.
>
> No more features for now for the mix, in fact, let's create a first version
> where it only takes into consideration the sales of the stores and work
> upwards from there.
>
> Also, if this calculation is being done here, what is meant to be put in the
> notebook?

> Let's start the notebook with what's there now, for a baseline of that version
> as well.

*(My position on Closed Lost reverses between here and the next block — excluded
above, kept and demoted below. The change was deliberate and the final build
follows the later decision; I have left both in rather than tidy the earlier one
away.)*

### 6 August — rescope to CRM accounts, category change, final ranking

> The mart creation has to be changed. The candidates need to be only accounts
> that are already in the CRM of the client, accounts that are not in the CRM
> are out of the scope for this project

*(in response to it asking how to close the 19-vs-25 gap)*

> I want a mix of these two: [tiered matched-accounts option] And [all
> non-closed-won] — please note that Closed Lost are still in the mix, I would
> assign them a lower "weight" since it will be harder than a cold approach, we
> have a "negative" past with them. I would rank the ones that we *do* have
> match with the market as more reliable than those ones that we don't. So
> higher.

> Let's add a materiality floor threshold of $600

> Seeing the product catalogue of Thameswood, they produce London Dry Gin (which
> I read that doesn't necessarily come from London, it's just a type of Gin) and
> they produce Contemporary Gin, don't both categories fit into "GIN_OTHER" and
> "GIN_PREMIUM", also does the classification make sense as is it is now? Cause
> its taking into consideration as if Thameswood was imported gin here, right?

> You mention that Thameswood distils in London, but where is that assertion
> made? Like where did you read that?


> Let's move flavored gins into gin_premium.
>
> I think the naming convention of gin_premium and gin_other is fine, let's keep
> it that way.
>
> Did you also compare the "FLAVORED GIN" category's price? In order to see if
> that needs to be included in GIN_PREMIUM, the end goal is for that category to
> truly resemble "expensive" or premium gin pricing category.

> Let's rebuild the notebook

> The tier label of 1 says "1 buys imported gin at scale (>= $600)", this should
> be "buys premium gin at scale" since it now includes flavored gin that is not
> necessarily imported. Same fix for the second label.

> Undo the replacement and do it "manually"

### Not covered by a transcript

The **GCP sandbox and service-account setup** — creating the project, the
service account, the key and the three US datasets — I did from Google's own
documentation rather than with the assistant, so there are no prompts to quote.
Everything else in the project is in the log above.
