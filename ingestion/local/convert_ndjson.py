#!/usr/bin/env python3
"""
Phase 1, Step 1 — Online Retail II: CSV -> daily NDJSON

Converts the raw Online Retail II CSV into one NDJSON file per invoice date,
laid out Hive-style so it can be uploaded straight to S3 as raw/bronze data.

Design rules (deliberate — these matter for the pipeline story):
  * Raw stays raw. Cancellations, negative quantities, null customer IDs and
    duplicates are NOT cleaned here. That belongs in dbt staging.
  * NDJSON (one object per line), never a JSON array — Spark/Glue/Snowflake
    all read NDJSON natively.
  * Customer ID is cast to a nullable string, otherwise pandas emits 17850.0
    and you spend an evening cleaning float artefacts in dbt for no reason.
  * Each record gets an ingested_at timestamp and a source tag so the batch
    and streaming paths can be told apart after they're unioned.

Usage:
    python convert_to_ndjson.py --input data/raw/online_retail_II.csv \
                                --outdir data/json
    python convert_to_ndjson.py --input ... --outdir ... --stream-days 30
"""

import argparse
import json
import pathlib
import sys
from datetime import datetime, timezone

import pandas as pd

# The Kaggle (mashlyn) version and the original UCI version use different
# column names for the same fields. Normalise to snake_case either way.
COLUMN_MAP = {
    "Invoice": "invoice_no",
    "InvoiceNo": "invoice_no",
    "StockCode": "stock_code",
    "Description": "description",
    "Quantity": "quantity",
    "InvoiceDate": "invoice_date",
    "Price": "unit_price",
    "UnitPrice": "unit_price",
    "Customer ID": "customer_id",
    "CustomerID": "customer_id",
    "Country": "country",
}

EXPECTED = [
    "invoice_no",
    "stock_code",
    "description",
    "quantity",
    "invoice_date",
    "unit_price",
    "customer_id",
    "country",
]


def load(path: pathlib.Path) -> pd.DataFrame:
    if not path.exists():
        sys.exit(f"Input file not found: {path}")

    # ISO-8859-1: the descriptions contain characters that break utf-8.
    df = pd.read_csv(path, encoding="ISO-8859-1", low_memory=False)
    df = df.rename(columns=COLUMN_MAP)

    missing = [c for c in EXPECTED if c not in df.columns]
    if missing:
        sys.exit(f"Missing expected columns after rename: {missing}\n"
                 f"Columns found: {list(df.columns)}")

    return df[EXPECTED]


def prepare(df: pd.DataFrame) -> pd.DataFrame:
    df["invoice_date"] = pd.to_datetime(df["invoice_date"], errors="coerce")

    bad_dates = df["invoice_date"].isna().sum()
    if bad_dates:
        print(f"  ! {bad_dates} rows have unparseable dates — dropping them "
              f"(they cannot be partitioned)")
        df = df[df["invoice_date"].notna()].copy()

    # Nullable string, not float. 17850 not 17850.0, and None stays None.
    df["customer_id"] = (
        df["customer_id"]
        .astype("Float64")
        .astype("Int64")
        .astype("string")
    )

    df["invoice_no"] = df["invoice_no"].astype("string")
    df["stock_code"] = df["stock_code"].astype("string")

    # Lineage columns — these earn their keep when you union batch + stream.
    df["source_system"] = "batch_historical"
    df["ingested_at"] = datetime.now(timezone.utc).isoformat()

    df["event_date"] = df["invoice_date"].dt.date
    return df


def write_partitions(df: pd.DataFrame, outdir: pathlib.Path, subdir: str) -> int:
    written = 0
    for day, chunk in df.groupby("event_date", sort=True):
        part = outdir / subdir / f"event_date={day}"
        part.mkdir(parents=True, exist_ok=True)

        records = chunk.drop(columns=["event_date"]).to_dict(orient="records")
        with open(part / "orders.json", "w", encoding="utf-8") as f:
            for r in records:
                r["invoice_date"] = r["invoice_date"].isoformat()
                # pandas NA -> JSON null
                r = {k: (None if pd.isna(v) else v) for k, v in r.items()}
                f.write(json.dumps(r) + "\n")
        written += 1
    return written


def profile(df: pd.DataFrame) -> None:
    """Print the messiness you'll be handling in dbt staging. Write these
    numbers down — they become your data quality test thresholds."""
    total = len(df)
    print("\n--- Raw data profile (do not fix these here) ---")
    print(f"  rows                     : {total:,}")
    print(f"  date range               : {df['invoice_date'].min().date()} "
          f"-> {df['invoice_date'].max().date()}")
    print(f"  distinct invoices        : {df['invoice_no'].nunique():,}")
    print(f"  distinct customers       : {df['customer_id'].nunique():,}")
    print(f"  distinct countries       : {df['country'].nunique()}")
    print(f"  null customer_id         : {df['customer_id'].isna().sum():,} "
          f"({df['customer_id'].isna().mean():.1%})")
    print(f"  negative quantity        : {(df['quantity'] < 0).sum():,}")
    print(f"  zero/negative unit_price : {(df['unit_price'] <= 0).sum():,}")
    print(f"  cancellations (invoice C): "
          f"{df['invoice_no'].str.startswith('C', na=False).sum():,}")
    print(f"  exact duplicate rows     : {df.duplicated().sum():,}")
    print("-----------------------------------------------\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="data/raw/online_retail_II.csv")
    ap.add_argument("--outdir", default="data/json")
    ap.add_argument(
        "--stream-days",
        type=int,
        default=0,
        help="Hold back the last N days into a separate stream/ folder, to be "
             "replayed later through Kinesis Firehose instead of batch.",
    )
    args = ap.parse_args()

    inp = pathlib.Path(args.input)
    outdir = pathlib.Path(args.outdir)

    print(f"Reading {inp} ...")
    df = prepare(load(inp))
    profile(df)

    if args.stream_days > 0:
        cutoff = sorted(df["event_date"].unique())[-args.stream_days]
        batch_df = df[df["event_date"] < cutoff]
        stream_df = df[df["event_date"] >= cutoff].copy()
        stream_df["source_system"] = "stream_live"
        print(f"Splitting at {cutoff}: last {args.stream_days} days reserved "
              f"for the streaming path")
    else:
        batch_df, stream_df = df, None

    n = write_partitions(batch_df, outdir, "batch")
    print(f"Wrote {n} daily batch partitions to {outdir / 'batch'} "
          f"({len(batch_df):,} rows)")

    if stream_df is not None and len(stream_df):
        n = write_partitions(stream_df, outdir, "stream")
        print(f"Wrote {n} daily stream partitions to {outdir / 'stream'} "
              f"({len(stream_df):,} rows)")

    print("\nNext: sanity-check one file with\n"
          f"  head -n 2 {outdir}/batch/event_date=*/orders.json | head -n 5")


if __name__ == "__main__":
    main()
