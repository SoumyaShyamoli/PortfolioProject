"""
Lambda: fetch World Bank country reference data into the raw bucket.

Pulls three things and writes each as NDJSON to raw/worldbank/:
  * country metadata  — ISO codes, region, income group, capital, lat/long
  * GDP (current US$) — NY.GDP.MKTP.CD
  * total population  — SP.POP.TOTL

Design notes:
  * Runs OUTSIDE the VPC. The private subnets have no NAT and no internet
    gateway (ADR 0003), so anything needing the public internet is placed
    outside deliberately. This is that case.
  * No third-party dependencies. urllib.request from the standard library
    rather than requests, so the function is a plain .py file with no layer
    or vendored zip to manage.
  * Aggregates ("World", "Euro area", "Arab World") are NOT filtered out.
    Raw takes what the API returns; filtering happens in dbt (ADR 0005).
    They are identifiable downstream by region.id == "NA".
  * Overwrites the same keys on every run rather than snapshotting. Reference
    data is current-state, not an event stream, and the indicator values are
    pinned to a fixed year, so there is no history worth accumulating. This
    is a deliberate exception to raw immutability — noted in the audit record.
  * Reconciliation: records fetched must equal records written, asserted per
    dataset. Same discipline as the Glue job, appropriate to the scale.

Environment variables:
  RAW_BUCKET        target bucket (required)
  INDICATOR_YEAR    year for GDP/population, default 2010 (mid-dataset)
"""

import json
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone

import boto3

API_BASE = "https://api.worldbank.org/v2"
PER_PAGE = 400          # comfortably above the ~300 country records
TIMEOUT_SECONDS = 20
MAX_RETRIES = 3

s3 = boto3.client("s3")


# -------------------------------------------------------------------------
# HTTP
# -------------------------------------------------------------------------

def _get_json(url: str) -> list:
    """GET a URL and parse JSON, with a bounded retry on transient failure.

    The World Bank API is free and occasionally slow. Retrying blindly on a
    4xx would be pointless, so only 5xx and network errors are retried.
    """
    last_error = None

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "retail-data-platform/1.0"}
            )
            with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
                return json.loads(resp.read().decode("utf-8"))

        except urllib.error.HTTPError as e:
            if e.code < 500:
                raise  # client error — retrying will not help
            last_error = e
            print(f"  attempt {attempt}: HTTP {e.code}, retrying")

        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
            last_error = e
            print(f"  attempt {attempt}: {type(e).__name__}, retrying")

    raise RuntimeError(f"Failed after {MAX_RETRIES} attempts: {url}") from last_error


def _fetch_all_pages(path: str, extra: str = "") -> list:
    """Fetch every page of a World Bank endpoint.

    The response is a two-element array: [pagination_metadata, records].
    Paginating matters even though one page currently suffices — the country
    count is not fixed, and a silent truncation at page 1 would be invisible.
    """
    records = []
    page = 1

    while True:
        url = f"{API_BASE}/{path}?format=json&per_page={PER_PAGE}&page={page}{extra}"
        print(f"GET {url}")
        payload = _get_json(url)

        if not isinstance(payload, list) or len(payload) < 2:
            # The API returns a single-element array containing a message
            # object when a query is malformed, rather than an HTTP error.
            raise ValueError(f"Unexpected response shape from {url}: {payload}")

        meta, batch = payload[0], payload[1]

        if batch is None:
            raise ValueError(f"No records returned from {url}")

        records.extend(batch)

        total_pages = int(meta.get("pages", 1))
        if page >= total_pages:
            print(f"  fetched {len(records)} records across {total_pages} page(s)")
            return records

        page += 1


# -------------------------------------------------------------------------
# Transform + write
# -------------------------------------------------------------------------

def _flatten_country(rec: dict, ingested_at: str) -> dict:
    """Flatten the nested country record.

    The API nests region, adminregion, incomeLevel and lendingType as
    {id, iso2code, value} objects. Flattening here is a structural change,
    not a cleaning one — no rows are dropped and no values are altered.
    """
    def nested(key, field):
        obj = rec.get(key) or {}
        return obj.get(field)

    return {
        "country_id": rec.get("id"),            # ISO3
        "iso2_code": rec.get("iso2Code"),
        "country_name": rec.get("name"),
        "region_id": nested("region", "id"),    # "NA" marks an aggregate
        "region_name": nested("region", "value"),
        "admin_region_id": nested("adminregion", "id"),
        "income_level_id": nested("incomeLevel", "id"),
        "income_level_name": nested("incomeLevel", "value"),
        "lending_type_id": nested("lendingType", "id"),
        "capital_city": rec.get("capitalCity") or None,
        "longitude": rec.get("longitude") or None,
        "latitude": rec.get("latitude") or None,
        "source_system": "worldbank_api",
        "ingested_at": ingested_at,
    }


