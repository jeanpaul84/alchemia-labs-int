{#
    The highest-value test in the project.

    Every other failure mode announces itself: a bad join returns no rows, a bad
    cast errors, a bad parse trips a parsing test. This one does not. If the
    universe filter in mart_target_accounts breaks, the output still looks
    perfect -- a clean, plausible, ranked list of stores. It is just a list of
    people who already buy, or who already said no. Nobody reading the notebook
    would spot it; the client would find out on the sales call.

    So the exclusion is asserted independently of the model that performs it,
    against the CRM directly, rather than trusted because the WHERE clause looks
    right.

    Reads the same var as the model, so the test follows the policy instead of
    contradicting it the moment someone flips the flag.
#}

{% set excluded_states = ['closed_won'] %}
{% if var('exclude_closed_lost') %}
    {% do excluded_states.append('closed_lost') %}
{% endif %}

select
    t.target_rank,
    t.store_number,
    t.store_name,
    c.account_id,
    c.account_name,
    c.crm_state

from {{ ref('mart_target_accounts') }} t
join {{ ref('int_crm__accounts_current') }} c
    on t.store_number = c.store_number

where c.crm_state in ({{ "'" ~ excluded_states | join("', '") ~ "'" }})
