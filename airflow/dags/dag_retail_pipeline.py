"""
Retail platform pipeline DAG.

The environment (dev or prod) is read from RETAIL_ENVIRONMENT, set as an
environment variable on the instance's systemd unit. Same DAG file runs
identically on both instances — this is the same "only the target differs"
principle used throughout the platform (dbt profiles, Snowflake roles,
Terraform locals).

Structure:

    trigger_glue
        -> wait_for_glue
            -> load_snowflake_raw
                -> dbt_deps
                    -> dbt_seed
                        -> dbt_run_staging
                            -> dbt_run_ops              (builds the recon fact)
                                -> recon_gate            <-- FAILS the run here
                                    -> dbt_run_marts
                                        -> dbt_test_marts
    [any task]  ------------------------------------------> send_status_email

recon_gate is the control asked for explicitly: marts must not be built on
top of data that has not reconciled. Airflow's default trigger rule means a
task only runs if ALL of its upstream dependencies succeeded, so a failed
recon_gate stops dbt_run_marts from ever starting — not "marts run and we
find out afterwards".

send_status_email has trigger_rule="all_done", so it runs regardless of
where the DAG failed, and renders the reconciliation table from whatever
state fct_pipeline_reconciliation is in at that point — including a failed
recon_gate, which is exactly when you most want the email.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta

import boto3
from airflow import DAG
from airflow.exceptions import AirflowFailException
from airflow.operators.python import PythonOperator
from airflow.operators.bash import BashOperator
from airflow.providers.smtp.operators.smtp import EmailOperator
from airflow.models import Variable

ENVIRONMENT = os.environ.get("RETAIL_ENVIRONMENT", "dev")
AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "eu-west-2")
ACCOUNT_ID = "009073574996"

GLUE_JOB_NAME = f"retail-{ENVIRONMENT}-json-to-parquet"
DBT_PROJECT_DIR = "/opt/airflow/dbt"
DBT_TARGET = ENVIRONMENT

# The Snowflake key for THIS environment only — fetched fresh at task run
# time from SSM, never baked into the AMI or left on disk between runs.
# Mirrors the pattern in dbt-ci.yml exactly.
SSM_KEY_PATH = f"/retail/{ENVIRONMENT}/snowflake/private_key"
LOCAL_KEY_PATH = "/tmp/sf_key.p8"

RECIPIENT_EMAIL = Variable.get(f"retail_{ENVIRONMENT}_alert_email")

default_args = {
    "owner": "retail-platform",
    "retries": 1,
    "retry_delay": timedelta(minutes=2),
}


# ---------------------------------------------------------------------------
# Task functions
# ---------------------------------------------------------------------------

def _fetch_snowflake_key() -> None:
    """Write the environment's Snowflake key to a task-local temp file.

    Deliberately re-fetched every DAG run rather than cached on disk between
    runs — the key never persists on the instance outside a single task
    execution window. Matches the CI pattern in dbt-ci.yml.
    """
    ssm = boto3.client("ssm", region_name=AWS_REGION)
    value = ssm.get_parameter(Name=SSM_KEY_PATH, WithDecryption=True)["Parameter"]["Value"]
    with open(LOCAL_KEY_PATH, "w") as f:
        f.write(value)
    os.chmod(LOCAL_KEY_PATH, 0o600)


def _cleanup_snowflake_key() -> None:
    if os.path.exists(LOCAL_KEY_PATH):
        os.remove(LOCAL_KEY_PATH)


def _trigger_glue(**context) -> str:
    """Start the Glue job for the period this DAG run targets.

    The period is a DAG run parameter (dag_run.conf), not derived from the
    schedule — this pipeline processes whichever month is requested, it does
    not assume "today's month", because the source data is historical.
    """
    conf = context["dag_run"].conf or {}
    year = conf.get("year")
    month = conf.get("month")
    if not year or not month:
        raise AirflowFailException(
            "DAG run requires {'year': ..., 'month': ...} in the trigger config."
        )

    glue = boto3.client("glue", region_name=AWS_REGION)
    run = glue.start_job_run(
        JobName=GLUE_JOB_NAME,
        Arguments={"--year": str(year), "--month": str(month)},
    )
    run_id = run["JobRunId"]
    context["ti"].xcom_push(key="glue_run_id", value=run_id)
    context["ti"].xcom_push(key="period", value=f"{year}-{int(month):02d}")
    return run_id


def _wait_for_glue(**context) -> None:
    """Poll until the Glue run reaches a terminal state.

    Glue's own job timeout (glue.tf, 15 minutes) is the real backstop against
    a hung run. This poll has a longer bound purely so Airflow does not give
    up before Glue's own timeout would have fired.
    """
    import time

    run_id = context["ti"].xcom_pull(key="glue_run_id")
    glue = boto3.client("glue", region_name=AWS_REGION)

    for _ in range(60):  # 60 x 20s = 20 minutes, beyond Glue's own 15-minute cap
        state = glue.get_job_run(JobName=GLUE_JOB_NAME, RunId=run_id)["JobRun"]["JobRunState"]
        if state == "SUCCEEDED":
            return
        if state in ("FAILED", "TIMEOUT", "STOPPED", "ERROR"):
            error = glue.get_job_run(JobName=GLUE_JOB_NAME, RunId=run_id)["JobRun"].get(
                "ErrorMessage", "no error message"
            )
            raise AirflowFailException(f"Glue run {run_id} ended in {state}: {error}")
        time.sleep(20)

    raise AirflowFailException(f"Glue run {run_id} did not finish within the poll window.")


def _load_snowflake_raw(**context) -> None:
    """COPY INTO RAW.ORDERS for the period Glue just wrote.

    Reprocessing safety per ADR 0012: DELETE the partition before COPY with
    FORCE=TRUE. Snowflake's load-file-history idempotency looks safe and is
    not — a reprocessed S3 partition arrives under a new filename, which
    Snowflake has never seen and will happily load ON TOP of the old rows if
    the delete step is skipped. This is the automation ADR 0012 flagged as
    missing; this task is that automation.
    """
    import snowflake.connector

    period = context["ti"].xcom_pull(key="period")
    year, month = period.split("-")

    conn = snowflake.connector.connect(
        account="BRTNPNX-IH35235",
        user=f"RETAIL_{ENVIRONMENT.upper()}_USER",
        private_key_file=LOCAL_KEY_PATH,
        role=f"RETAIL_TRANSFORMER_{ENVIRONMENT.upper()}",
        warehouse="RETAIL_WH",
        database=f"RETAIL_{ENVIRONMENT.upper()}",
        schema="RAW",
    )
    cur = conn.cursor()
    try:
        # The delete-before-force sequence ADR 0012 said was still manual.
        cur.execute(
            "DELETE FROM RAW.ORDERS WHERE partition_year = %s AND partition_month = %s",
            (int(year), int(month)),
        )
        cur.execute(f"""
            COPY INTO RAW.ORDERS (
                invoice_no, stock_code, description, quantity, invoice_date,
                unit_price, customer_id, country, source_system, ingested_at,
                partition_year, partition_month, source_file
            )
            FROM (
                SELECT
                    $1:invoice_no::VARCHAR, $1:stock_code::VARCHAR,
                    $1:description::VARCHAR, $1:quantity::NUMBER,
                    $1:invoice_date::TIMESTAMP_NTZ, $1:unit_price::FLOAT,
                    $1:customer_id::VARCHAR, $1:country::VARCHAR,
                    $1:source_system::VARCHAR, $1:ingested_at::TIMESTAMP_TZ,
                    REGEXP_SUBSTR(METADATA$FILENAME, 'year=([0-9]+)', 1, 1, 'e', 1)::NUMBER,
                    REGEXP_SUBSTR(METADATA$FILENAME, 'month=([0-9]+)', 1, 1, 'e', 1)::NUMBER,
                    METADATA$FILENAME
                FROM @RAW.STG_ORDERS
            )
            PATTERN = '.*year={year}/month={int(month)}/part-.*[.]snappy[.]parquet'
            FILE_FORMAT = (TYPE = PARQUET)
            FORCE = TRUE
            ON_ERROR = 'ABORT_STATEMENT'
        """)
    finally:
        cur.close()
        conn.close()


def _recon_gate(**context) -> None:
    """The control. Query fct_pipeline_reconciliation for the period just
    processed and fail the DAG if it is not 'ok'.

    This is a Python check on top of dbt's own tests for the same model —
    deliberately redundant. dbt build would also fail on the accepted_values
    test on recon_status. The reason for checking again here, explicitly, is
    that this task's failure is what stops dbt_run_marts from being scheduled
    at all, via Airflow's dependency graph — relying solely on dbt's exit
    code would still let a downstream Airflow task attempt to run.
    """
    import snowflake.connector

    period = context["ti"].xcom_pull(key="period")

    conn = snowflake.connector.connect(
        account="BRTNPNX-IH35235",
        user=f"RETAIL_{ENVIRONMENT.upper()}_USER",
        private_key_file=LOCAL_KEY_PATH,
        role=f"RETAIL_TRANSFORMER_{ENVIRONMENT.upper()}",
        warehouse="RETAIL_WH",
        database=f"RETAIL_{ENVIRONMENT.upper()}",
        schema="OPS",
    )
    cur = conn.cursor()
    try:
        cur.execute(
            "SELECT recon_status FROM OPS.FCT_PIPELINE_RECONCILIATION WHERE period = %s",
            (period,),
        )
        row = cur.fetchone()
    finally:
        cur.close()
        conn.close()

    if row is None:
        raise AirflowFailException(f"No reconciliation record found for period {period}.")

    status = row[0]
    if status != "ok":
        raise AirflowFailException(
            f"Reconciliation FAILED for {period}: status = '{status}'. "
            f"Marts will NOT be built on top of this data."
        )


def _send_status_email(**context) -> None:
    """Render the reconciliation table as HTML and email it, regardless of
    where the DAG succeeded or failed.

    trigger_rule=all_done on the operator means this runs even after an
    upstream failure — a failed recon_gate should produce an email showing
    exactly what disagreed, not silence.
    """
    import snowflake.connector

    period = context["ti"].xcom_pull(key="period") or "unknown"
    dag_run_state = "SUCCESS" if context["dag_run"].get_task_instance("dbt_test_marts") and \
        context["dag_run"].get_task_instance("dbt_test_marts").state == "success" else "FAILED"

    conn = snowflake.connector.connect(
        account="BRTNPNX-IH35235",
        user=f"RETAIL_{ENVIRONMENT.upper()}_USER",
        private_key_file=LOCAL_KEY_PATH,
        role=f"RETAIL_TRANSFORMER_{ENVIRONMENT.upper()}",
        warehouse="RETAIL_WH",
        database=f"RETAIL_{ENVIRONMENT.upper()}",
        schema="OPS",
    )
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT period, ndjson_source_lines, glue_wrote_to_s3, snowflake_loaded,
                   dbt_staging_rows, s3_to_snowflake_diff, snowflake_to_staging_diff,
                   recon_status
            FROM OPS.FCT_PIPELINE_RECONCILIATION
            ORDER BY period
        """)
        rows = cur.fetchall()
        cols = [d[0] for d in cur.description]
    finally:
        cur.close()
        conn.close()

    def row_html(r: tuple) -> str:
        status = r[-1]
        color = "#d4edda" if status == "ok" else "#f8d7da"
        cells = "".join(f"<td style='padding:4px 8px;border:1px solid #ccc'>{v}</td>" for v in r)
        return f"<tr style='background:{color}'>{cells}</tr>"

    header = "".join(f"<th style='padding:4px 8px;border:1px solid #ccc'>{c}</th>" for c in cols)
    body_rows = "".join(row_html(r) for r in rows)

    html = f"""
    <h3>Retail Platform — {ENVIRONMENT.upper()} pipeline run</h3>
    <p><b>Period processed:</b> {period}<br>
       <b>Overall status:</b> {dag_run_state}</p>
    <table style='border-collapse:collapse;font-family:monospace;font-size:12px'>
        <tr>{header}</tr>
        {body_rows}
    </table>
    <p style='color:#666;font-size:11px'>
        Green rows reconciled cleanly at every hop (source lines, S3, Snowflake,
        dbt staging). Red rows disagree somewhere in that chain — the column
        showing a non-zero diff is where to look first.
    </p>
    """
    context["ti"].xcom_push(key="email_html", value=html)


