"""Single source of truth for project settings and the gin category decision.

Both extract scripts and the documentation read from here, so the "which Iowa
categories count as gin" judgement lives in exactly one place.
"""

import os

# --- GCP -------------------------------------------------------------------

PROJECT_ID = os.environ.get("BQ_PROJECT_ID", "gin-accounts-recommendation")

# The public source dataset lives in the US multi-region. BigQuery cannot query
# across locations, so every dataset we create must be US too.
LOCATION = "US"

RAW_CRM_DATASET = "raw_crm"
RAW_IOWA_DATASET = "raw_iowa"

# --- Sources ---------------------------------------------------------------

CRM_BUCKET = "alchemialabs-tech-assessment"
CRM_FEEDS = ("accounts", "contacts", "opportunities")
PRODUCT_CATALOGUE_OBJECT = "product_catalogue.parquet"

SALES_TABLE = "bigquery-public-data.iowa_liquor_sales.sales"
MARKET_TABLE = "store_category_yearly"

# The public table starts in 2012. Five years of history is plenty for a trend
# signal and keeps the aggregate small.
MARKET_START_DATE = "2021-01-01"

# --- Cost guard ------------------------------------------------------------

# The free sandbox allows 1 TB of query processing per month. The market rollup
# scans ~4 GB; this ceiling exists to catch an accidental SELECT * or a dropped
# WHERE clause before it runs, not to constrain normal use.
MAX_QUERY_BYTES = 10 * 1024**3  # 10 GB

# --- The gin category decision --------------------------------------------
#
# Iowa's `category_name` is the state's own taxonomy of everything retailers
# buy. Thameswood's catalogue uses its own vocabulary ("London Dry Gin",
# "Contemporary Gin"), so the two do not join -- we map Iowa's categories onto
# Thameswood's competitive set by hand.
#
# Verified against SELECT DISTINCT category_name (104 values, of which 7 contain
# the substring "GIN"). Do NOT use LIKE '%GIN%': it matches
# "PUERTO RICO & VIRGIN ISLANDS RUM".

# Imported gin -- Thameswood's actual shelf. A store already moving these has
# proven it can sell a GBP 35 bottle. This is the *fit* signal.
GIN_PREMIUM_CATEGORIES = (
    "IMPORTED DRY GINS",
    "IMPORTED GINS",
)

# Domestic and flavoured gin -- real gin demand, but mostly value tier. Useful
# for sizing total gin appetite. This is the *market size* signal.
GIN_OTHER_CATEGORIES = (
    "AMERICAN DRY GINS",
    "FLAVORED GINS",
    "FLAVORED GIN",  # same category as above, second spelling in the source
)

# Deliberately excluded:
#   AMERICAN SLOE GINS            -- a sweetened liqueur (~15-25% ABV), not gin.
#                                    Thameswood's range is 41.4-47% ABV.
#   PUERTO RICO & VIRGIN ISLANDS RUM -- substring false positive. Rum.

# The source spells one category two ways; collapse them so downstream
# groupings do not split.
GIN_CATEGORY_ALIASES = {
    "FLAVORED GIN": "FLAVORED GINS",
}


def gin_categories() -> tuple[str, ...]:
    """Every Iowa category treated as gin, premium and other combined."""
    return GIN_PREMIUM_CATEGORIES + GIN_OTHER_CATEGORIES
