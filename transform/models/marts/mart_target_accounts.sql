{#
    Grain: one row per store_number. THE deliverable.

    Every Iowa store Thameswood could approach, ranked. Not just the top 25 --
    the whole eligible universe is scored and stored, and is_top_target flags
    the deliverable. "Who is number 26?" should never mean rebuilding anything.

    V1 ranking: premium gin dollars, descending. One measure, no weights,
    nothing to argue about.

    The reasoning, stated plainly so it can be challenged:
      * cat_group decides which dollars COUNT. net_sale_dollars decides the
        ORDER. Ranking on a store's total sales would return the 25 biggest
        liquor stores in Iowa -- something the client already knows, for free.
        Ranking on IMPORTED gin says the store's customers have already proven
        they will pay premium prices for exactly this product.
      * No weighted composite yet, on purpose. A single measure is impossible
        to get subtly wrong, and every later version is purely additive:
        momentum (needs month grain), fit ratio, recency, order frequency.
#}

with market as (

    select * from {{ ref('int_iowa__store_recent_sales') }}

),

crm as (

    -- Accounts with no store_number cannot be matched to the market data at
    -- all. All 40 of them are open Prospects, so excluding them here removes
    -- nothing we could have excluded anyway -- but it does mean five Closed
    -- Lost accounts have no store_number and therefore cannot be filtered out.
    -- They will appear below as 'net_new'. Known, quantified, documented.
    select * from {{ ref('int_crm__accounts_current') }}
    where store_number is not null

),

contacts as (

    select * from {{ ref('int_crm__primary_contact') }}

),

joined as (

    -- LEFT join, and this is the single most important word in the model. The
    -- best targets are stores with no CRM row at all; an inner join would
    -- silently delete exactly the population this project exists to find.
    select
        m.*,

        c.account_id,
        c.account_name,
        c.status                as crm_status,
        c.segment               as crm_segment,
        c.account_owner,
        c.crm_state,
        c.annual_target_gbp,
        c.open_pipeline_gbp,
        c.last_activity_date    as crm_last_activity_date,

        ct.contact_name,
        ct.contact_title,
        ct.contact_email,
        ct.contact_phone,
        ct.contact_linkedin_url,

        -- The split that decides who does the work: a known prospect can be
        -- called this afternoon by the rep who already owns it; a net-new store
        -- has to be sourced first. Two lists, two motions.
        case
            when c.account_id is null      then 'net_new'
            when c.crm_state = 'open'      then 'known_prospect'
            else c.crm_state
        end                     as target_type

    from market m
    left join crm c
        on m.store_number = c.store_number
    left join contacts ct
        on c.account_id = ct.account_id

),

eligible as (

    select *
    from joined
    -- "Gin-selling" means selling gin NOW, in the scoring window -- not having
    -- sold some in 2021. A store with no premium gin purchases has not shown it
    -- can move Thameswood's product.
    where premium_gin_dollars > 0

      -- Already customers. Nothing to approach.
      and coalesce(crm_state, 'none') != 'closed_won'

      {% if var('exclude_closed_lost') %}
      -- Said no already. Excluded by policy, not by data: the client has a bad
      -- history with these accounts and rep time is expensive. Flip
      -- exclude_closed_lost to resurface them as re-approach candidates.
      and coalesce(crm_state, 'none') != 'closed_lost'
      {% endif %}

),

ranked as (

    select
        *,
        -- row_number, not rank: ties would produce two number 1s and no number
        -- 2, which breaks both the unique test and "give me the top 25".
        -- store_number is the tiebreak so the order is reproducible.
        row_number() over (
            order by premium_gin_dollars desc, store_number
        ) as target_rank
    from eligible

)

select
    target_rank,
    target_rank <= {{ var('target_list_size') }} as is_top_target,

    store_number,
    store_name,
    city,
    county,
    address,

    target_type,
    account_id,
    account_name,
    crm_status,
    crm_segment,
    crm_state,
    account_owner,
    open_pipeline_gbp,
    annual_target_gbp,
    crm_last_activity_date,

    contact_name,
    contact_title,
    contact_email,
    contact_phone,
    contact_linkedin_url,

    -- The ranking measure.
    premium_gin_dollars,

    -- Context, not criteria. None of these affect target_rank.
    other_gin_dollars,
    total_gin_dollars,
    non_gin_dollars,
    total_dollars,
    premium_gin_bottles,
    premium_gin_order_lines,
    premium_share_of_gin,
    gin_share_of_store,
    premium_gin_dollars_per_bottle,
    last_premium_gin_purchase_date,
    last_purchase_date,

    -- The brief asks for "the reasoning behind the ranking". A score column
    -- alone does not survive contact with a salesperson -- this does. Every
    -- argument is coalesced because CONCAT returns NULL if any input is NULL,
    -- which would blank the rationale on exactly the net-new rows that need it.
    concat(
        '$', format("%'.0f", premium_gin_dollars),
        ' premium gin over ', cast(premium_gin_order_lines as string), ' orders',
        '; ', format('%.0f', coalesce(premium_share_of_gin, 0) * 100),
        '% of its gin spend is premium',
        '; ',
        case target_type
            when 'net_new'        then 'not in the CRM -- needs sourcing'
            when 'known_prospect' then concat(
                'open prospect, owned by ', coalesce(account_owner, 'unassigned')
            )
            else coalesce(target_type, 'unknown')
        end
    ) as rank_rationale

from ranked
