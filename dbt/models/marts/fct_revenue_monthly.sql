{{ config(materialized='table') }}

/*
    Grain: one row per period x country. The business-facing rollup —
    what a dashboard would actually query.

    Cancelled orders are shown as their own columns, not netted silently
    into total_revenue. A stakeholder should see both the gross figure
    and what was reversed, not a pre-netted number that hides
    cancellation volume from view.

    revenue_mom_change compares each period to the prior period WITHIN
    the same country (lag() partitioned by country) — comparing across
    countries would be meaningless. is_first_period_for_country flags
    rows where that comparison has no prior period to use, so a null or
    huge swing in the first row isn't misread as a data error.
*/

with orders as (

    select * from {{ ref('fct_orders') }}

),

aggregated as (

    select
        period,
        country,

        count(distinct case when not is_cancelled_order then invoice_no end) as total_orders,
        sum(case when not is_cancelled_order then total_revenue else 0 end)  as total_revenue,
        sum(case when not is_cancelled_order then total_quantity else 0 end) as total_units,
        count(distinct case when not is_cancelled_order then customer_id end) as total_customers,

        count(distinct case when is_cancelled_order then invoice_no end)     as cancelled_orders,
        sum(case when is_cancelled_order then abs(total_revenue) else 0 end) as cancelled_revenue

    from orders
    group by 1, 2

)

select
    period,
    country,
    total_orders,
    total_revenue,
    total_units,
    total_customers,
    cancelled_orders,
    cancelled_revenue,

    lag(total_revenue) over (partition by country order by period) as prior_period_revenue,

    div0null(
        total_revenue - lag(total_revenue) over (partition by country order by period),
        lag(total_revenue) over (partition by country order by period)
    ) as revenue_mom_change,

    lag(total_revenue) over (partition by country order by period) is null as is_first_period_for_country

from aggregated
