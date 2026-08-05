{{
    config(
        materialized='view'
    )
}}

{#
    Grain: one row per account_id per snapshot_date.

    Two jobs only -- clean and type. No business logic, no joins, no filtering
    down to the current snapshot: that is the mart layer's decision to make, and
    baking it in here would throw away the history we deliberately kept.
#}

with source as (

    select * from {{ source('raw_crm', 'accounts_snapshots') }}

),

cleaned as (

    select
        {{ clean_string('account_id') }}                as account_id,
        {{ clean_string('account_name') }}              as account_name,
        {{ clean_string('city') }}                      as city,
        {{ clean_string('address') }}                   as address,

        -- The join key to the market data. Kept as STRING: it is an identifier,
        -- not a quantity, and Iowa's own column is a STRING too.
        {{ clean_string('store_number') }}              as store_number,

        {{ clean_string('segment') }}                   as segment,
        {{ clean_string('account_owner') }}             as account_owner,
        {{ clean_string('status') }}                    as status,

        -- Mixed formats across columns in the same file. See macros/parsing.sql.
        {{ parse_uk_date('contract_start_date') }}      as contract_start_date,
        {{ parse_iso_date('last_activity_date') }}      as last_activity_date,
        {{ parse_iso_date('created_date') }}            as created_date,

        {{ parse_gbp('annual_target_gbp') }}            as annual_target_gbp,

        snapshot_date,
        _source_file,
        _loaded_at

    from source

),

deduplicated as (

    select *
    from cleaned
    -- Three accounts (ACC-0001, ACC-0035, ACC-0060) appear twice in *every*
    -- snapshot, differing only by trailing whitespace in account_name. Once
    -- trimmed the pairs are identical, so taking either one is safe -- but
    -- "safe" is asserted, not assumed: tests/assert_account_duplicates_agree.sql
    -- fails the build if a duplicate pair ever disagrees on a real column.
    --
    -- Left in, these fan out every downstream join and double-count three
    -- accounts' revenue straight into the ranking.
    qualify row_number() over (
        partition by account_id, snapshot_date
        order by _loaded_at desc
    ) = 1

)

select * from deduplicated
