{#
    The highest-value test in the project.

    Every other failure mode announces itself: a bad join returns no rows, a bad
    cast errors, a bad parse trips a parsing test. This one does not. If the
    universe filter in mart_target_accounts breaks, the output still looks
    perfect -- a clean, plausible, ranked list of accounts. It is just a list of
    people who already buy. Nobody reading the notebook would spot it; the
    client would find out on the sales call.

    So the exclusion is asserted independently of the model that performs it,
    against the CRM directly, rather than trusted because the WHERE clause looks
    right. Joined on account_id, which is the mart's grain -- joining on
    store_number would silently skip the accounts that carry no store_number.

    Closed Won is unconditional: they are customers, they can never be targets.
    Closed Lost follows the var, because the client's policy is to keep previous
    losses in the mix (demoted -- see assert_closed_lost_demoted.sql). Reading
    the same var as the model means the test follows the policy instead of
    contradicting it the moment someone flips the flag.
#}

{% set excluded_states = ['closed_won'] %}
{% if var('exclude_closed_lost') %}
    {% do excluded_states.append('closed_lost') %}
{% endif %}

select
    t.target_rank,
    t.account_id,
    t.account_name,
    t.store_number,
    c.crm_state

from {{ ref('mart_target_accounts') }} t
join {{ ref('int_crm__accounts_current') }} c
    on t.account_id = c.account_id

where c.crm_state in ({{ "'" ~ excluded_states | join("', '") ~ "'" }})
