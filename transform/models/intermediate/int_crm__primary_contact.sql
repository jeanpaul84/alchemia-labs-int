{#
    Grain: one row per account_id -- the single person to call.

    Exists because a ranked list without a name and a phone number is a report,
    not an action. The brief's bar is "whether we'd act on it", and this is the
    column that decides it.

    Today the CRM holds exactly one contact per account, so the seniority
    ordering below never actually fires. It is here so that the day a second
    contact appears, the model picks the more useful one deliberately instead of
    picking at random -- and so the ranked list does not silently gain a
    duplicate row per account.
#}

with latest_contacts as (

    select *
    from {{ ref('stg_crm__contacts') }}
    where snapshot_date = (
        select max(snapshot_date) from {{ ref('stg_crm__contacts') }}
    )

)

select
    account_id,
    contact_id,
    full_name       as contact_name,
    title           as contact_title,
    email           as contact_email,
    phone           as contact_phone,
    linkedin_url    as contact_linkedin_url

from latest_contacts

-- Who actually decides what goes on the gin shelf, best first. contact_id is
-- the final tiebreak purely so the choice is reproducible: without it, two runs
-- over identical data could name two different people.
qualify row_number() over (
    partition by account_id
    order by
        case title
            when 'Owner'                  then 1
            when 'Beverage Director'      then 2
            when 'Spirits Buyer'          then 3
            when 'Wine & Spirits Manager' then 4
            when 'Store Manager'          then 5
            else 6
        end,
        contact_id
) = 1
