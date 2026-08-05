{#
    stg_crm__accounts drops duplicate (account_id, snapshot_date) rows and keeps
    an arbitrary one. That is only safe while the duplicates are genuinely
    identical -- today they differ solely by trailing whitespace in
    account_name, which trimming removes.

    This test is the guard on that assumption. It fails if a duplicate pair ever
    disagrees on a real business column, which would mean "pick either one" had
    quietly become "pick a winner", and the choice would be arbitrary.

    to_json_string(struct(...)) gives us a single comparable value per row, so
    "do these rows agree" becomes one count(distinct).
#}

with trimmed as (

    select
        {{ clean_string('account_id') }} as account_id,
        snapshot_date,
        to_json_string(struct(
            {{ clean_string('account_name') }}        as account_name,
            {{ clean_string('city') }}                as city,
            {{ clean_string('address') }}             as address,
            {{ clean_string('store_number') }}        as store_number,
            {{ clean_string('segment') }}             as segment,
            {{ clean_string('account_owner') }}       as account_owner,
            {{ clean_string('contract_start_date') }} as contract_start_date,
            {{ clean_string('annual_target_gbp') }}   as annual_target_gbp,
            {{ clean_string('last_activity_date') }}  as last_activity_date,
            {{ clean_string('created_date') }}        as created_date,
            {{ clean_string('status') }}              as status
        )) as row_fingerprint

    from {{ source('raw_crm', 'accounts_snapshots') }}

)

select
    account_id,
    snapshot_date,
    count(*)                            as duplicate_rows,
    count(distinct row_fingerprint)     as distinct_versions
from trimmed
group by account_id, snapshot_date
having count(distinct row_fingerprint) > 1
