"""Extract: Iowa liquor sales (public BigQuery) -> raw_iowa.store_category_yearly.

Aggregates 34M order lines down to one row per store / year / category group.
This is the only query in the project that touches the large public table, so it
runs behind two guards:

  1. a dry run that refuses to proceed above MAX_QUERY_BYTES
  2. a skip-if-already-built check, overridable with --force

Reproducible does not mean "re-runs blindly" -- it means anyone can re-derive
the table from this file.

Usage:
    python -m extract.extract_market              # build if missing
    python -m extract.extract_market --force      # rebuild
    python -m extract.extract_market --estimate   # print cost, run nothing
"""

import argparse
import sys

from google.cloud import bigquery
from google.cloud.exceptions import NotFound

from extract import config


def _sql_list(values) -> str:
    """Render a Python sequence as a SQL IN-list literal."""
    return ", ".join(f"'{v}'" for v in values)


def build_sql() -> str:
    """The rollup query, with the category lists injected from config."""
    alias_whens = "\n        ".join(
        f"when '{src}' then '{dst}'"
        for src, dst in config.GIN_CATEGORY_ALIASES.items()
    )
    return f"""
create or replace table
  `{config.PROJECT_ID}.{config.RAW_IOWA_DATASET}.{config.MARKET_TABLE}`
-- Clustered on the join key to the CRM. Not partitioned: the result is only
-- tens of thousands of rows, and partitioning that adds metadata overhead
-- without buying anything.
cluster by store_number
as
select
  store_number,

  -- Store attributes drift: the same store_number appears under different
  -- names across years. ANY_VALUE would pick arbitrarily and is not guaranteed
  -- stable between runs, so take the most recent value explicitly.
  array_agg(store_name order by date desc limit 1)[offset(0)] as store_name,
  array_agg(address    order by date desc limit 1)[offset(0)] as address,
  array_agg(city       order by date desc limit 1)[offset(0)] as city,
  array_agg(county     order by date desc limit 1)[offset(0)] as county,

  extract(year from date) as year,

  case
    when trim(upper(category_name)) in ({_sql_list(config.GIN_PREMIUM_CATEGORIES)})
      then 'GIN_PREMIUM'
    when trim(upper(category_name)) in ({_sql_list(config.GIN_OTHER_CATEGORIES)})
      then 'GIN_OTHER'
    else 'NON_GIN'
  end as cat_group,

  -- Keep the specific gin category so we can drill in later without paying for
  -- another scan of the source table. Null for non-gin rows.
  case
    when trim(upper(category_name)) in ({_sql_list(config.gin_categories())})
      then case trim(upper(category_name))
        {alias_whens}
        else trim(upper(category_name))
      end
  end as gin_category,

  -- Rows whose invoice is prefixed RINV- are returns: negative bottles and
  -- negative dollars. Net is what the store actually retained, so that is the
  -- headline measure; gross and returns are kept for sensitivity checks.
  sum(sale_dollars)                          as net_sale_dollars,
  sum(if(bottles_sold > 0, sale_dollars, 0)) as gross_sale_dollars,
  sum(if(bottles_sold < 0, sale_dollars, 0)) as returns_dollars,
  sum(volume_sold_liters)                    as net_volume_liters,
  sum(bottles_sold)                          as net_bottles,
  countif(bottles_sold < 0)                  as return_lines,
  count(*)                                   as order_lines,
  max(date)                                  as last_purchase_date

from `{config.SALES_TABLE}`
where date >= '{config.MARKET_START_DATE}'
group by store_number, year, cat_group, gin_category
"""


def estimate_bytes(client: bigquery.Client, sql: str) -> int:
    """Cost of the query without running it. Dry runs are free and instant."""
    job = client.query(
        sql,
        job_config=bigquery.QueryJobConfig(dry_run=True, use_query_cache=False),
    )
    return job.total_bytes_processed


def check_cost(estimated_bytes: int, ceiling: int = config.MAX_QUERY_BYTES) -> None:
    """Refuse to run a query that would scan more than the ceiling.

    Catches an accidental SELECT * or a dropped WHERE clause before it costs
    anything. Pure function so it can be tested without touching BigQuery.
    """
    if estimated_bytes > ceiling:
        raise RuntimeError(
            f"Refusing to run: would scan {estimated_bytes / 1024**3:.2f} GB, "
            f"ceiling is {ceiling / 1024**3:.2f} GB. "
            f"Raise MAX_QUERY_BYTES in extract/config.py if this is intentional."
        )


def table_exists(client: bigquery.Client, table_id: str) -> bool:
    """Metadata lookup -- free, does not scan the table."""
    try:
        client.get_table(table_id)
        return True
    except NotFound:
        return False


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--force", action="store_true", help="rebuild even if the table exists"
    )
    parser.add_argument(
        "--estimate", action="store_true", help="print the cost estimate and exit"
    )
    args = parser.parse_args(argv)

    client = bigquery.Client(project=config.PROJECT_ID, location=config.LOCATION)
    table_id = (
        f"{config.PROJECT_ID}.{config.RAW_IOWA_DATASET}.{config.MARKET_TABLE}"
    )
    sql = build_sql()

    estimated = estimate_bytes(client, sql)
    print(f"Estimated scan: {estimated / 1024**3:.2f} GB")

    if args.estimate:
        return 0

    check_cost(estimated)

    if table_exists(client, table_id) and not args.force:
        print(f"{table_id} already exists -- skipping. Use --force to rebuild.")
        return 0

    print(f"Building {table_id} ...")
    job = client.query(sql)
    job.result()  # block until the job finishes

    table = client.get_table(table_id)
    print(
        f"Done. {table.num_rows:,} rows, "
        f"{job.total_bytes_processed / 1024**3:.2f} GB scanned."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
