{#
    Every CRM date column, checked against the format we claim it has, across
    all 180 snapshots.

    A row here means: the source had a value, and our parser returned NULL for
    it. That is exactly the failure mode that makes a ranking quietly wrong --
    a date that fails to parse becomes an account with "no recent activity"
    rather than an error anybody notices.

    We sampled the format from the most recent snapshot. This test is what makes
    that a claim about all 180 rather than a claim about one.
#}

{% set date_columns = [
    ('accounts_snapshots',      'contract_start_date', 'uk'),
    ('accounts_snapshots',      'last_activity_date',  'iso'),
    ('accounts_snapshots',      'created_date',        'iso'),
    ('opportunities_snapshots', 'expected_close_date', 'uk'),
    ('opportunities_snapshots', 'closed_date',         'uk'),
    ('opportunities_snapshots', 'last_activity_date',  'iso'),
    ('opportunities_snapshots', 'created_date',        'iso'),
] %}

{% for table, column, fmt in date_columns %}

select
    '{{ table }}'  as source_table,
    '{{ column }}' as source_column,
    '{{ fmt }}'    as expected_format,
    snapshot_date,
    {{ column }}   as unparseable_value
from {{ source('raw_crm', table) }}
where {{ clean_string(column) }} is not null
  and {% if fmt == 'uk' %}{{ parse_uk_date(column) }}{% else %}{{ parse_iso_date(column) }}{% endif %} is null

{% if not loop.last %}union all{% endif %}

{% endfor %}
