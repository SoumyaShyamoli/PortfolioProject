{{ config(materialized='table') }}

/*
    Calendar spine covering the dataset's actual span plus a small buffer.
    Generated, not sourced — nothing in the source data drives this table,
    it exists purely to support time-intelligence joins from the facts.
*/

with spine as (

    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('2009-12-01' as date)",
        end_date="cast('2012-01-31' as date)"
    ) }}

)

select
    date_day,
    extract(year from date_day)                          as year,
    extract(month from date_day)                          as month,
    to_char(date_day, 'Month')                            as month_name,
    extract(quarter from date_day)                        as quarter,
    dayofweek(date_day)                                   as day_of_week,
    to_char(date_day, 'Day')                               as day_name,
    dayofweek(date_day) in (0, 6)                          as is_weekend,
    date_day = last_day(date_day)                          as is_month_end,

    -- Matches the period key used everywhere else in this project
    -- (stg_orders.period, fct_pipeline_reconciliation.period) so joins
    -- from a fact to this table's period-level attributes need no
    -- separate lookup.
    to_char(date_day, 'YYYY-MM')                           as period

from spine
