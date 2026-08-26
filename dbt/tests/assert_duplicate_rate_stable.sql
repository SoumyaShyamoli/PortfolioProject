/*
    Duplicate rows exist in the source and are deliberately kept in staging
    — stg_orders drops nothing (ADR 0005, ADR 0012). This test does not
    assert duplicates are absent; it asserts the observed pattern of
    duplication has not changed unexpectedly.

    FINDING (2026-08-25): the true duplicate rate in this dataset is ~30%,
    not the ~1% assumed when this test was first written. Verified as
    genuine — identical invoice_no, stock_code, quantity, invoice_date
    (to the millisecond) and unit_price, confirmed against raw Parquet.
    This is Online Retail II itself, not an artefact of Glue or the load.
    See ADR 0012.

    The reconciliation chain could not have caught this: Glue counts
    duplicate rows as rows, so source lines, rows written to S3, and rows
    loaded to Snowflake all agree. Recon proves nothing was lost in
    transit; it says nothing about whether what arrived is what you'd
    expect it to look like. This test exists for that second kind of
    check.

    Threshold is generous — 25% to 45% — because the true baseline was
    established from three periods only (Dec 2010, Jan 2011, Nov 2011).
    Tightening it should wait until more months are loaded and a real
    per-period range is known, not asserted from three data points.
*/

select
    period,
    count(*)                                        as total_rows,
    count_if(duplicate_occurrence > 1)               as duplicate_rows,
    count_if(duplicate_occurrence > 1) / count(*)    as duplicate_rate

from {{ ref('stg_orders') }}
group by 1
having duplicate_rate < 0.25 or duplicate_rate > 0.45