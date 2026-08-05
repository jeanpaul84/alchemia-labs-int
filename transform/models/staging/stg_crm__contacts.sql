{{
    config(
        materialized='view'
    )
}}

{#
    Grain: one row per contact_id per snapshot_date.

    Contacts carry no measures -- they exist so the ranked list can name a
    person to call. That makes them a joinable attribute, not a fact.
#}

with source as (

    select * from {{ source('raw_crm', 'contacts_snapshots') }}

),

cleaned as (

    select
        {{ clean_string('contact_id') }}                as contact_id,
        {{ clean_string('account_id') }}                as account_id,
        {{ clean_string('first_name') }}                as first_name,
        {{ clean_string('last_name') }}                 as last_name,
        {{ clean_string('title') }}                     as title,

        -- Lowercased because email is case-insensitive in practice and we may
        -- want to match on it; the display name keeps its original casing.
        lower({{ clean_string('email') }})              as email,

        {{ clean_string('phone') }}                     as phone,
        {{ clean_string('linkedin_url') }}              as linkedin_url,

        trim(concat(
            coalesce({{ clean_string('first_name') }}, ''), ' ',
            coalesce({{ clean_string('last_name') }}, '')
        ))                                              as full_name,

        snapshot_date,
        _source_file,
        _loaded_at

    from source

),

deduplicated as (

    select *
    from cleaned
    qualify row_number() over (
        partition by contact_id, snapshot_date
        order by _loaded_at desc
    ) = 1

)

select * from deduplicated
