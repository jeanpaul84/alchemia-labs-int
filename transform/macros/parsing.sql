{#
    Parsing rules for the CRM's string columns.

    These live in macros rather than being pasted into each model so that the
    rule is defined once and can be tested once. The singular tests in
    transform/tests/ assert each macro against the raw layer, so a format change
    in a future snapshot fails the build instead of silently producing nulls.
#}


{% macro clean_string(column) %}
    {#- Trim, then treat the empty string as NULL.

        The CRM exports use "" for "no value", and BigQuery treats "" and NULL
        as different things. Collapsing them here means every downstream
        not_null test means what it says. -#}
    nullif(trim({{ column }}), '')
{% endmacro %}


{% macro parse_gbp(column) %}
    {#- "GBP 76,503.29" / "76,503.29" -> 76503.29

        Strips everything that is not a digit, a decimal point or a minus sign,
        which covers the currency symbol, the "GBP " prefix and the thousands
        separators in one pass. NUMERIC (not FLOAT64) because this is money:
        NUMERIC is exact decimal, FLOAT64 would introduce rounding error the
        moment we start summing pipeline value. -#}
    safe_cast(
        regexp_replace({{ clean_string(column) }}, r'[^0-9.\-]', '') as numeric
    )
{% endmacro %}


{% macro parse_uk_date(column) %}
    {#- "24/01/2023" -> 2023-01-24.

        Day-first, not month-first. Verified from the data, not assumed: the
        first component reaches 24 and 28 across the snapshots, and there is no
        24th or 28th month. safe.parse_date returns NULL rather than erroring on
        a value in another format -- a test catches it, ingestion never breaks. -#}
    safe.parse_date('%d/%m/%Y', {{ clean_string(column) }})
{% endmacro %}


{% macro parse_iso_date(column) %}
    {#- "2026-05-01" -> 2026-05-01.

        Deliberately a separate macro from parse_uk_date rather than one clever
        "try both formats" helper. A column that silently switches format is a
        problem we want to be told about, not one we want papered over: with
        two explicit macros, drift shows up as a failing test. -#}
    safe.parse_date('%F', {{ clean_string(column) }})
{% endmacro %}
