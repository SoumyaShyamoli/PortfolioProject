/*
    fct_order_lines should have EXACTLY as many rows, per period, as
    stg_orders has rows where duplicate_occurrence = 1. Any difference
    means the mart layer either dropped genuine rows or let duplicates
    through — a second, independent check on the dedup logic at the
    point it actually gets consumed, not just where it's flagged in
    staging.

    This is the marts-level equivalent of assert_staging_matches_glue_recon
    — same pattern (join two independently-derived counts, fail on
    disagreement), one layer further up the chain. Source-to-staging
    reconciliation (ops.fct_pipeline_reconciliation) proves nothing was
    lost in transit; this proves the dedup step in marts didn't
    introduce a NEW discrepancy on top of that.
*/

with staging_deduped as (

    select period, count(*) as staging_count
    from {{ ref('stg_orders') }}
    where duplicate_occurrence = 1
    group by 1

),

marts_actual as (

    select period, count(*) as marts_count
    from {{ ref('fct_order_lines') }}
    group by 1

)

select
    s.period,
    s.staging_count,
    m.marts_count,
    s.staging_count - m.marts_count as diff

from staging_deduped s
join marts_actual m using (period)
where s.staging_count != m.marts_count
