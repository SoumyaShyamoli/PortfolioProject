{{ config(materialized = 'view') }}

/*
    End-to-end reconciliation. One row per period, comparing what each hop of
    the pipeline believes it handled.

    The chain:
        NDJSON source lines -> Glue wrote to S3 -> Snowflake loaded
                            -> dbt staging holds

    Every hop should agree. Where they do not, the column that differs says
    WHICH hop lost rows — which is the reason for measuring at each one
    rather than only at the ends.

    This is what the reconciliation tests assert against, and the first thing
    to look at when a number looks wrong anywhere downstream.
*/

with glue as (

    select * from {{ ref('stg_glue_recon') }}

),

snowflake_raw as (

    select
        lpad(partition_year, 4, '0') || '-' || lpad(partition_month, 2, '0') as period,
        count(*) as rows_in_raw
    from {{ source('raw', 'orders') }}
    group by 1

),

dbt_staging as (

    select
        period,
        count(*) as rows_in_staging
    from {{ ref('stg_orders') }}
    group by 1

)

select
    coalesce(g.period, r.period, s.period)      as period,

    g.source_lines                              as ndjson_source_lines,
    g.corrupt_rows,
    g.undated_rows,
    g.rows_written_back                         as glue_wrote_to_s3,
    r.rows_in_raw                               as snowflake_loaded,
    s.rows_in_staging                           as dbt_staging_rows,

    -- Each should be zero. A non-zero value localises the loss.
    coalesce(r.rows_in_raw, 0) - coalesce(g.rows_written_back, 0)  as s3_to_snowflake_diff,
    coalesce(s.rows_in_staging, 0) - coalesce(r.rows_in_raw, 0)    as snowflake_to_staging_diff,

    g.glue_balanced,
    g.recon_at                                  as last_glue_run_at,
    g.run_id                                    as last_glue_run_id,

    -- Single status flag, for tests and alerting.
    case
        when g.period is null                                   then 'no_glue_record'
        when r.period is null                                   then 'not_loaded_to_snowflake'
        when not g.glue_balanced                                then 'glue_unbalanced'
        when coalesce(r.rows_in_raw, 0) <> g.rows_written_back  then 's3_to_snowflake_mismatch'
        when coalesce(s.rows_in_staging, 0) <> r.rows_in_raw    then 'snowflake_to_staging_mismatch'
        else 'ok'
    end                                         as recon_status

from glue g
full outer join snowflake_raw r on r.period = g.period
full outer join dbt_staging   s on s.period = coalesce(g.period, r.period)
