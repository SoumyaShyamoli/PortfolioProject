{{ config(materialized='table') }}

/*
    Grain: one row per invoice_no. Aggregates fct_order_lines up to the
    order — "how many orders, how much per order," where fct_order_lines
    answers "what was bought."

    is_cancelled_order uses BOOLOR_AGG rather than assuming consistency:
    Online Retail II cancellations are invoice-level events (a
    C-prefixed invoice number), so every line on a cancelled invoice
    should already agree — but this is verified, not assumed, by
    assert_cancellation_flag_consistent_per_invoice.sql rather than left
    as an unstated assumption baked into the aggregation.
*/

with lines as (

    select * from {{ ref('fct_order_lines') }}

)

select
    invoice_no,

    -- Order-level attributes taken once per invoice via any_value —
    -- these should be identical across every line on an invoice; picking
    -- one representative row is correct, not an approximation.
    any_value(customer_id)   as customer_id,
    any_value(country)       as country,
    any_value(period)        as period,
    any_value(invoice_date)  as invoice_date,

    count(distinct stock_code)          as line_item_count,
    sum(quantity)                       as total_quantity,
    sum(line_amount)                    as total_revenue,
    boolor_agg(is_cancellation)         as is_cancelled_order

from lines
group by invoice_no
