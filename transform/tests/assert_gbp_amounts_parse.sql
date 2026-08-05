{#
    Money columns, checked across all 180 snapshots.

    A row here means the source had an amount and parse_gbp returned NULL. The
    consequence is worse than it sounds: a nulled annual_target_gbp does not
    error, it just drops that account's value to nothing and pushes it down the
    ranked list. Silent, directional, and invisible in the output.
#}

{% set money_columns = [
    ('accounts_snapshots',      'annual_target_gbp'),
    ('opportunities_snapshots', 'value_gbp'),
] %}

{% for table, column in money_columns %}

select
    '{{ table }}'  as source_table,
    '{{ column }}' as source_column,
    snapshot_date,
    {{ column }}   as unparseable_value
from {{ source('raw_crm', table) }}
where {{ clean_string(column) }} is not null
  and {{ parse_gbp(column) }} is null

{% if not loop.last %}union all{% endif %}

{% endfor %}
