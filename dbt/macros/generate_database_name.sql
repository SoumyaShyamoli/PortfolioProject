{#
    Explicit database naming.

    Not strictly required — dbt uses target.database by default — but stated
    here so the dev/prod switch is visible in the project rather than only in
    a profile file that is not committed.

    The ONLY things that differ between a dev and a prod run are database,
    user and key. This macro is where the first of those is resolved.
#}

{% macro generate_database_name(custom_database_name, node) -%}

    {%- set default_database = target.database -%}

    {%- if custom_database_name is none -%}
        {{ default_database }}
    {%- else -%}
        {{ custom_database_name | trim }}
    {%- endif -%}

{%- endmacro %}
