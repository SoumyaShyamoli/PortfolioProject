#!/usr/bin/env bash
#
# EC2 user_data — runs ONCE on first boot only. A stop/start cycle does NOT
# re-run this; installed state persists on the root volume across a pause.
# Re-running manually is idempotent (safe to repeat) after a fix.
#
# Installs Airflow with SequentialExecutor + SQLite. See ADR 0014: this
# pipeline is one linear DAG, so paying for parallelism (in memory, on a
# t3.small) that is never used is the wrong trade.
#
# LOGGING: a plain `exec > file 2>&1` redirect — see ADR 0015's amendment
# for why `exec > >(tee file) 2>&1` caused cloud-init to report success
# before any real command had run.
#
# PACKAGE INSTALL — three passes, matching scripts/build_wheelhouse.sh.
# See ADR 0015 for the full reasoning (explicit version pinning, local
# constraints file, the dbt-core-experimental-parser wheel).
#
# NO SMTP configuration — deliberately. See ADR 0014's third amendment:
# email alerting was scoped out, not deferred by accident. The DAG's
# send_email task will fail every run until/unless this is revisited; that
# is expected and does not block anything else (cleanup_key has
# trigger_rule=all_done and runs regardless).

set -euo pipefail
exec > /var/log/airflow-bootstrap.log 2>&1

ENVIRONMENT="${environment}"
AWS_REGION="${aws_region}"
S3_STAGED_BUCKET="${s3_staged_bucket}"

echo "=== Bootstrapping Airflow for environment: $ENVIRONMENT ==="
date -u

# --- System packages -------------------------------------------------------

dnf update -y
dnf install -y python3.11 python3.11-pip git jq

useradd -m -s /bin/bash airflow || true
mkdir -p /opt/airflow
chown airflow:airflow /opt/airflow

echo "=== System packages done ==="
date -u

# --- Python environment ------------------------------------------------------

sudo -u airflow python3.11 -m venv /opt/airflow/venv

AIRFLOW_VERSION="2.10.5"
PYTHON_VERSION="3.11"

# --- Fetch the wheelhouse from S3, not PyPI --------------------------------

WHEELHOUSE_DIR=/opt/airflow/wheelhouse
mkdir -p "$WHEELHOUSE_DIR"

aws s3 sync "s3://$S3_STAGED_BUCKET/_wheelhouse/" "$WHEELHOUSE_DIR" \
  --only-show-errors --region "$AWS_REGION"

echo "=== Wheelhouse synced from S3 ==="
date -u

CONSTRAINT_FILE="$WHEELHOUSE_DIR/constraints.txt"
if [ ! -f "$CONSTRAINT_FILE" ]; then
  echo "FATAL: $CONSTRAINT_FILE not found in the synced wheelhouse." >&2
  exit 1
fi

sudo -u airflow /opt/airflow/venv/bin/pip install \
  --no-index --find-links "$WHEELHOUSE_DIR" \
  --upgrade pip

sudo -u airflow /opt/airflow/venv/bin/pip install \
  --no-index --find-links "$WHEELHOUSE_DIR" \
  "apache-airflow==$${AIRFLOW_VERSION}" \
  --constraint "$CONSTRAINT_FILE"

echo "=== Pass 1 (Airflow core) installed ==="
date -u

sudo -u airflow /opt/airflow/venv/bin/pip install \
  --no-index --find-links "$WHEELHOUSE_DIR" \
  "apache-airflow==$${AIRFLOW_VERSION}" \
  apache-airflow-providers-amazon \
  apache-airflow-providers-smtp \
  --constraint "$CONSTRAINT_FILE"

echo "=== Pass 2 (providers, pinned to $AIRFLOW_VERSION) installed ==="
date -u

sudo -u airflow /opt/airflow/venv/bin/pip install \
  --no-index --find-links "$WHEELHOUSE_DIR" \
  dbt-core \
  dbt-snowflake \
  snowflake-connector-python \
  boto3

echo "=== Pass 3 (dbt/Snowflake/boto3) installed ==="
date -u

INSTALLED_VERSION=$(/opt/airflow/venv/bin/airflow version)
echo "Installed Airflow version: $INSTALLED_VERSION"
if [ "$INSTALLED_VERSION" != "$AIRFLOW_VERSION" ]; then
  echo "FATAL: expected Airflow $AIRFLOW_VERSION, got $INSTALLED_VERSION" >&2
  exit 1
fi

echo "=== Python packages done, version verified: $INSTALLED_VERSION ==="
date -u

# --- Airflow configuration -------------------------------------------------

export AIRFLOW_HOME=/opt/airflow

sudo -u airflow AIRFLOW_HOME=/opt/airflow /opt/airflow/venv/bin/airflow db init

mkdir -p /opt/airflow/dags
chown -R airflow:airflow /opt/airflow

echo "=== Airflow config done ==="
date -u

# --- systemd services --------------------------------------------------------

cat > /etc/systemd/system/airflow-scheduler.service <<UNITEOF
[Unit]
Description=Airflow Scheduler - $ENVIRONMENT
After=network.target

[Service]
User=airflow
# SequentialExecutor spawns task subprocesses by invoking the bare command
# "airflow" (not a full path) — see sequential_executor.py's sync(). Without
# PATH including the venv's bin directory, every task subprocess launch
# fails with FileNotFoundError, the scheduler crashes, systemd restarts it
# (silently, per Restart=on-failure below), and every queued task is
# orphaned forever with no visible error anywhere except journalctl. Found
# 2026-08-31 — the scheduler itself starts fine (ExecStart uses a full
# path), only task execution inside it was broken, which is why this
# looked like a stuck/queued-task problem rather than a PATH problem at
# first.
Environment=PATH=/opt/airflow/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=AIRFLOW_HOME=/opt/airflow
Environment=RETAIL_ENVIRONMENT=$ENVIRONMENT
Environment=AWS_DEFAULT_REGION=$AWS_REGION
Environment=AIRFLOW__CORE__EXECUTOR=SequentialExecutor
Environment=AIRFLOW__CORE__LOAD_EXAMPLES=False
Environment=AIRFLOW__CORE__DAGS_FOLDER=/opt/airflow/dags
Environment=AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=sqlite:////opt/airflow/airflow.db
ExecStart=/opt/airflow/venv/bin/airflow scheduler
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNITEOF

cat > /etc/systemd/system/airflow-webserver.service <<UNITEOF
[Unit]
Description=Airflow Webserver - $ENVIRONMENT
After=network.target

[Service]
User=airflow
Environment=PATH=/opt/airflow/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=AIRFLOW_HOME=/opt/airflow
Environment=RETAIL_ENVIRONMENT=$ENVIRONMENT
Environment=AIRFLOW__CORE__EXECUTOR=SequentialExecutor
Environment=AIRFLOW__CORE__LOAD_EXAMPLES=False
Environment=AIRFLOW__CORE__DAGS_FOLDER=/opt/airflow/dags
Environment=AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=sqlite:////opt/airflow/airflow.db
ExecStart=/opt/airflow/venv/bin/airflow webserver --port 8080
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable airflow-scheduler airflow-webserver
systemctl start airflow-scheduler airflow-webserver

echo "=== systemd services started ==="
date -u
echo "=== Bootstrap complete for $ENVIRONMENT ==="
