{{ config(materialized='table') }}

/*
    Grain: one row per customer_id.

    Built from fct_order_lines, not staging directly — every metric here
    is already dedup-correct by construction, since fct_order_lines did
    that filtering once.

    RFM recency is measured against the dataset's own max date, not
    CURRENT_DATE. The data is historical (2009-2011); "days since today"
    would be a meaningless, ever-growing number with no relationship to
    actual customer behaviour.
*/

with lines as (

    select * from {{ ref('fct_order_lines') }}
    where customer_id is not null   -- guest-style orders have no customer_id; excluded from this dimension, not dropped from the fact

),

reference_date as (

    select max(invoice_date) as max_invoice_date from lines

),

-- A customer's country should be stable, but the source occasionally
-- shows more than one for the same customer_id. Rather than assume
-- single-country and risk a silently wrong join, take the most frequent
-- one explicitly.
customer_country as (

    select
        customer_id,
        country,
        count(*) as country_line_count

    from lines
    group by 1, 2
    qualify row_number() over (
        partition by customer_id
        order by country_line_count desc
    ) = 1

),

aggregated as (

    select
        customer_id,

        min(invoice_date)                                          as first_order_date,
        max(invoice_date)                                          as last_order_date,

        count(distinct case when not is_cancellation then invoice_no end)  as total_orders,
        count(distinct case when is_cancellation then invoice_no end)      as total_cancelled_orders,

        count(*)                                                    as total_line_items,
        sum(case when not is_cancellation then quantity else 0 end) as total_units_purchased,
        sum(case when not is_cancellation then line_amount else 0 end) as total_revenue

    from lines
    group by 1

)

select
    a.customer_id,
    cc.country,
    a.first_order_date,
    a.last_order_date,
    datediff('day', a.first_order_date, a.last_order_date)           as customer_tenure_days,

    a.total_orders,
    a.total_cancelled_orders,
    a.total_line_items,
    a.total_units_purchased,
    a.total_revenue,

    a.total_cancelled_orders / nullif(a.total_orders + a.total_cancelled_orders, 0) as cancellation_rate,
    a.total_revenue / nullif(a.total_orders, 0)                      as avg_order_value,

    -- RFM, against the dataset's own timeline rather than today's date.
    datediff('day', a.last_order_date, r.max_invoice_date)           as rfm_recency_days,
    a.total_orders                                                    as rfm_frequency,
    a.total_revenue                                                   as rfm_monetary,

    -- Tercile segmentation on monetary value. ntile(3) over the whole
    -- customer base — an actual, usable segmentation, not decoration.
    case ntile(3) over (order by a.total_revenue)
        when 3 then 'high_value'
        when 2 then 'mid_value'
        else 'low_value'
    end as customer_segment

from aggregated a
join customer_country cc on cc.customer_id = a.customer_id
cross join reference_date r
