{#
    Override dbt's default schema naming.

    dbt's default behaviour CONCATENATES the profile schema with the model's
    configured schema: profile `staging` + model `+schema: marts` gives
    STAGING_MARTS. That default exists so several developers can work in one
    database without colliding, each with their own prefix.

    This platform does not need that — dev and prod are separate databases,
    and there is one developer. What it does need is schema names that match
    the ones created in snowflake/setup/01, because the storage integration,
    the RAW tables and the committed DDL all reference them by name.

    So: use the model's configured schema verbatim, and fall back to the
    profile's schema for anything unconfigured.

    Consequence worth knowing: two people running dbt against the same
    database would now overwrite each other's models. Acceptable here,
    and the reason the default is what it is.
#}

{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}

    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}

{%- endmacro %}
