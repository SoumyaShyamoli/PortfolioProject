/*
    Duplicate rows exist in the source and are deliberately kept in staging
    (ADR 0005, ADR 0012). This test asserts the duplication rate is within
    an expected range PER PERIOD, rather than a single flat threshold —
    a flat threshold was tried first and rejected once real numbers showed
    why it does not work here.

    FINDING (2026-08-25): duplicate rate varies enormously by month.

        2010-12   35.4%   <- first month in the dataset. Outlier.
        2011-01    0.70%
        2011-11    1.55%

    December 2010 is the initial month of Online Retail II and is treated
    here as a KNOWN, DOCUMENTED EXCEPTION rather than folded into a wider
    "normal" range — a range wide enough to cover 35% would no longer catch
    a genuine anomaly in any other month (see ADR 0012 for the
    investigation and current best guess at cause).

    Ordinary months are expected in a tight band, 0-5%. Dec 2010 is
    excluded from that check and given its own explicit, generous ceiling
    so a change in ITS behaviour is still caught, without that ceiling
    hiding a problem anywhere else.

    The reconciliation chain cannot catch any of this — Glue counts
    duplicate rows as rows, so source lines, S3 writes and Snowflake loads
    all agree regardless of duplication. This test exists for exactly the
    gap that leaves.
*/

with rates as (

    select
        period,
        count(*)                                     as total_rows,
        count_if(duplicate_occurrence > 1)            as duplicate_rows,
        count_if(duplicate_occurrence > 1) / count(*) as duplicate_rate

    from {{ ref('stg_orders') }}
    group by 1

)

select
    period,
    total_rows,
    duplicate_rows,
    duplicate_rate,
    case
        when period = '2010-12' then 'known exception — see model comment'
        else 'ordinary period'
    end as period_class

from rates
where
    -- The documented exception: still bounded, just at its own known level.
    -- A jump well past what was observed (35.4%) is still worth knowing
    -- about.
    (period = '2010-12' and duplicate_rate > 0.45)
    or
    -- Every other period: tight band. 5% is roughly 3x the highest
    -- ordinary rate observed so far (1.55%), leaving margin for normal
    -- variation without being wide enough to hide a real problem.
    (period <> '2010-12' and (duplicate_rate < 0 or duplicate_rate > 0.05))