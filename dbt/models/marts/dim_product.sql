{{ config(materialized='table') }}

/*
    Grain: one row per stock_code.

    Online Retail II has the same stock_code appear with slightly varying
    free-text descriptions across rows (typos, casing, minor wording
    differences). Picking the most frequent description gives one stable
    label per product rather than an arbitrary first-seen value that
    happens to depend on load order.

    avg_unit_price is deliberately an average, not "the" price — prices
    for the same stock_code genuinely vary over the dataset's two-year
    span. Presenting a single price would misrepresent real variation as
    a data quality problem.
*/

with lines as (

    select * from {{ ref('fct_order_lines') }}

),

product_description as (

    select
        stock_code,
        description,
        count(*) as description_count

    from lines
    where description is not null
    group by 1, 2
    qualify row_number() over (
        partition by stock_code
        order by description_count desc
    ) = 1

),

aggregated as (

    select
        stock_code,

        min(invoice_date)                                              as first_sold_date,
        max(invoice_date)                                              as last_sold_date,

        count(distinct invoice_no)                                     as total_orders_containing,

        sum(case when not is_cancellation then quantity else 0 end)    as total_units_sold,
        sum(case when not is_cancellation then line_amount else 0 end) as total_revenue,
        sum(case when is_cancellation then abs(quantity) else 0 end)   as total_cancelled_units,

        avg(case when not is_cancellation then unit_price end)         as avg_unit_price

    from lines
    group by 1

)

select
    a.stock_code,
    pd.description,
    a.first_sold_date,
    a.last_sold_date,
    a.total_orders_containing,
    a.total_units_sold,
    a.total_revenue,
    a.total_cancelled_units,
    a.avg_unit_price,
    a.total_cancelled_units / nullif(a.total_units_sold + a.total_cancelled_units, 0) as cancellation_rate

from aggregated a
left join product_description pd on pd.stock_code = a.stock_code
