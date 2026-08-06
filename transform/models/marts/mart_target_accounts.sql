{#
    Grain: one row per account_id. THE deliverable.

    SCOPE: the client's own CRM. Every candidate is an account Thameswood
    already holds a record for. Stores that appear in the Iowa market data but
    not in the CRM are OUT of scope by decision -- see the assumptions page.
    That is why this model reads FROM the CRM and joins market data onto it,
    rather than the other way round: the CRM defines the universe, the market
    data scores it.

    Excluded outright: Closed Won (already customers, nothing to approach).
    Included but demoted: Closed Lost (see relationship_penalty below).

    V1 ranking: a tiered ordinal sort, not a weighted score. Nothing here is
    multiplied by a coefficient anyone has to defend -- each key is a plain
    statement of precedence, applied in order:

      1. evidence_tier        -- what the third-party market data PROVES about
                                 this account, best evidence first. An account we
                                 can match to a real Iowa store that is actively
                                 buying premium-tier gin is a better bet than
                                 one we can only describe from our own CRM.
      2. relationship_penalty -- Closed Lost sits at the BOTTOM OF ITS OWN TIER.
                                 A previous loss is harder work than a live
                                 prospect, but it is not worthless: a lost
                                 account that demonstrably buys premium-tier gin
                                 still beats an open prospect with no gin
                                 traction at all. Demoted, not deleted.
      3. tier_measure         -- the dollar measure appropriate to that tier,
                                 descending. Because evidence_tier sorts first,
                                 this column is only ever compared LIKE FOR LIKE
                                 -- premium gin against premium gin, never
                                 premium gin against total spend.
      4. open_pipeline_gbp    -- decides tier 4, where there is no market data to
                                 sort on at all, and breaks dollar ties elsewhere.
      5. account_id           -- final tiebreak, so the order is reproducible.

    The reasoning behind the tiers, stated plainly so it can be challenged:
      * cat_group decides which dollars COUNT. Ranking on an account's total
        liquor spend would just surface the biggest shops on the client's list --
        something they already know, for free. Ranking on PREMIUM-TIER gin says
        this account's customers have already proven they will pay premium
        prices for exactly this product.
      * Tier 1 requires that proof to be MATERIAL. Without a floor, an account
        that bought $65 of premium-tier gin in sixteen months -- two bottles --
        outranks one with $1,116 of gin spend, purely because the $65 landed in
        the right category. That is the tier structure being taken literally
        past the point where the evidence means anything. The floor is where
        "this shelf exists" stops being a reasonable inference.
      * Sub-floor accounts are demoted, never dropped. They fall to tier 2 and
        are re-ranked on total gin spend, which is the honest measure of what
        they can actually move.
      * Tier 2 is the interesting one commercially: accounts with gin demand but
        no proven premium volume. That is a switch conversation, not a cold one.
#}

{% set floor = var('premium_gin_materiality_floor') %}

with crm as (

    -- The universe. One row per account, latest snapshot, already classified
    -- into a crm_state upstream.
    select * from {{ ref('int_crm__accounts_current') }}

    -- Already customers. There is nothing to "approach".
    where crm_state != 'closed_won'

    {% if var('exclude_closed_lost') %}
    -- Off by default: the client asked for previous losses to stay in the mix,
    -- demoted rather than removed. Flip exclude_closed_lost to true to drop
    -- them entirely instead.
    and crm_state != 'closed_lost'
    {% endif %}

),

market as (

    select * from {{ ref('int_iowa__store_recent_sales') }}

),

contacts as (

    select * from {{ ref('int_crm__primary_contact') }}

),

joined as (

    -- LEFT joins, and the direction is the whole point of this version. Every
    -- CRM account survives; market data attaches where we can match it. An
    -- inner join here would silently drop the 47 accounts we cannot match to an
    -- Iowa store -- accounts that are still in scope, just with weaker evidence.
    --
    -- store_number is unique per account, so the market join cannot fan out and
    -- the account grain is preserved.
    select
        c.account_id,
        c.account_name,
        c.store_number,
        c.segment                       as crm_segment,
        c.status                        as crm_status,
        c.crm_state,
        c.account_owner,
        c.annual_target_gbp,
        c.open_pipeline_gbp,
        c.opportunity_count,
        c.last_activity_date            as crm_last_activity_date,
        c.crm_as_of_date,

        -- Identity: prefer what the client's own CRM says, fall back to the
        -- market feed. county exists only market-side.
        coalesce(c.city, m.city)        as city,
        coalesce(c.address, m.address)  as address,
        m.county,
        m.store_name,

        ct.contact_name,
        ct.contact_title,
        ct.contact_email,
        ct.contact_phone,
        ct.contact_linkedin_url,

        -- Market measures. Left NULL rather than zero-filled where there is no
        -- match: "we have no market data for this account" and "this account
        -- bought no gin" are different facts and the list should not blur them.
        m.premium_gin_dollars,
        m.other_gin_dollars,
        m.total_gin_dollars,
        m.non_gin_dollars,
        m.total_dollars,
        m.premium_gin_bottles,
        m.premium_gin_order_lines,
        m.premium_share_of_gin,
        m.gin_share_of_store,
        m.premium_gin_dollars_per_bottle,
        m.last_premium_gin_purchase_date,
        m.last_purchase_date,

        m.store_number is not null      as has_market_match

    from crm c
    left join market m
        on c.store_number = m.store_number
    left join contacts ct
        on c.account_id = ct.account_id

),

classified as (

    select
        *,

        -- What the market data proves about this account, strongest first.
        -- Note the floor on tier 1 and the plain `> 0` on tier 2: an account
        -- with token premium-tier gin fails the first test but passes the
        -- second, so it lands in tier 2 rather than falling out of the ranking.
        case
            when not has_market_match                        then 4
            when coalesce(premium_gin_dollars, 0) >= {{ floor }} then 1
            when coalesce(total_gin_dollars, 0) > 0          then 2
            else                                                  3
        end as evidence_tier,

        -- A previous loss costs an account its place within its tier, not the
        -- tier itself. Reversible without touching this file.
        {% if var('demote_closed_lost') %}
        if(crm_state = 'closed_lost', 1, 0) as relationship_penalty,
        {% else %}
        0 as relationship_penalty,
        {% endif %}

        -- Who does the work, in the client's language.
        case crm_state
            when 'open'        then 'known_prospect'
            when 'closed_lost' then 'previous_loss'
            else crm_state  -- 'no_opportunity': an account with no pipeline yet
        end as target_type

    from joined

),

measured as (

    select
        *,

        -- One column, but a different meaning per tier -- which is only safe
        -- because evidence_tier is the first sort key, so tier 1 dollars are
        -- never compared against tier 3 dollars.
        case evidence_tier
            when 1 then coalesce(premium_gin_dollars, 0)  -- proven premium demand
            when 2 then coalesce(total_gin_dollars, 0)    -- gin demand, unproven premium
            when 3 then coalesce(total_dollars, 0)        -- size, no gin traction
            else 0                                        -- tier 4: no market data
        end as tier_measure,

        -- Kept 1:1 with evidence_tier so it can be grouped on directly. The
        -- sub-distinction inside tier 2 -- token premium gin vs none at all --
        -- lives in rank_rationale instead, where it does not break grouping.
        -- The floor is interpolated, not typed, so the label cannot drift from
        -- the var that produced it.
        -- "premium", not "imported": the tier is defined on PRICE, and it now
        -- includes flavoured gin, which sells at the imported price but is not
        -- necessarily imported. Calling it "imported" would misdescribe the
        -- rule to anyone reading the ranked list.
        case evidence_tier
            when 1 then 'buys premium gin at scale (>= ${{ floor }})'
            when 2 then 'gin demand, below the ${{ floor }} premium-gin floor'
            when 3 then 'no gin traction'
            else        'no market match -- CRM evidence only'
        end as evidence_tier_label

    from classified

),

ranked as (

    select
        *,
        -- row_number, not rank: ties would produce two number 1s and no number
        -- 2, which breaks both the unique test and "give me the top 25".
        row_number() over (
            order by
                evidence_tier,                          -- best market evidence first
                relationship_penalty,                   -- previous losses last within tier
                tier_measure desc,                      -- like-for-like dollars
                coalesce(open_pipeline_gbp, 0) desc,    -- decides tier 4
                account_id                              -- reproducible
        ) as target_rank
    from measured

)

select
    target_rank,
    target_rank <= {{ var('target_list_size') }} as is_top_target,

    account_id,
    account_name,
    target_type,
    evidence_tier,
    evidence_tier_label,
    relationship_penalty,

    crm_status,
    crm_segment,
    crm_state,
    account_owner,
    open_pipeline_gbp,
    annual_target_gbp,
    opportunity_count,
    crm_last_activity_date,
    crm_as_of_date,

    contact_name,
    contact_title,
    contact_email,
    contact_phone,
    contact_linkedin_url,

    has_market_match,
    store_number,
    store_name,
    city,
    county,
    address,

    -- The measure that decided the order within this account's tier.
    tier_measure,

    -- Market context. NULL where the account has no matched store.
    premium_gin_dollars,
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
    -- which would blank the rationale on exactly the thin rows that need it.
    concat(
        'Tier ', cast(evidence_tier as string), ' -- ', evidence_tier_label,
        '; ',
        case evidence_tier
            when 1 then concat(
                '$', format("%'.0f", coalesce(premium_gin_dollars, 0)),
                ' premium gin over ',
                cast(coalesce(premium_gin_order_lines, 0) as string), ' orders, ',
                format('%.0f', coalesce(premium_share_of_gin, 0) * 100),
                '% of its gin spend'
            )
            -- The one place the two flavours of tier 2 are told apart: an
            -- account with token premium gin is a different conversation from
            -- one with none, even though they rank on the same measure.
            when 2 then concat(
                '$', format("%'.0f", coalesce(total_gin_dollars, 0)), ' gin spend, ',
                if(coalesce(premium_gin_dollars, 0) > 0,
                   concat('but only $', format("%'.0f", premium_gin_dollars),
                          ' of it premium tier -- below the ${{ floor }} floor'),
                   'none of it premium tier -- switch target')
            )
            when 3 then concat(
                '$', format("%'.0f", coalesce(total_dollars, 0)),
                ' total liquor spend, no gin purchases in the window'
            )
            else concat(
                'no Iowa store matched',
                if(store_number is null,
                   ' (no store_number on the account)',
                   concat(' (store_number ', store_number, ' not in the market data)'))
            )
        end,
        '; ',
        case target_type
            when 'known_prospect' then concat(
                'open prospect, owned by ', coalesce(account_owner, 'unassigned'),
                ', GBP ', format("%'.0f", coalesce(open_pipeline_gbp, 0)), ' open pipeline'
            )
            when 'previous_loss'  then concat(
                'PREVIOUSLY LOST -- demoted within tier; owned by ',
                coalesce(account_owner, 'unassigned')
            )
            else coalesce(target_type, 'unknown')
        end
    ) as rank_rationale

from ranked
