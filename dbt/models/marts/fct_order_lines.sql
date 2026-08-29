{{ config(materialized='table') }}

/*
    Grain: one row per genuine (deduplicated) order line.

    The dedup happens EXACTLY ONCE, here — duplicate_occurrence = 1 filters
    out the real, confirmed duplicate rows found in ADR 0012 (35.4% of
    December 2010, 0.7-1.6% elsewhere). Every other mart in this project
    builds on top of this table rather than re-filtering stg_orders
    directly, so the filter logic exists in exactly one place.

    assert_marts_dedup_reconciles and assert_marts_revenue_reconciles
    (dbt/tests/) independently verify this filter removed exactly the
    right rows — a second, marts-level check, not a repeat of the
    source-to-staging reconciliation that already exists in ops.
*/

with staging as (

    select * from {{ ref('stg_orders') }}
    where duplicate_occurrence = 1

)

select
    invoice_no,
    stock_code,
    description,
    customer_id,
    country,
    invoice_date,
    period,
    quantity,
    unit_price,
    line_amount,
    is_cancellation,
    line_type,
    source_system

from staging