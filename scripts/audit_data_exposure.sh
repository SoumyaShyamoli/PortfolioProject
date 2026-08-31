#!/usr/bin/env bash
#
# Greps the codebase for patterns likely to leak row-level customer data
# into logs — CloudWatch (Glue), Airflow task logs, or dbt test output.
# Run from the repo root.
#
# This does NOT prove absence of a problem — grep is a starting point, not
# a guarantee. A clean run means "nothing obviously wrong found by pattern
# matching," not "formally verified safe." Read anything it flags by hand.

set -euo pipefail

echo "=== Scanning for row-level logging / print statements ==="
echo

echo "--- Glue script: any .show(), print(), or explicit row dumps? ---"
grep -n -E '\.show\(|print\(.*row|collect\(\)' glue/*.py 2>/dev/null || echo "  none found (or glue/*.py path is wrong — check the actual script location)"
echo

echo "--- Glue script: does any log line include customer_id or similar? ---"
grep -n -iE 'log.*customer_id|print.*customer_id' glue/*.py 2>/dev/null || echo "  none found"
echo

echo "--- Airflow DAG: any logging of query RESULTS rather than counts/status? ---"
grep -n -E 'print\(|logging\.|logger\.' airflow/dags/*.py | grep -iE 'row|customer|fetchall|fetchone' || echo "  none found — DAG logging appears to be counts/status only"
echo

echo "--- dbt tests: any model or test using SELECT * without aggregation? ---"
grep -rn 'select \*' dbt/tests/ dbt/models/ 2>/dev/null | grep -viE 'with |cte' || echo "  none found outside CTEs (expected — staging models legitimately select *)"
echo

echo "--- CI workflows: any step that could echo query output to the log? ---"
grep -n -E 'dbt show|dbt run-operation|--fail-fast' .github/workflows/*.yml || echo "  none found"
echo

echo "=== Manual checks this script cannot do ==="
echo "1. Open the Glue script and confirm no debug .show()/collect() calls"
echo "   were left in from development — these ARE stripped in production"
echo "   Spark jobs but are easy to leave in accidentally."
echo "2. Confirm dbt test failure output (in CI logs) shows counts/diffs"
echo "   only, never a sample of the actual failing rows — check one real"
echo "   failed test run's CI log if one exists."
echo "3. Confirm Airflow's XCom values (Admin -> XComs in the UI) never"
echo "   contain row-level data — task functions in retail_pipeline.py"
echo "   currently only xcom_push counts/status strings, by design, but"
echo "   worth a one-time visual check in the UI."
