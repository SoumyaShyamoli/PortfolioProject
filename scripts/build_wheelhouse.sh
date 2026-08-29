#!/usr/bin/env bash
#
# Builds a wheelhouse — every Python package the Airflow instances need,
# downloaded once from a machine with internet access, uploaded to S3, and
# installed from there instead of PyPI. See ADR 0015.
#
# THREE passes:
#
#   1. Airflow core alone, under its constraints file.
#   2. Airflow core AGAIN, explicitly, ALONGSIDE the providers, under the
#      SAME constraints file. Redundant-looking, and deliberate: when
#      providers were downloaded without also explicitly naming
#      apache-airflow on that same command line, pip pulled Airflow in only
#      TRANSITIVELY (as a provider dependency, ">=2.9.0") and picked
#      whatever the newest satisfying version was — 3.3.1 the first time
#      (constraint dropped entirely), 2.11.0 the second time (constraint
#      applied but Airflow itself not explicitly pinned in that command).
#      Naming the exact version explicitly in EVERY command that touches
#      Airflow's dependency graph is what actually pins it — a constraints
#      file limits what a resolver MAY pick from candidates already in
#      play, it does not by itself put a specific package version in play
#      if nothing on that command line asked for it.
#   3. dbt / Snowflake / boto3 — a separate ecosystem, no shared
#      constraints file. Mixing it into passes 1-2 previously produced an
#      unrelated dependency conflict
#
# PLUS one manual fetch: the wheel dbt-core-experimental-parser's build
# backend otherwise tries (and fails, offline) to pull directly from
# GitHub See the header comment on that section below

set -euo pipefail

: "${AWS_PROFILE:=retail-dev}"
export AWS_PROFILE

ACCOUNT="009073574996"
REGION="eu-west-2"
AIRFLOW_VERSION="2.10.5"
PYTHON_VERSION="3.11"
CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"
EXPERIMENTAL_PARSER_URL="https://github.com/dbt-labs/dbt-core/releases/download/v2.0.0-beta.2/dbt_core_experimental_parser-2.0.0b2-py3-none-manylinux_2_28_x86_64.whl"

BUILD_DIR="$(pwd)/.wheelhouse-build"
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

echo "Building wheelhouse in $BUILD_DIR"
echo "Target: apache-airflow==${AIRFLOW_VERSION}, python ${PYTHON_VERSION}"

# --- Fetch the constraints file itself, not just the packages it pins ----
#
# `--no-index` on the instance stops pip reaching PyPI for PACKAGES, but
# `--constraint <URL>` is a separate HTTP fetch pip makes to READ the
# constraints file — that fetch is not covered by --no-index at all, and
# the instance has no route to raw.githubusercontent.com any more than it
# has one to pypi.org (ADR 0003). Saved locally here and shipped in the
# wheelhouse so the instance references a local path instead of a URL.
curl -fL -o "$BUILD_DIR/constraints.txt" "$CONSTRAINT_URL"
echo "=== Constraints file fetched ==="

# --- Pass 1: Airflow core alone -------------------------------------------

python3 -m pip download \
  --dest "$BUILD_DIR" \
  --platform manylinux2014_x86_64 \
  --python-version "$PYTHON_VERSION" \
  --implementation cp \
  --only-binary=:all: \
  "apache-airflow==${AIRFLOW_VERSION}" \
  --constraint "$BUILD_DIR/constraints.txt"

echo "=== Pass 1 (Airflow core) done ==="

# --- Pass 2: Airflow core (explicit, again) + providers, same constraint --
# The explicit "apache-airflow==${AIRFLOW_VERSION}" here is NOT redundant
# with pass 1 — it is what forces THIS resolution to solve against exactly
# that version rather than treating Airflow as a free transitive dependency
# of the providers.

python3 -m pip download \
  --dest "$BUILD_DIR" \
  --platform manylinux2014_x86_64 \
  --python-version "$PYTHON_VERSION" \
  --implementation cp \
  --only-binary=:all: \
  "apache-airflow==${AIRFLOW_VERSION}" \
  apache-airflow-providers-amazon \
  apache-airflow-providers-smtp \
  --constraint "$BUILD_DIR/constraints.txt"

echo "=== Pass 2 (providers, pinned to ${AIRFLOW_VERSION}) done ==="

# --- Pass 3: dbt / Snowflake / boto3, separate ecosystem ------------------

python3 -m pip download \
  --dest "$BUILD_DIR" \
  --platform manylinux2014_x86_64 \
  --python-version "$PYTHON_VERSION" \
  --implementation cp \
  --only-binary=:all: \
  dbt-core \
  dbt-snowflake \
  snowflake-connector-python \
  boto3

echo "=== Pass 3 (dbt/Snowflake/boto3) done ==="

# --- Manual fetch: dbt-core-experimental-parser ----------------------------
# Ships with no published wheel; its build backend fetches this exact file
# from GitHub AT BUILD TIME (not download time), which fails on an instance
# with no internet route. Fetched here, on a machine that has internet, and
# placed directly in the wheelhouse so pip finds a pre-built wheel and never
# triggers that build step at all.

curl -fL -o "$BUILD_DIR/$(basename "$EXPERIMENTAL_PARSER_URL")" "$EXPERIMENTAL_PARSER_URL"

echo "=== Experimental parser wheel fetched ==="

# --- Verify what actually landed, before uploading anywhere ---------------
# Cheap and non-negotiable given history: confirm the wheelhouse contains
# EXACTLY the target version and nothing from the 3.x line, before this
# gets uploaded and an instance bootstraps against it.

FOUND_AIRFLOW=$(find "$BUILD_DIR" -maxdepth 1 -iname "apache_airflow-*.whl" -printf '%f\n')
echo "Airflow wheel(s) in build dir: $FOUND_AIRFLOW"

if ! echo "$FOUND_AIRFLOW" | grep -q "apache_airflow-${AIRFLOW_VERSION}-"; then
  echo "FATAL: expected apache_airflow-${AIRFLOW_VERSION}-*.whl in the wheelhouse, did not find it." >&2
  echo "Found instead: $FOUND_AIRFLOW" >&2
  exit 1
fi

if echo "$FOUND_AIRFLOW" | grep -qE "apache_airflow-3\."; then
  echo "FATAL: an apache-airflow 3.x wheel is present in the wheelhouse — refusing to upload." >&2
  exit 1
fi

echo "=== Version check passed: ${AIRFLOW_VERSION}, no 3.x wheels present ==="

COUNT=$(find "$BUILD_DIR" -name "*.whl" -o -name "*.tar.gz" | wc -l)
echo "Wheelhouse contains $COUNT package files."

for ENV in "$@"; do
  BUCKET="sd-retail-${ENV}-staged-${ACCOUNT}-${REGION}-an"
  echo "Uploading to s3://${BUCKET}/_wheelhouse/"
  aws s3 sync "$BUILD_DIR" "s3://${BUCKET}/_wheelhouse/" \
    --delete --only-show-errors --profile "$AWS_PROFILE"
done

echo "Done."
