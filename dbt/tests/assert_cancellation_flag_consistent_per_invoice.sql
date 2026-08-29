/*
    Online Retail II cancellations are invoice-level events (a
    C-prefixed invoice number) — every line on a given invoice should
    therefore share the same is_cancellation value. fct_orders'
    is_cancelled_order column assumes this via BOOLOR_AGG; this test
    verifies the assumption rather than leaving it unstated.

    A failure here would mean either a genuine source anomaly (a mixed
    invoice) or a bug upstream in how is_cancellation gets derived in
    stg_orders — worth knowing which, rather than silently trusting
    BOOLOR_AGG to paper over a real inconsistency.
*/

select
    invoice_no,
    count(distinct is_cancellation) as distinct_flag_values

from {{ ref('fct_order_lines') }}
group by invoice_no
having count(distinct is_cancellation) > 1
