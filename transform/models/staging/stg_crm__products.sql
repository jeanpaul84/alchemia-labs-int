{{
    config(
        materialized='view'
    )
}}

{#
    Grain: one row per SKU. Five rows.

    Parquet carries its own schema, so unlike the CSV feeds this one arrives
    already typed and needs almost nothing doing to it. It is here so that
    opportunities can be described by what was actually being sold rather than
    by a SKU code.
#}

with source as (

    select * from {{ source('raw_crm', 'product_catalogue') }}

)

select
    trim(sku_id)                as sku_id,
    trim(product_name)          as product_name,
    trim(company)               as company,
    trim(variant)               as variant,
    trim(category)              as category,

    bottle_size_cl,
    abv_pct,
    list_price_gbp,
    pack_size,
    launch_date

from source
