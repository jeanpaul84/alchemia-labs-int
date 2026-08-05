{{
    config(
        materialized='view'
    )
}}

{#
    Grain: one row per opportunity_id per snapshot_date.

    180 snapshots of the same ~100 opportunities is what lets us see movement --
    which deals changed stage, and when. The mart layer turns that into a
    recency/momentum signal; here we only make it readable.
#}

with source as (

    select * from {{ source('raw_crm', 'opportunities_snapshots') }}

),

cleaned as (

    select
        {{ clean_string('opportunity_id') }}            as opportunity_id,
        {{ clean_string('account_id') }}                as account_id,
        {{ clean_string('product_sku') }}               as product_sku,
        {{ clean_string('stage') }}                     as stage,
        {{ clean_string('owner') }}                     as owner,
        {{ clean_string('type') }}                      as opportunity_type,

        {{ parse_uk_date('expected_close_date') }}      as expected_close_date,
        {{ parse_uk_date('closed_date') }}              as closed_date,
        {{ parse_iso_date('last_activity_date') }}      as last_activity_date,
        {{ parse_iso_date('created_date') }}            as created_date,

        {{ parse_gbp('value_gbp') }}                    as value_gbp,

        -- Derived here rather than repeated in three marts. Everything that is
        -- not Closed Won or Closed Lost is live pipeline.
        case
            when {{ clean_string('stage') }} = 'Closed Won'  then 'won'
            when {{ clean_string('stage') }} = 'Closed Lost' then 'lost'
            else 'open'
        end                                             as stage_group,

        snapshot_date,
        _source_file,
        _loaded_at

    from source

),

deduplicated as (

    select *
    from cleaned
    qualify row_number() over (
        partition by opportunity_id, snapshot_date
        order by _loaded_at desc
    ) = 1

)

select * from deduplicated
