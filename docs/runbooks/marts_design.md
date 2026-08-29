# Marts design — retail_platform

Star schema, one fact at order-line grain plus a rollup, three dimensions
plus a date spine. Every model traces back to `stg_orders` /
`stg_worldbank_*`, which already carry the dedup flag and the
reconciliation trail — marts inherit both rather than reinventing them.

## Why this shape

**One fact at the finest grain (`fct_order_lines`), one rollup
(`fct_orders`).** Line-level answers "what was bought," order-level
answers "how many orders, how much per order" — collapsing to one table
would force every consumer to either lose line detail or re-aggregate it
themselves. Both are cheap to materialize as tables given the data
volume (tens of thousands of rows, not millions).

**Dedup happens once, in the fact, not repeated in every downstream
query.** `stg_orders.duplicate_occurrence` already tags which rows are
genuine repeats (ADR 0012's finding — real duplication, worst in Dec
2010 at 35.4%). Every mart filters `duplicate_occurrence = 1` at the
point of building `fct_order_lines`; nothing downstream needs to know
the flag exists at all.

**Recon doesn't stop at staging.** `ops.fct_pipeline_reconciliation`
proves source → S3 → Snowflake → staging agree. Marts need their own
check proving staging → marts agrees too — specifically, that the dedup
step dropped *exactly* the rows it should have and nothing else. That's
a new singular test, not a re-run of the existing one.

---

## Model list

```
marts/
├── dim_date.sql
├── dim_customer.sql
├── dim_product.sql
├── dim_country.sql
├── fct_order_lines.sql
├── fct_orders.sql
└── fct_revenue_monthly.sql
```

---

### `dim_date` — grain: one row per calendar day

Generated, not sourced — a spine covering the dataset's actual span
(Dec 2009–Dec 2011) plus a small buffer, built with `dbt_utils.date_spine`
(already available; the package is installed).

| column | purpose |
|---|---|
| `date_day` | PK |
| `year`, `month`, `month_name`, `quarter`, `day_of_week`, `day_name` | standard calendar breakdown |
| `is_weekend` | boolean |
| `is_month_end` | boolean — useful for "did revenue spike at month-end" questions |
| `period` | `YYYY-MM`, matches the join key used everywhere else in this project (`stg_orders.period`, `fct_pipeline_reconciliation.period`) |

**Tests:** `unique` + `not_null` on `date_day`.

---

### `dim_customer` — grain: one row per `customer_id`

Built from `fct_order_lines` (defined below) rather than directly from
staging, so its metrics are already dedup-correct by construction.

| column | purpose |
|---|---|
| `customer_id` | PK |
| `country` | customer's most frequent country (Online Retail II customers rarely span countries, but a `mode()` handles the edge case rather than assuming) |
| `first_order_date`, `last_order_date` | for recency |
| `customer_tenure_days` | `last_order_date - first_order_date` — 0 for one-time buyers, meaningful for repeat ones |
| `total_orders` | distinct `invoice_no` count, cancellations excluded |
| `total_line_items` | row count |
| `total_units_purchased` | `sum(quantity)`, cancellations excluded |
| `total_revenue` | `sum(line_amount)`, cancellations excluded |
| `total_cancelled_orders` | distinct cancelled `invoice_no` count |
| `cancellation_rate` | `total_cancelled_orders / nullif(total_orders + total_cancelled_orders, 0)` |
| `avg_order_value` | `total_revenue / nullif(total_orders, 0)` |
| `rfm_recency_days` | days between `last_order_date` and the dataset's max date (a fixed reference point, not `current_date` — the data is historical, "today" is meaningless here) |
| `rfm_frequency` | = `total_orders` |
| `rfm_monetary` | = `total_revenue` |
| `customer_segment` | simple tercile-based RFM label (`high_value`, `mid_value`, `low_value`) computed with `ntile(3)` over monetary — a real segmentation a stakeholder could act on, not decoration |

**Tests:**
- `unique`, `not_null` on `customer_id`
- `not_null` on `total_orders`, `total_revenue`
- `dbt_utils.accepted_range`: `cancellation_rate` between 0 and 1
- `accepted_values`: `customer_segment` in `['high_value','mid_value','low_value']`

---

### `dim_product` — grain: one row per `stock_code`

| column | purpose |
|---|---|
| `stock_code` | PK |
| `description` | most frequent description for that code — Online Retail II has the same stock code with slightly varying free-text descriptions across rows; picking the mode gives one stable label rather than an arbitrary first-seen value |
| `first_sold_date`, `last_sold_date` | product lifecycle |
| `total_units_sold` | cancellations excluded |
| `total_revenue` | cancellations excluded |
| `total_orders_containing` | distinct invoice count — "how many orders included this product," different from units sold |
| `avg_unit_price` | `avg(unit_price)` — Online Retail II prices for the same stock code do vary over time; average gives a representative figure, not a false single "the" price |
| `total_cancelled_units` | units cancelled, for a return-rate style metric |
| `cancellation_rate` | same shape as the customer version |

