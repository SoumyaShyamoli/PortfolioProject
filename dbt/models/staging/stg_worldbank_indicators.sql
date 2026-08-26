{{ config(materialized = 'view') }}

/*
    GDP and population, pivoted to one row per country-year.

    The source has one row per country-indicator-year. Pivoting here means
    dim_country joins once rather than twice, and adding a third indicator
    later is a single extra case expression rather than another join.

    Null values are expected. The World Bank has no figure for every
    country-year — small territories especially — and a null here is
    genuinely "not reported" rather than missing data.
*/

with source as (

    select * from {{ source('raw', 'worldbank_indicators') }}
    where country_id is not null      -- aggregates come through with a blank id

),

pivoted as (

    select
        country_id,
        year,

        max(case when indicator_id = 'NY.GDP.MKTP.CD' then value end) as gdp_usd,
        max(case when indicator_id = 'SP.POP.TOTL'    then value end) as population,

        max(source_system) as source_system,
        max(ingested_at)   as ingested_at,
        max(loaded_at)     as loaded_at

    from source
    group by 1, 2

)

select
    country_id,
    year,
    gdp_usd,
    population,

    -- Derived rather than fetched: GDP per capita is a separate World Bank
    -- indicator, but computing it avoids a third API call and a third
    -- COPY. nullif guards against a divide-by-zero that should never
    -- happen but would fail the whole model if it did.
    case
        when population > 0 then gdp_usd / nullif(population, 0)
    end as gdp_per_capita_usd,

    source_system,
    ingested_at,
    loaded_at

from pivoted
