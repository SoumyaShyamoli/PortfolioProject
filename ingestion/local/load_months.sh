#!/usr/bin/env bash
#
# Upload NDJSON partitions to raw and run the Glue conversion for a range of
# months, sequentially.
#
# Sequential, not parallel, deliberately: the Glue job is configured with
# max_concurrent_runs = 1 (ADR 0007), so parallel starts would just fail
# while still billing the one-minute minimum.
#
# This is a stopgap. The Airflow DAG replaces it — with the recon gate,
# proper retries and status email. Kept in the repo because a documented
# manual procedure beats an undocumented one, and because backfills will
# still be run by hand occasionally.
#
# Usage:
#   ./scripts/load_months.sh dev 2011-01 2011-11
#   ./scripts/load_months.sh dev 2011-03 2011-03      # single month
#   ./scripts/load_months.sh dev 2011-01 2011-11 --skip-upload
#
set -euo pipefail

ENV="${1:?usage: load_months.sh <dev|prod> <start YYYY-MM> <end YYYY-MM> [--skip-upload]}"
START="${2:?start month required, YYYY-MM}"
END="${3:?end month required, YYYY-MM}"
SKIP_UPLOAD="${4:-}"

ACCOUNT="009073574996"
REGION="eu-west-2"
RAW_BUCKET="sd-retail-${ENV}-raw-${ACCOUNT}-${REGION}-an"
JOB_NAME="retail-${ENV}-json-to-parquet"
LOCAL_JSON="data/json/batch"

: "${AWS_PROFILE:=retail-dev}"
export AWS_PROFILE

# --- Guard against an expensive mistake ------------------------------------
# Twelve months is ~30p. Someone fat-fingering a five-year range should be
# stopped rather than billed.
month_diff() {
    local s_y=${1%-*} s_m=${1#*-} e_y=${2%-*} e_m=${2#*-}
    echo $(( (10#$e_y - 10#$s_y) * 12 + (10#$e_m - 10#$s_m) + 1 ))
}

TOTAL=$(month_diff "$START" "$END")
if (( TOTAL < 1 )); then
    echo "End month is before start month." >&2
    exit 1
fi

echo "Environment : $ENV"
echo "Range       : $START to $END  ($TOTAL months)"
echo "Raw bucket  : $RAW_BUCKET"
echo "Glue job    : $JOB_NAME"
echo "Est. cost   : ~£$(awk "BEGIN{printf \"%.2f\", $TOTAL * 0.03}") in Glue runs"
echo

if (( TOTAL > 15 )); then
    read -rp "That is more than 15 months. Continue? [y/N] " confirm
    [[ "$confirm" == "y" ]] || exit 1
fi

# --- Build the month list --------------------------------------------------
months=()
y=${START%-*}; m=${START#*-}
for (( i=0; i<TOTAL; i++ )); do
    months+=( "$(printf '%04d-%02d' "$((10#$y))" "$((10#$m))")" )
    m=$((10#$m + 1))
    if (( m > 12 )); then m=1; y=$((10#$y + 1)); fi
done

# --- Upload ----------------------------------------------------------------
if [[ "$SKIP_UPLOAD" != "--skip-upload" ]]; then
    echo "=== Uploading NDJSON to s3://$RAW_BUCKET/orders/ ==="
    for period in "${months[@]}"; do
        if ! compgen -G "${LOCAL_JSON}/event_date=${period}-*" > /dev/null; then
            echo "  ! no local files for $period — skipping upload"
            continue
        fi
        aws s3 cp "${LOCAL_JSON}/" "s3://${RAW_BUCKET}/orders/" \
            --recursive --exclude "*" --include "event_date=${period}-*" \
            --only-show-errors
        echo "  uploaded $period"
    done
    echo
fi

# --- Run Glue, one month at a time -----------------------------------------
declare -a failed=()

for period in "${months[@]}"; do
    year=${period%-*}
    # 10# forces base-10; without it, 08 and 09 are invalid octal.
    month=$((10#${period#*-}))

    echo "=== $period ==="

    run_id=$(aws glue start-job-run \
        --job-name "$JOB_NAME" \
        --arguments "{\"--year\":\"${year}\",\"--month\":\"${month}\"}" \
        --query JobRunId --output text)

    echo "  run: $run_id"

    # Poll. Job timeout is 15 minutes (glue.tf), so 40 x 15s bounds this
    # slightly beyond that.
    state=""
    for (( t=0; t<40; t++ )); do
        sleep 15
        state=$(aws glue get-job-run --job-name "$JOB_NAME" --run-id "$run_id" \
                  --query JobRun.JobRunState --output text)
        case "$state" in
            SUCCEEDED|FAILED|TIMEOUT|STOPPED|ERROR) break ;;
        esac
        printf '.'
    done
    echo
    sleep 10

    case "$state" in
        SUCCEEDED)
            secs=$(aws glue get-job-run --job-name "$JOB_NAME" --run-id "$run_id" \
                     --query JobRun.ExecutionTime --output text)
            echo "  SUCCEEDED in ${secs}s"
            ;;
        *)
            err=$(aws glue get-job-run --job-name "$JOB_NAME" --run-id "$run_id" \
                    --query JobRun.ErrorMessage --output text)
            echo "  $state: $err"
            failed+=( "$period" )
            # Keep going. A month with no source data should not stop the
            # rest, and the reconciliation will catch anything genuinely
            # missing later.
            ;;
    esac
done

echo
echo "=== Summary ==="
echo "Attempted: ${#months[@]}"
echo "Failed   : ${#failed[@]}  ${failed[*]:-}"
echo
echo "Next:"
echo "  1. Reload Snowflake RAW  — see snowflake/setup/05_raw_tables.sql"
echo "  2. dbt run && dbt test"
echo "  3. Check RETAIL_${ENV^^}.OPS.FCT_PIPELINE_RECONCILIATION — every"
echo "     period should show recon_status = 'ok'"

(( ${#failed[@]} == 0 )) || exit 1