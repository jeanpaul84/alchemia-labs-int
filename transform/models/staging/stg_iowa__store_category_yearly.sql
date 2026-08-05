{{
    config(
        materialized='view'
    )
}}

{#
    Grain: store_number x year x cat_group x gin_category.

    The heavy lifting already happened in extract/extract_market.py, which rolled
    34M order lines down to 31k rows. This model exists to make the join key
    explicitly comparable to the CRM's and to give the market data a name in the
    dbt lineage graph -- so a reviewer can see where it comes from rather than
    finding a table that appeared from nowhere.
#}

with source as (

    select * from {{ source('raw_iowa', 'store_category_yearly') }}

)

select
    -- Cast before trim so this works whether Iowa's column is STRING or INT64,
    -- and so it lines up byte-for-byte with stg_crm__accounts.store_number.
    -- A join key that is STRING on one side and INT64 on the other is the
    -- quietest way to get zero matched rows and no error.
    nullif(trim(cast(store_number as string)), '')  as store_number,

    trim(store_name)                                as store_name,
    trim(address)                                   as address,
    trim(city)                                      as city,
    trim(county)                                    as county,

    year,
    cat_group,
    gin_category,

    net_sale_dollars,
    gross_sale_dollars,
    returns_dollars,
    net_volume_liters,
    net_bottles,
    return_lines,
    order_lines,
    last_purchase_date

from source