**Tests:**
- `unique`, `not_null` on `stock_code`
- `not_null` on `description`
- `dbt_utils.accepted_range`: `avg_unit_price` >= 0

---

### `dim_country` — grain: one row per retail country (from the mapping seed)

The model this project's earlier work (World Bank integration) was
building toward.

| column | purpose |
|---|---|
| `retail_country` | PK — the country string as it appears in the source data |
| `worldbank_country_id` | ISO3, from the seed |
| `mapping_type` | `exact` / `alias` / `assumed` / `unmappable` — carried through, not hidden, so a consumer knows how much to trust the enrichment for that row |
| `country_name` | World Bank's canonical name |
| `region_name`, `income_level_name` | from `stg_worldbank_countries` |
| `gdp_usd`, `population`, `gdp_per_capita_usd` | from `stg_worldbank_indicators`, pinned year |
| `total_orders`, `total_revenue`, `total_customers` | this project's own data, joined from `fct_order_lines` |
| `revenue_per_capita` | `total_revenue / nullif(population, 0)` — a genuinely interesting derived metric: which countries buy disproportionately to their size |

**Left join, not inner** — `unmappable` countries (Unspecified,
European Community, West Indies — 3 known cases per the earlier mapping
work) still get a row with null World Bank columns, rather than
silently vanishing from the dimension.

**Tests:**
- `unique`, `not_null` on `retail_country`
- `accepted_values`: `mapping_type` in the four known values
- The existing `assert_no_unmapped_countries.sql` singular test already
  covers the seed-to-World-Bank join integrity — reused here, not
  duplicated.

---

### `fct_order_lines` — grain: one row per genuine (deduplicated) order line

The dedup happens exactly once, here.

```sql
{{ config(materialized='table') }}

with staging as (
    select * from {{ ref('stg_orders') }}
    where duplicate_occurrence = 1   -- THE dedup. Nowhere else in marts repeats this filter.
)

select
    invoice_no,
    stock_code,
    customer_id,
    country,
    invoice_date,
    period,
    quantity,
    unit_price,
    line_amount,
    is_cancellation,
    line_type,
    source_system
from staging
```

