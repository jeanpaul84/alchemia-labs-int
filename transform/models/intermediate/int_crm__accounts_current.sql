{#
    Grain: one row per account_id. The current state of the CRM.

    Staging deliberately kept all 180 snapshots. This is the single model that
    decides what "now" means, so every mart downstream agrees on it -- if that
    decision were repeated in three marts, they would eventually disagree.

    It also classifies each account into a crm_state. Note what this model does
    NOT do: it does not decide who to exclude. It states the fact ("this account
    is closed_won"); the mart applies the policy ("closed_won accounts are not
    approachable"). Facts here, policy there -- so changing the policy never
    means editing a model that other things depend on.
#}

with latest_snapshot as (

    -- One scalar, reused by both feeds, so accounts and opportunities are
    -- always read as of the same night. Reading each at its own max would
    -- silently mix two days if one feed ever lands late.
    select max(snapshot_date) as snapshot_date
    from {{ ref('stg_crm__accounts') }}

),

accounts as (

    select *
    from {{ ref('stg_crm__accounts') }}
    where snapshot_date = (select snapshot_date from latest_snapshot)

),

opportunities as (

    select *
    from {{ ref('stg_crm__opportunities') }}
    where snapshot_date = (select snapshot_date from latest_snapshot)

),

opportunity_rollup as (

    -- Today every account has exactly one opportunity. Rolling up anyway costs
    -- nothing and means a second opportunity on an account tomorrow changes the
    -- numbers rather than duplicating the store in the ranked list.
    select
        account_id,
        count(*)                            as opportunity_count,
        logical_or(stage_group = 'won')     as has_won_opportunity,
        logical_or(stage_group = 'open')    as has_open_opportunity,
        logical_or(stage_group = 'lost')    as has_lost_opportunity,
        sum(if(stage_group = 'open', value_gbp, 0)) as open_pipeline_gbp,
        max(last_activity_date)             as last_opportunity_activity_date
    from opportunities
    group by account_id

)

select
    a.account_id,
    a.account_name,
    a.store_number,
    a.city,
    a.address,
    a.segment,
    a.account_owner,
    a.status,
    a.annual_target_gbp,
    a.contract_start_date,
    a.last_activity_date,
    a.snapshot_date                         as crm_as_of_date,

    coalesce(o.opportunity_count,     0)     as opportunity_count,
    coalesce(o.has_won_opportunity,   false) as has_won_opportunity,
    coalesce(o.has_open_opportunity,  false) as has_open_opportunity,
    coalesce(o.has_lost_opportunity,  false) as has_lost_opportunity,
    o.open_pipeline_gbp,
    o.last_opportunity_activity_date,

    -- Ordered by precedence, not by frequency. An account with both a win and
    -- an open deal is a customer first: "already sold to" outranks "in
    -- pipeline", and getting that order wrong would put existing customers back
    -- on the prospecting list.
    case
        when coalesce(o.has_won_opportunity,  false) then 'closed_won'
        when coalesce(o.has_open_opportunity, false) then 'open'
        when coalesce(o.has_lost_opportunity, false) then 'closed_lost'
        else 'no_opportunity'
    end                                     as crm_state

from accounts a
left join opportunity_rollup o
    on a.account_id = o.account_id
