{#
    Grain: one row per store_number, over the scoring window.

    Turns the market data from long to wide: cat_group stops being rows and
    becomes columns. That is the shape the ranking needs -- "premium gin dollars
    per store" has to be one number on one row before you can order by it.

    Window: var('market_window_years'), currently 2025 + 2026 = Jan-2025 ..
    Apr-2026. Sixteen months, and the SAME sixteen months for every store, which
    is precisely what makes it safe to rank on. It is NOT safe to compare the
    two years against each other -- 2026 holds four months of data and 2025
    holds twelve. Year-on-year growth needs month grain upstream; until then
    this model deliberately produces no growth measure at all rather than a
    misleading one.
#}

{% set window_years = var('market_window_years') %}

with market as (

    select *
    from {{ ref('stg_iowa__store_category_yearly') }}
    where year in ({{ window_years | join(', ') }})

),

store_attributes as (

    -- The same store_number appears under several names and addresses across
    -- years. Take the most recent, and break ties deterministically: an
    -- arbitrary pick would make the ranked list's store names change between
    -- runs on unchanged data, which erodes trust faster than a wrong number.
    select
        store_number,
        store_name,
        address,
        city,
        county
    from market
    qualify row_number() over (
        partition by store_number
        order by year desc, net_sale_dollars desc, cat_group
    ) = 1

),

store_sales as (

    -- Conditional aggregation: sum(if(condition, value, 0)) is how you pivot in
    -- SQL. One pass over the rows produces every column.
    select
        store_number,

        sum(if(cat_group = 'GIN_PREMIUM', net_sale_dollars, 0)) as premium_gin_dollars,
        sum(if(cat_group = 'GIN_OTHER',   net_sale_dollars, 0)) as other_gin_dollars,
        sum(if(cat_group != 'NON_GIN',    net_sale_dollars, 0)) as total_gin_dollars,
        sum(if(cat_group = 'NON_GIN',     net_sale_dollars, 0)) as non_gin_dollars,
        sum(net_sale_dollars)                                   as total_dollars,

        sum(if(cat_group = 'GIN_PREMIUM', net_bottles, 0))      as premium_gin_bottles,
        sum(if(cat_group = 'GIN_PREMIUM', order_lines, 0))      as premium_gin_order_lines,

        max(if(cat_group = 'GIN_PREMIUM', last_purchase_date, null))
                                                                as last_premium_gin_purchase_date,
        max(last_purchase_date)                                 as last_purchase_date

    from market
    group by store_number

)

select
    s.store_number,

    a.store_name,
    a.address,
    a.city,
    a.county,

    s.premium_gin_dollars,
    s.other_gin_dollars,
    s.total_gin_dollars,
    s.non_gin_dollars,
    s.total_dollars,
    s.premium_gin_bottles,
    s.premium_gin_order_lines,
    s.last_premium_gin_purchase_date,
    s.last_purchase_date,

    -- Descriptive only -- V1 ranks on premium_gin_dollars alone and nothing
    -- below feeds the ordering. These are carried so the notebook can describe
    -- a store ("71% of its gin spend is premium") and so V2 has its inputs
    -- already in place when fit becomes a scored component.
    safe_divide(s.premium_gin_dollars, s.total_gin_dollars)  as premium_share_of_gin,
    safe_divide(s.total_gin_dollars,   s.total_dollars)      as gin_share_of_store,
    safe_divide(s.premium_gin_dollars, s.premium_gin_bottles) as premium_gin_dollars_per_bottle

from store_sales s
join store_attributes a
    on s.store_number = a.store_number
