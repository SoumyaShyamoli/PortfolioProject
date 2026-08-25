{{
    config(
        materialized = 'incremental',
        incremental_strategy = 'delete+insert',
        unique_key = 'period',
        on_schema_change = 'fail'
    )
}}

/*
    Cleaned order lines. One row per invoice line

    REPROCESSING MODEL — the point of this configuration:

    Glue reprocesses a month by replacing that month's S3 partition. This
    model mirrors that exactly. `delete+insert` on `period` means a run
    covering 2011-01 deletes every existing 2011-01 row and inserts the new
    ones. Reprocess a month, that month is replaced, at every layer.

    The alternative — append and dedupe downstream — would leave the
    warehouse holding rows S3 no longer has, and "what is currently true"
    would depend on which query you wrote. See ADR 0012.

    unique_key is `period`, NOT an invoice line key. dbt's delete+insert
    deletes by unique_key, so using the period makes this a partition swap.
    An invoice-line key would delete only rows present in the new batch,
    leaving orphans behind from a run that produced fewer rows.

    CLEANING happens here, not in Glue and not in raw. Raw stays the replay
    point (ADR 0005).
*/

with source as (

    select * from {{ source('raw', 'orders') }}

    {% if is_incremental() %}
        {% if var('reprocess_periods', none) %}
        -- Explicit reprocess:
        --   dbt run -s stg_orders --vars '{"reprocess_periods": ["2011-01"]}'
        where lpad(partition_year, 4, '0') || '-' || lpad(partition_month, 2, '0')
              in ({{ "'" ~ var('reprocess_periods') | join("','") ~ "'" }})
        {% else %}
        -- Normal run: anything loaded since the last build.
        where loaded_at > (select coalesce(max(loaded_at), '1900-01-01'::timestamp_tz) from {{ this }})
        {% endif %}
    {% endif %}

),

typed as (

    select
        invoice_no,
        stock_code,
        trim(description)                    as description,
        quantity,
        invoice_date,
        unit_price,
        customer_id,
        trim(country)                        as country,
        source_system,
        ingested_at,
        loaded_at,
        source_file,

        lpad(partition_year, 4, '0') || '-' || lpad(partition_month, 2, '0') as period,
        cast(invoice_date as date)           as invoice_date_only,

        -- A leading C marks a cancellation. Flagged rather than filtered:
        -- excluding them would make revenue totals stop matching the source,
        -- and cancellation rate is itself worth analysing.
        case when left(invoice_no, 1) = 'C' then true else false end as is_cancellation,

        -- Negative quantity outside a cancellation is an adjustment or an
        -- error. Worth distinguishing from a genuine return.
        case
            when left(invoice_no, 1) = 'C'  then 'cancellation'
            when quantity < 0               then 'negative_adjustment'
            when unit_price <= 0            then 'zero_or_negative_price'
            else 'normal'
        end                                  as line_type,

        quantity * unit_price                as line_amount

    from source

),

deduped as (

    /*
        The source contains exact duplicate rows — same invoice, stock code,
        quantity, timestamp, price. Some are genuine (two identical lines on
        one invoice), some are extract artefacts, and no field distinguishes
        them.

        Kept, with an occurrence number. Dropping them would change revenue
        totals against the source; ignoring them would hide the issue. The
        occurrence number lets a downstream model choose.
    */
    select
        *,
        row_number() over (
            partition by invoice_no, stock_code, quantity, invoice_date, unit_price
            order by loaded_at
        ) as duplicate_occurrence
    from typed

)

select * from deduped
