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
# LOGGING: a plain `exec > file 2>&1` redirect, not
# `exec > >(tee file) 2>&1` — the latter's process substitution created a
# background subshell whose completion cloud-init did not reliably wait on,
# making the script appear to finish in seconds with almost nothing
# actually run. Confirmed on this exact AMI.
#
# PACKAGE INSTALL — three passes, matching scripts/build_wheelhouse.sh:
#
#   1. Airflow core alone, under its constraints file.
#   2. Airflow core AGAIN, explicitly, alongside the providers, under the
#      SAME constraints file. The explicit re-statement of the exact
#      version is what pins it — installing providers alone let pip treat
#      Airflow as a free transitive dependency and pick whatever newest
#      version satisfied the provider's own minimum, which drifted to 3.x
#      once and to a different 2.x minor once. See ADR 0015 (amendment).
#   3. dbt / Snowflake / boto3, unconstrained, separate ecosystem.
#
# All three install from the local wheelhouse only (--no-index), which
# includes a manually-fetched wheel for dbt-core-experimental-parser — see
# build_wheelhouse.sh for why that is needed.

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
# No route from this subnet to pypi.org at all (ADR 0003/0015).

WHEELHOUSE_DIR=/opt/airflow/wheelhouse
mkdir -p "$WHEELHOUSE_DIR"

aws s3 sync "s3://$S3_STAGED_BUCKET/_wheelhouse/" "$WHEELHOUSE_DIR" \
  --only-show-errors --region "$AWS_REGION"

echo "=== Wheelhouse synced from S3 ==="
date -u

# `--constraint <URL>` is a SEPARATE network fetch from the package
# installs below — --no-index/--find-links only cover where pip looks for
# PACKAGES, not this. There is no route from this subnet to
# raw.githubusercontent.com any more than there is to pypi.org (ADR 0003).
# The constraints file was downloaded during the wheelhouse build (where
# there is internet) and synced here as constraints.txt alongside the
# packages — reference that local file, never the remote URL, on this box.
CONSTRAINT_FILE="$WHEELHOUSE_DIR/constraints.txt"
if [ ! -f "$CONSTRAINT_FILE" ]; then
  echo "FATAL: $CONSTRAINT_FILE not found in the synced wheelhouse." >&2
  exit 1
fi

sudo -u airflow /opt/airflow/venv/bin/pip install \
  --no-index --find-links "$WHEELHOUSE_DIR" \
  --upgrade pip

# Pass 1 — Airflow core alone, under its constraints file.
sudo -u airflow /opt/airflow/venv/bin/pip install \
  --no-index --find-links "$WHEELHOUSE_DIR" \
  "apache-airflow==$${AIRFLOW_VERSION}" \
  --constraint "$CONSTRAINT_FILE"

echo "=== Pass 1 (Airflow core) installed ==="
date -u

# Pass 2 — Airflow core (explicit, again) + providers, same constraint.
# The re-statement of the exact version is what pins it — see header.
sudo -u airflow /opt/airflow/venv/bin/pip install \
  --no-index --find-links "$WHEELHOUSE_DIR" \
  "apache-airflow==$${AIRFLOW_VERSION}" \
  apache-airflow-providers-amazon \
  apache-airflow-providers-smtp \
  --constraint "$CONSTRAINT_FILE"

echo "=== Pass 2 (providers, pinned to $AIRFLOW_VERSION) installed ==="
date -u

# Pass 3 — dbt / Snowflake / boto3, unconstrained.
sudo -u airflow /opt/airflow/venv/bin/pip install \
  --no-index --find-links "$WHEELHOUSE_DIR" \
  dbt-core \
  dbt-snowflake \
  snowflake-connector-python \
  boto3

echo "=== Pass 3 (dbt/Snowflake/boto3) installed ==="
date -u

# --- Verify the version that actually landed --------------------------------
# Non-negotiable given history: fail loudly rather than proceed to
# systemd on a silently wrong Airflow version.
INSTALLED_VERSION=$(/opt/airflow/venv/bin/airflow version)
echo "Installed Airflow version: $INSTALLED_VERSION"
if [ "$INSTALLED_VERSION" != "$AIRFLOW_VERSION" ]; then
  echo "FATAL: expected Airflow $AIRFLOW_VERSION, got $INSTALLED_VERSION" >&2
  exit 1
fi

echo "=== Python packages done, version verified: $INSTALLED_VERSION ==="
date -u

# --- Airflow configuration -------------------------------------------------
#
# Set via AIRFLOW__SECTION__KEY environment variables on the systemd units,
# not an airflow.cfg.d directory — Airflow has no such directory-of-
# fragments mechanism; that was a mistaken carryover from other tools
# (nginx, systemd) that do work that way. Environment variables are
# Airflow's actual, documented override mechanism and take precedence over
# airflow.cfg without needing to edit that file at all.

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
