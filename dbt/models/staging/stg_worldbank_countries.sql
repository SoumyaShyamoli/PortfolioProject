{{ config(materialized = 'view') }}

/*
    World Bank countries, aggregates removed.

    The API returns roughly 300 rows, of which about 50 are AGGREGATES rather
    than countries — 'World', 'Euro area', 'Arab World', 'Sub-Saharan Africa'.
    They are identifiable by region_id = 'NA'.

    The Lambda deliberately does not filter them (ADR 0005: raw takes what
    the source returns), so the filter lives here. Doing it at ingest would
    mean re-fetching to recover them if they turn out to be useful for
    regional rollups later.
*/

with source as (

    select * from {{ source('raw', 'worldbank_countries') }}

)

select
    country_id,
    iso2_code,
    country_name,
    region_id,
    region_name,
    income_level_id,
    income_level_name,
    lending_type_id,
    nullif(trim(capital_city), '')       as capital_city,

    -- The API returns coordinates as strings, and empty for aggregates and
    -- a few small territories. try_cast returns null rather than failing
    -- the model on a value that was never numeric.
    try_cast(longitude as float)         as longitude,
    try_cast(latitude as float)          as latitude,

    source_system,
    ingested_at,
    loaded_at

from source

-- region_id = 'NA' marks an aggregate. Not a null check — 'NA' is a literal
-- two-character string the API uses, which is easy to misread.
where region_id is not null
  and region_id <> 'NA'
