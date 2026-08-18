flowchart TD

    A[Raw CSV: online_retail_II.csv] --> B[Load CSV<br/>- Read ISO-8859-1<br/>- Rename columns<br/>- Validate schema]

    B --> C[Prepare DataFrame<br/>- Parse dates<br/>- Cast IDs to string<br/>- Add lineage columns<br/>- Derive event_date]

    C --> D[Profile Raw Data<br/>- Nulls, negatives<br/>- Duplicates<br/>- Distinct counts<br/>- Date range]

    D --> E{--stream-days > 0?}

    E -->|No| F[Batch DF = All Rows]
    E -->|Yes| G[Split Batch vs Stream<br/>- Last N days → stream_df<br/>- Mark source_system]

    F --> H[Write Daily Partitions<br/>batch/event_date=YYYY-MM-DD/orders.json]
    G --> H
    G --> I[Write Daily Partitions<br/>stream/event_date=YYYY-MM-DD/orders.json]

    H --> J[S3 Bronze Layer<br/>batch/…]
    I --> K[S3 Bronze Layer<br/>stream/…]