# ---------------------------------------------------------------------------
# DAG
# ---------------------------------------------------------------------------

with DAG(
    dag_id=f"retail_pipeline_{ENVIRONMENT}",
    description=f"Batch ingestion, transformation and reconciliation - {ENVIRONMENT}",
    default_args=default_args,
    schedule=None,  # triggered manually / with {"year": ..., "month": ...} conf
    start_date=datetime(2026, 1, 1),
    catchup=False,
    tags=["retail", ENVIRONMENT],
) as dag:

    fetch_key = PythonOperator(task_id="fetch_snowflake_key", python_callable=_fetch_snowflake_key)

    trigger_glue = PythonOperator(task_id="trigger_glue", python_callable=_trigger_glue)

    wait_for_glue = PythonOperator(task_id="wait_for_glue", python_callable=_wait_for_glue)

    load_snowflake_raw = PythonOperator(
        task_id="load_snowflake_raw", python_callable=_load_snowflake_raw
    )

    dbt_deps = BashOperator(
        task_id="dbt_deps",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt deps --target {DBT_TARGET}",
    )

    dbt_seed = BashOperator(
        task_id="dbt_seed",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt seed --target {DBT_TARGET}",
    )

    dbt_run_staging = BashOperator(
        task_id="dbt_run_staging",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt run --target {DBT_TARGET} --select staging",
    )

    dbt_run_ops = BashOperator(
        task_id="dbt_run_ops",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt run --target {DBT_TARGET} --select ops",
    )

    recon_gate = PythonOperator(task_id="recon_gate", python_callable=_recon_gate)

    dbt_run_marts = BashOperator(
        task_id="dbt_run_marts",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt run --target {DBT_TARGET} --select marts",
    )

    dbt_test_marts = BashOperator(
        task_id="dbt_test_marts",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt test --target {DBT_TARGET} --select marts",
    )

    render_email = PythonOperator(
        task_id="render_email",
        python_callable=_send_status_email,
        trigger_rule="all_done",  # runs whether upstream succeeded or failed
    )

    send_email = EmailOperator(
        task_id="send_email",
        to=RECIPIENT_EMAIL,
        subject=f"Retail pipeline [{ENVIRONMENT}] — run {{{{ ds }}}}",
        html_content="{{ ti.xcom_pull(task_ids='render_email', key='email_html') }}",
        trigger_rule="all_done",
    )

    cleanup_key = PythonOperator(
        task_id="cleanup_snowflake_key",
        python_callable=_cleanup_snowflake_key,
        trigger_rule="all_done",  # always remove the key, success or failure
    )

    (
        fetch_key
        >> trigger_glue
        >> wait_for_glue
        >> load_snowflake_raw
        >> dbt_deps
        >> dbt_seed
        >> dbt_run_staging
        >> dbt_run_ops
        >> recon_gate
        >> dbt_run_marts
        >> dbt_test_marts
    )

    # Email and key cleanup run after everything, regardless of outcome.
    [dbt_test_marts, recon_gate] >> render_email >> send_email
    [send_email] >> cleanup_key
