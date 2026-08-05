# Alchemia Labs — Technical Assessment
## Revenue-Ops & GTM Data Engineering

Thanks for continuing with us. This is a practical exercise that mirrors the work we actually
do: joining third-party market intelligence to a client's first-party CRM data to drive
go-to-market targeting. We're less interested in a perfect answer than in how you think, how
you engineer, and how you communicate what you built.

---

## The scenario

**Thameswood Distillers Ltd** is a small London gin producer with an established book of
business selling into liquor stores in Iowa. They want to grow that market and need to know
**which accounts to approach next**.

To help, Alchemia Labs has purchased a third-party dataset covering **all wholesale liquor purchases
by Iowa retailers** — it's already available to you in BigQuery. The client also sends us
**nightly exports of their CRM** (accounts, opportunities, contacts) plus their **product
catalogue**.

Neither source answers the question on its own. Your job is to integrate them and produce a
**ranked list of target accounts** the client can act on.

---

## What you're given

1. **The market dataset** — `bigquery-public-data.iowa_liquor_sales.sales`, a public BigQuery
   dataset. Any BigQuery project has read access to it by default.
2. **The client's CRM data** — a Google Cloud Storage bucket you can list and download from:
   **`gs://alchemialabs-tech-assessment`**
   It contains the client's nightly CRM exports and their product catalogue. Have a look at
   what's in there. (It's publicly readable — `gsutil ls gs://alchemialabs-tech-assessment/`,
   or the standard GCS HTTP API, both work with no credentials.)

---

## Your environment

You'll work in **your own** Google Cloud project — we don't provision anything for you.

- Create a **free BigQuery sandbox project** (no billing account, no credit card): 10 GB
  storage and 1 TB of query processing per month, not time-limited. Creating the project, a
  service account, and working credentials is part of the exercise.
- Google Cloud's own documentation walks through the sandbox and service-account setup end to
  end — standing that up is yours to do, and it's part of what we're looking at.

---

## What to build (deliverables)

1. **A repository** — start a fresh one under your own GitHub account. Extraction code for both
   sources, your transformation layer, and tests. Share it (make it public, or invite
   `friscian.viales@alchemialabs.com`).
2. **A modelled data warehouse** in your own BigQuery project. When it's ready, grant
   **BigQuery Data Viewer** & **BigQuery Job User** on your final modelled dataset to:
   **`local-dev@alchemialabs-sbx.iam.gserviceaccount.com`**
   (so we can review your work directly). Doing that grant is a small part of the exercise too.
3. **The ranked list.** The 25 Iowa accounts the client should approach next, ranked, **with the
   reasoning behind the ranking**. Format is yours — a dashboard, an app, a notebook, a
   one-pager. We care about whether we'd act on it.
4. **An assumptions page** (one page). What you assumed, what you'd ask us if you could, and
   what you'd do differently with more time.
5. **Full documentation of your AI use.** We use AI-assisted development here and expect you to —
   this is about how you *direct and verify* it, not whether you use it. Document it properly:
   how you used AI across the task, the challenges you hit and how you overcame them, and the
   prompts you used (include them). We're especially interested in where the assistant was wrong
   and how you caught and corrected it.

---

## Recommendations

- **We use [dbt](https://github.com/dbt-labs/dbt-core) on BigQuery** for our client transformation layers, and we'd suggest it here.
  You're welcome to use it. If you'd rather do the transforms another way, that's fine — just
  tell us why in your README.
- **We'd recommend Claude Code if you can** — a Claude Pro plan is **$20/month** and includes it.
  If that's not an option, use whatever AI tool is available to you (Codex, a plain chat
  interface — whatever you're most productive in). Either way, AI-assisted development is expected,
  and either way we still expect the AI-use documentation described in deliverable 5 above.
- **Treat the extraction like a pipeline**, not a one-off copy: something re-runnable and safe
  to run more than once — each run should pull only what's new. If you take a different
  approach, be ready to talk us through the tradeoff.
- **Mind your query costs.** The market table is large; the free tier's 1 TB/month is a real
  budget. Filtering and pruning are good habits — this rewards them.
- **When something is ambiguous, use your judgement and write it down** (that's what the
  assumptions page is for) — or just ask us.
- **We're not looking for exhaustiveness.** A smaller, correct, well-reasoned submission beats a
  large, shaky one. There's no time limit — spend the time you feel it deserves — just meet the
  deadline below.

---

## Timeline

| Milestone                                                           | When                          |
|---------------------------------------------------------------------|-------------------------------|
| Brief sent — please **acknowledge receipt**                         | Monday 3 August               |
| **Submission due** (repo shared + BQ access granted + deliverables) | Thursday 6 August, end of day |
| **Walkthrough call** (60 min — we'll book a slot)                   | Friday 7 August               |

On the call you'll walk us through your own code and make a small live change to it. Come ready
to talk through your decisions, not just the result.

---

## Going further (bonus — welcome, but not a substitute)

Anything beyond the ranked list is genuinely welcome and counts in your favour — for example:

- a working app or dashboard,
- generated outreach drafts,
- an agent that enriches your top accounts,
- a polished front end.

It's a bonus **on top of** a solid foundation, not a replacement for one.

---

**One more time:** a correct, honest, well-explained result is exactly what we're
looking for. We're excited to see how you approach it — good luck.

*Questions? Reply to `friscian.viales@alchemialabs.com`.*
