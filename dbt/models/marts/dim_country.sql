{{ config(materialized='table') }}

/*
    Grain: one row per retail country string, as it appears in the
    source data — the model the World Bank integration work was building
    toward.

    LEFT JOIN, deliberately, not inner: the three known unmappable
    countries (Unspecified, European Community, West Indies — see the
    country_mapping seed) still get a row here, with null World Bank
    columns, rather than silently disappearing from the dimension. A
    consumer joining a fact to this table should never lose rows just
    because enrichment data doesn't exist for a valid retail country.

    mapping_type is carried through unmodified so a consumer can see
    exactly how much to trust the enrichment columns for any given row —
    'exact' and 'alias' are solid, 'assumed' is a judgement call made
    during the seed's construction, 'unmappable' means the World Bank
    columns are null by design, not by error.
*/

with mapping as (

    select * from {{ ref('country_mapping') }}

),

worldbank as (

    select * from {{ ref('stg_worldbank_countries') }}

),

indicators as (

    select * from {{ ref('stg_worldbank_indicators') }}

),

lines as (

    select * from {{ ref('fct_order_lines') }}

),

country_activity as (

    select
        country,
        count(distinct invoice_no) as total_orders,
        count(distinct customer_id) as total_customers,
        sum(case when not is_cancellation then line_amount else 0 end) as total_revenue

    from lines
    group by 1

)

select
    m.retail_country,
    m.worldbank_country_id,
    m.mapping_type,

    wb.country_name,
    wb.region_name,
    wb.income_level_name,

    ind.gdp_usd,
    ind.population,
    ind.gdp_per_capita_usd,

    coalesce(ca.total_orders, 0)    as total_orders,
    coalesce(ca.total_customers, 0) as total_customers,
    coalesce(ca.total_revenue, 0)   as total_revenue,

    -- Which countries buy disproportionately to their population size —
    -- only meaningful where population is known, hence the nullif rather
    -- than treating an unmappable country's null population as zero.
    ca.total_revenue / nullif(ind.population, 0) as revenue_per_capita

from mapping m
left join worldbank  wb  on wb.country_id  = m.worldbank_country_id
left join indicators ind on ind.country_id = m.worldbank_country_id
left join country_activity ca on ca.country = m.retail_country
