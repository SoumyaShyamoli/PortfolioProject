{{ config(materialized = 'view') }}

/*
    Latest reconciliation record per period.

    Every Glue run appends an audit record, so reprocessing a month leaves
    several records for it. Comparing against all of them double-counts;
    comparing against an arbitrary one might pick a stale failure.

    History stays in ops.glue_recon_raw deliberately — it shows reruns and
    which runs failed. This view is the current-truth read over it.

    QUALIFY filters on a window function without a subquery. Snowflake
    specific, and clearer than the CTE-and-filter alternative.
*/

select
    recon_record:period::varchar                    as period,
    recon_record:run_id::varchar                    as run_id,
    recon_record:job_name::varchar                  as job_name,
    recon_record:recon_at::timestamp_tz             as recon_at,

    recon_record:source_lines::number               as source_lines,
    recon_record:corrupt_rows::number               as corrupt_rows,
    recon_record:undated_rows::number               as undated_rows,
    recon_record:expected_rows::number              as expected_rows,
    recon_record:rows_written_back::number          as rows_written_back,
    recon_record:difference::number                 as difference,
    recon_record:balanced::boolean                  as glue_balanced,

    recon_record:quality:rows_total::number         as q_rows_total,
    recon_record:quality:null_invoice_no::number    as q_null_invoice_no,
    recon_record:quality:null_customer_id::number   as q_null_customer_id,
    recon_record:quality:negative_quantity::number  as q_negative_quantity,
    recon_record:quality:non_positive_price::number as q_non_positive_price,
    recon_record:quality:cancellations::number      as q_cancellations,
    recon_record:quality:unparseable_date::number   as q_unparseable_date,

    source_file,
    loaded_at

from {{ source('ops', 'glue_recon_raw') }}

qualify row_number() over (
    partition by recon_record:period::varchar
    order by recon_record:recon_at::timestamp_tz desc
) = 1
