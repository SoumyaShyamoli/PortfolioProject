/*
    Sum of line_amount in fct_order_lines should match the sum in
    deduplicated staging exactly, per period. Catches a class of bug a
    row-count check alone would miss — e.g. a join that changes values
    without changing row count, or a rounding/casting error introduced
    in the mart layer.

    0.01 tolerance is float rounding slack, not a real business
    tolerance — any genuine data discrepancy will be orders of magnitude
    larger than a rounding error and will still fail this test.
*/

with staging_deduped as (

    select period, sum(line_amount) as staging_revenue
    from {{ ref('stg_orders') }}
    where duplicate_occurrence = 1
    group by 1

),

marts_actual as (

    select period, sum(line_amount) as marts_revenue
    from {{ ref('fct_order_lines') }}
    group by 1

)

select
    s.period,
    s.staging_revenue,
    m.marts_revenue,
    abs(s.staging_revenue - m.marts_revenue) as diff

from staging_deduped s
join marts_actual m using (period)
where abs(s.staging_revenue - m.marts_revenue) > 0.01