def _flatten_indicator(rec: dict, ingested_at: str) -> dict:
    return {
        "country_id": (rec.get("countryiso3code") or None),
        "country_name": (rec.get("country") or {}).get("value"),
        "indicator_id": (rec.get("indicator") or {}).get("id"),
        "indicator_name": (rec.get("indicator") or {}).get("value"),
        "year": rec.get("date"),
        "value": rec.get("value"),              # null is normal and preserved
        "source_system": "worldbank_api",
        "ingested_at": ingested_at,
    }


def _write_ndjson(bucket: str, key: str, rows: list) -> int:
    """Write rows as NDJSON and return the number of lines written."""
    body = "\n".join(json.dumps(r) for r in rows) + "\n"
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=body.encode("utf-8"),
        ContentType="application/x-ndjson",
    )
    return len(rows)


# -------------------------------------------------------------------------
# Handler
# -------------------------------------------------------------------------

def lambda_handler(event, context):
    bucket = os.environ["RAW_BUCKET"]
    year = os.environ.get("INDICATOR_YEAR", "2010")
    ingested_at = datetime.now(timezone.utc).isoformat()

    prefix = "worldbank"
    results = {}

    # --- countries -------------------------------------------------------
    raw_countries = _fetch_all_pages("country")
    countries = [_flatten_country(r, ingested_at) for r in raw_countries]
    written = _write_ndjson(bucket, f"{prefix}/countries/countries.json", countries)
    results["countries"] = {
        "fetched": len(raw_countries),
        "written": written,
        "key": f"{prefix}/countries/countries.json",
        # Recorded, not filtered — see ADR 0005.
        "aggregates_included": sum(1 for c in countries if c["region_id"] == "NA"),
    }

    # --- indicators ------------------------------------------------------
    indicators = {
        "gdp": "NY.GDP.MKTP.CD",
        "population": "SP.POP.TOTL",
    }

    for name, code in indicators.items():
        raw_rows = _fetch_all_pages(
            f"country/all/indicator/{code}", extra=f"&date={year}"
        )
        rows = [_flatten_indicator(r, ingested_at) for r in raw_rows]
        key = f"{prefix}/{name}/{name}_{year}.json"
        written = _write_ndjson(bucket, key, rows)
        results[name] = {
            "fetched": len(raw_rows),
            "written": written,
            "key": key,
            "indicator_code": code,
            "year": year,
            # A null value means the World Bank has no figure for that
            # country-year. Expected, and worth knowing the scale of.
            "null_values": sum(1 for r in rows if r["value"] is None),
        }

    # --- reconciliation --------------------------------------------------
    # Fetched must equal written for every dataset. Trivially true unless
    # something is wrong, which is exactly the point of asserting it.

    mismatches = [
        f"{name}: fetched {r['fetched']} != written {r['written']}"
        for name, r in results.items()
        if r["fetched"] != r["written"]
    ]

    audit = {
        "job_name": "worldbank-reference-pull",
        "request_id": getattr(context, "aws_request_id", "local"),
        "ingested_at": ingested_at,
        "indicator_year": year,
        "datasets": results,
        "balanced": not mismatches,
        # Reference data overwrites in place rather than accumulating
        # partitions — a deliberate exception to raw immutability.
        "write_mode": "overwrite_in_place",
    }

    s3.put_object(
        Bucket=bucket,
        Key=f"_audit/worldbank/{ingested_at[:10]}/{audit['request_id']}.json",
        Body=json.dumps(audit, indent=2).encode("utf-8"),
        ContentType="application/json",
    )

    print("RECON_RESULT " + json.dumps(audit))

    if mismatches:
        raise ValueError("RECONCILIATION FAILED: " + "; ".join(mismatches))

    return {"statusCode": 200, "body": json.dumps(audit)}


if __name__ == "__main__":
    # Local run: RAW_BUCKET=... python fetch_worldbank.py
    print(json.dumps(lambda_handler({}, None), indent=2))
