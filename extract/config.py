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

# The premium price tier -- Thameswood's actual shelf. A store already moving
# these has proven it can sell a GBP 35 bottle. This is the *fit* signal.
#
# Membership is decided on PRICE, measured, not on the word "imported". Average
# USD per bottle across 2021-2026, straight from the public table:
#
#     IMPORTED DRY GINS     $25.41    27.7M    <- premium
#     FLAVORED GIN          $24.89     4.9M    <- premium (98% of imported)
#     IMPORTED GINS         $22.13     4.8k    <- premium, but dormant
#     ---------------------------------------- the gap
#     AMERICAN DRY GINS      $9.16    17.3M    <- value
#     AMERICAN SLOE GINS     $8.34     137k    <- value
#
# The split is bimodal at ~$25 vs ~$9 with nothing in between, so the tier
# boundary is a real feature of the market rather than a judgement call.
GIN_PREMIUM_CATEGORIES = (
    "IMPORTED DRY GINS",
    # Dormant, not dropped: 13 order lines ever, none since 2022-05-31, so it
    # contributes nothing to the scoring window. Kept so that a reviewer who
    # greps for it finds this note instead of assuming it was missed -- and so
    # the set still covers Thameswood's Contemporary Gin range on paper.
    "IMPORTED GINS",
    # Moved here from GIN_OTHER on price evidence. Iowa's taxonomy splits on
    # ORIGIN (imported vs American); Thameswood competes on PRICE, and flavoured
    # gin sells at essentially the imported price. It is also the only gin
    # category in Iowa that is growing (+221% 2021-2025 while imported dry fell
    # 13% and American dry fell 21%), and it is where Thameswood's own
    # Elderflower Expression (GBP 35, 42% ABV) would be shelved.
    "FLAVORED GINS",
    "FLAVORED GIN",  # the spelling that actually occurs post-2021; see aliases
)

# Domestic value-tier gin -- real gin demand at a third of the price. Useful for
# sizing total gin appetite, and it is what a tier-2 "switch" conversation is
# about. This is the *market size* signal, not the fit signal.
GIN_OTHER_CATEGORIES = (
    "AMERICAN DRY GINS",
)

# Deliberately excluded:
#   AMERICAN SLOE GINS            -- a sweetened liqueur (~15-25% ABV), not gin.
#                                    Thameswood's range is 41.4-47% ABV. At
#                                    $8.34/bottle it is also the cheapest gin
#                                    category in the data -- cheaper than
#                                    domestic dry gin -- so the exclusion is
#                                    measured, not just asserted.
#   PUERTO RICO & VIRGIN ISLANDS RUM -- substring false positive. Rum.

# The source spells one category two ways; collapse them so downstream
# groupings do not split. Worth knowing which way round it is: only the SINGULAR
# occurs from 2021 onwards, so in practice every row is rewritten to the plural
# rather than the other way about. The alias is kept because the plural does
# appear in a DISTINCT over the table's full history back to 2012.
GIN_CATEGORY_ALIASES = {
    "FLAVORED GIN": "FLAVORED GINS",
}


def gin_categories() -> tuple[str, ...]:
    """Every Iowa category treated as gin, premium and other combined."""
    return GIN_PREMIUM_CATEGORIES + GIN_OTHER_CATEGORIES
