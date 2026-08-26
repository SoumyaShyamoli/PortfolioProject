/*
    Duplicate rows exist in the source and are deliberately kept
    (stg_orders drops nothing). But the RATE should be stable. A sudden
    jump means the extract changed, not that customers started placing
    identical orders.

    The reconciliation cannot catch this: Glue counts duplicates as rows,
    so the numbers balance perfectly while the data becomes wrong.

    Threshold is 5%. Observed rate in the source is around 1%.
*/

select
    period,
    count(*)                                          as total_rows,
    count_if(duplicate_occurrence > 1)                as duplicate_rows,
    count_if(duplicate_occurrence > 1) / count(*)     as duplicate_rate

from {{ ref('stg_orders') }}
group by 1
having count_if(duplicate_occurrence > 1) / count(*) > 0.05