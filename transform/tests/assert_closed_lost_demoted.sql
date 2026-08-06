{#
    Asserts the Closed Lost demotion actually happened.

    The policy is "a previous loss ranks below every comparable live account,
    but keeps its tier" -- demoted, not deleted. That is expressed in
    mart_target_accounts as a single ORDER BY key, and a single misplaced key
    would silently promote previously-lost accounts back up the list. The output
    would still look like a perfectly ordered ranking; a rep would just find
    themselves cold-calling somebody who already told the client no.

    So the invariant is asserted against the finished ranking rather than
    trusted because the ORDER BY reads correctly: within any evidence tier, no
    Closed Lost account may outrank a non-lost one.

    Deliberately not gated on the demote_closed_lost var. When that var is off,
    relationship_penalty is 0 for every row, the `lost` CTE is empty, and the
    test passes trivially -- so the same SQL is correct under both settings
    without a branch to keep in sync.
#}

with lost as (

    select
        evidence_tier,
        target_rank,
        account_id,
        account_name
    from {{ ref('mart_target_accounts') }}
    where relationship_penalty = 1

),

comparable as (

    -- The worst rank held by a live account in each tier. Anything lost that
    -- beats it has jumped the queue.
    select
        evidence_tier,
        max(target_rank) as worst_live_rank
    from {{ ref('mart_target_accounts') }}
    where relationship_penalty = 0
    group by evidence_tier

)

select
    l.account_id,
    l.account_name,
    l.evidence_tier,
    l.target_rank,
    c.worst_live_rank

from lost l
join comparable c
    using (evidence_tier)

-- Lower target_rank = better position. A lost account ahead of any live account
-- in the same tier is the failure.
where l.target_rank < c.worst_live_rank
