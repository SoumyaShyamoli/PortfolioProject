/*
    Singular test: dbt staging must hold exactly as many rows as the latest
    Glue run wrote to S3, for every period.

    This is the control ADR 0007 promised. The Glue job proves nothing was
    lost between the source file and S3; this proves nothing was lost between
    S3 and the warehouse.

    Fails by returning rows. Any row returned is a period where the counts
    disagree.

    Note this compares against the LATEST Glue record per period, which is
    why stg_glue_recon deduplicates — comparing against all records would
    fail every time a month is reprocessed.
*/

with staging_counts as (

    select
        period,
        count(*) as staging_rows
    from {{ ref('stg_orders') }}
    group by 1

),

glue_counts as (

    select
        period,
        rows_written_back as glue_rows
    from {{ ref('stg_glue_recon') }}

)

select
    coalesce(s.period, g.period) as period,
    g.glue_rows,
    s.staging_rows,
    coalesce(s.staging_rows, 0) - coalesce(g.glue_rows, 0) as difference

from staging_counts s
full outer join glue_counts g on g.period = s.period

where coalesce(s.staging_rows, 0) <> coalesce(g.glue_rows, 0)
