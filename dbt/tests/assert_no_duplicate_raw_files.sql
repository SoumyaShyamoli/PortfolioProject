/*
    ADR 0012 named this explicitly as a gap: row-count reconciliation
    (ops.fct_pipeline_reconciliation) proves nothing about WHETHER a
    partition was double-loaded — only whether the final counts happen to
    balance. If a period is reprocessed without the delete-then-FORCE
    sequence (the exact failure mode ADR 0012 documented), RAW.ORDERS can
    end up holding two loads of the same file, or two different files
    covering the same partition, and a coincidental balance elsewhere
    would hide it.

    This test catches it directly: no (period, source_file) combination
    should appear more than once in RAW.ORDERS. A period reprocessed
    correctly (DELETE, then COPY...FORCE) never has two source_files for
    the same period lingering — the old one is gone before the new one
    lands. Seeing two here means either the delete step was skipped, or a
    genuinely duplicate file was loaded twice.
*/

with periods as (

    select
        to_char(partition_year, 'FM0000') || '-' || to_char(partition_month, 'FM00') as period,
        source_file,
        count(*) as row_count

    from {{ source('raw', 'orders') }}
    group by 1, 2

)

select
    period,
    count(distinct source_file) as distinct_files,
    listagg(distinct source_file, ', ') as files

from periods
group by period
having count(distinct source_file) > 1