| column | purpose |
|---|---|
| `invoice_no`, `stock_code` | composite natural key at this grain (with a row-generating surrogate if multiple identical lines legitimately exist post-dedup — see test below) |
| `customer_id`, `country` | FKs to `dim_customer`, `dim_country` |
| `period` | FK to `dim_date` (via period, not a direct date join, matching this project's existing period-based pattern) |
| `is_cancellation` | carried from staging — marts don't need to re-derive it |
| `line_amount` | the core revenue measure |

**Tests:**
- `not_null` on `invoice_no`, `stock_code`, `line_amount`
- `relationships`: `customer_id` → `dim_customer.customer_id` (where not null — Online Retail II has genuine null customer_ids for guest-style orders, not a data error)
- `relationships`: `country` → `dim_country.retail_country`
- **The new recon test** (below)

---

### `fct_orders` — grain: one row per `invoice_no`

Aggregates `fct_order_lines` up to the order.

| column | purpose |
|---|---|
| `invoice_no` | PK |
| `customer_id`, `country`, `period`, `invoice_date` | order-level attributes (taken once per invoice, not repeated per line) |
| `line_item_count` | number of distinct products on the order |
| `total_quantity` | `sum(quantity)` |
| `total_revenue` | `sum(line_amount)` |
| `is_cancelled_order` | true if **any** line on the invoice is a cancellation — Online Retail II cancellations are invoice-level events (a `C`-prefixed invoice number), so this should be consistent across all lines on that invoice; the test below verifies that consistency rather than assuming it |
| `avg_line_value` | `total_revenue / nullif(line_item_count, 0)` |

**Tests:**
- `unique`, `not_null` on `invoice_no`
- `dbt_utils.expression_is_true`: `line_item_count > 0`
- **New singular test:** `assert_cancellation_flag_consistent_per_invoice.sql`
  — every line on a given invoice has the same `is_cancellation` value.
  This is exactly the kind of "reuse the exceptions-testing pattern
  already established" you asked for: same shape as
  `assert_staging_matches_glue_recon` — group, compare, fail on
  disagreement — applied to a new invariant.

---

### `fct_revenue_monthly` — grain: one row per `period` × `country`

The actual business-facing rollup — what a dashboard would query.

| column | purpose |
|---|---|
| `period`, `country` | composite PK |
| `total_orders` | excluding cancellations |
| `total_revenue` | excluding cancellations |
| `total_units` | excluding cancellations |
| `total_customers` | distinct customers active that period-country |
| `cancelled_orders`, `cancelled_revenue` | shown separately, not netted silently — a stakeholder should see both the gross figure and what was reversed, not just a pre-netted number that hides cancellation volume |
| `revenue_mom_change` | month-over-month % change, via `lag()` over `period` within `country` — genuinely useful given the Dec 2010/Dec 2011 seasonality your data actually has |
| `is_first_period_for_country` | true for a country's first appearance — flags rows where `revenue_mom_change` is meaningless (no prior period to compare against), so a consumer doesn't misread a null/huge % change as a data error |

**Tests:**
- `dbt_utils.unique_combination_of_columns`: `[period, country]`
- `not_null` on `total_revenue`
- `dbt_utils.accepted_range`: `total_revenue` >= 0

---

## The marts-level reconciliation test — the new piece

`ops.fct_pipeline_reconciliation` proves source through staging agree.
Nothing currently proves **staging through marts** agree — specifically,
that `fct_order_lines`' dedup step removed exactly the duplicate rows
and nothing else.

```sql
-- tests/assert_marts_dedup_reconciles.sql
--
-- fct_order_lines should have EXACTLY as many rows, per period, as
-- stg_orders has rows where duplicate_occurrence = 1. Any difference
-- means the mart either dropped real rows or let duplicates through —
-- a second, independent check on the dedup logic, at the point it
-- actually gets used, not just where it's flagged.

with staging_deduped as (
    select period, count(*) as staging_count
    from {{ ref('stg_orders') }}
    where duplicate_occurrence = 1
    group by 1
),

marts_actual as (
    select period, count(*) as marts_count
    from {{ ref('fct_order_lines') }}
    group by 1
)

select
    s.period,
    s.staging_count,
    m.marts_count,
    s.staging_count - m.marts_count as diff
from staging_deduped s
join marts_actual m using (period)
where s.staging_count != m.marts_count
```

This is the marts equivalent of `assert_staging_matches_glue_recon` —
same pattern (join two independently-derived counts, fail on
disagreement), applied one layer further up the chain.

**A second one, checking revenue rather than row count:**

```sql
-- tests/assert_marts_revenue_reconciles.sql
--
-- Sum of line_amount in fct_order_lines should match the sum in
-- deduplicated staging exactly. Catches a class of bug row-count
-- checks miss entirely — e.g. a join that duplicates rows without
-- changing the count (impossible here, but the pattern is worth
-- having) or a rounding/casting error introduced in the mart layer.

with staging_deduped as (
    select period, sum(line_amount) as staging_revenue
    from {{ ref('stg_orders') }}
    where duplicate_occurrence = 1
    group by 1
),

marts_actual as (
    select period, sum(line_amount) as marts_revenue
    from {{ ref('fct_order_lines') }}
    group by 1
)

select
    s.period,
    s.staging_revenue,
    m.marts_revenue,
    abs(s.staging_revenue - m.marts_revenue) as diff
from staging_deduped s
join marts_actual m using (period)
where abs(s.staging_revenue - m.marts_revenue) > 0.01  -- float rounding tolerance
```

---

## Test matrix summary

| Model | Generic tests | Singular / dbt_utils |
|---|---|---|
| `dim_date` | unique, not_null on `date_day` | — |
| `dim_customer` | unique/not_null PK, accepted_values on segment | `dbt_utils.accepted_range` on cancellation_rate |
| `dim_product` | unique/not_null PK | `dbt_utils.accepted_range` on avg_unit_price |
| `dim_country` | unique/not_null PK, accepted_values on mapping_type | reuses `assert_no_unmapped_countries` |
| `fct_order_lines` | not_null, relationships to both dims | **`assert_marts_dedup_reconciles`**, **`assert_marts_revenue_reconciles`** |
| `fct_orders` | unique/not_null PK | `dbt_utils.expression_is_true`, **`assert_cancellation_flag_consistent_per_invoice`** |
| `fct_revenue_monthly` | not_null | `dbt_utils.unique_combination_of_columns`, `dbt_utils.accepted_range` |

Every dbt_utils test referenced is already available — `packages.yml`
already has `dbt_utils` installed and in use (`stg_worldbank_indicators`
already uses `unique_combination_of_columns`). No new package needed.

---

## Build order

Dependencies run this order automatically via `ref()`, but worth stating
explicitly since it's also the order I'd build and test in:

1. `dim_date` (no dependencies)
2. `dim_country` (depends on staging + seed, independent of the fact)
3. `fct_order_lines` (depends on `stg_orders` only)
4. `dim_customer`, `dim_product` (depend on `fct_order_lines`)
5. `fct_orders` (depends on `fct_order_lines`)
6. `fct_revenue_monthly` (depends on `fct_orders`, `dim_country`)
7. The two new recon tests (depend on `stg_orders` + `fct_order_lines`)

```bash
dbt run --select marts.dim_date marts.dim_country
dbt run --select marts.fct_order_lines
dbt test --select marts.fct_order_lines
dbt run --select marts.dim_customer marts.dim_product marts.fct_orders marts.fct_revenue_monthly
dbt test --select marts
```

Testing `fct_order_lines` before building anything downstream of it
means a dedup bug gets caught immediately, not after three more models
were built on top of a wrong foundation.
