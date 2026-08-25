# Snowflake setup

DDL run once by hand, committed here for reproducibility and review.

Per ADR 0011, Snowflake objects that live purely inside Snowflake are managed
as committed SQL rather than Terraform. Anything spanning AWS and Snowflake —
currently just the storage integration — is Terraform, because that is where
the coordination problem is.

## Run order

| File | What it does | Run as |
|---|---|---|
| `01_warehouse_and_databases.sql` | Warehouse, two databases, five schemas each | ACCOUNTADMIN |
| `02_roles_and_grants.sql` | Transformer role per environment, reader role | ACCOUNTADMIN |
| `03_users_and_keys.sql` | Users, RSA public key registration, defaults | ACCOUNTADMIN |

Storage integration comes after these, from Terraform.

## Before running 03

Generate two key pairs locally:

```bash
mkdir -p ~/.snowflake

openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM \
  -out ~/.snowflake/rsa_key_dev.p8 -nocrypt
openssl rsa -in ~/.snowflake/rsa_key_dev.p8 -pubout \
  -out ~/.snowflake/rsa_key_dev.pub

openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM \
  -out ~/.snowflake/rsa_key_prod.p8 -nocrypt
openssl rsa -in ~/.snowflake/rsa_key_prod.p8 -pubout \
  -out ~/.snowflake/rsa_key_prod.pub
```

Push both private keys to SSM — SSM is the source of truth, the local copy is
a cache:

```bash
aws ssm put-parameter --name "/retail/dev/snowflake/private_key" \
  --type SecureString --value "$(cat ~/.snowflake/rsa_key_dev.p8)" \
  --overwrite --profile retail-dev

aws ssm put-parameter --name "/retail/prod/snowflake/private_key" \
  --type SecureString --value "$(cat ~/.snowflake/rsa_key_prod.p8)" \
  --overwrite --profile retail-dev
```

Then **delete the prod private key from disk**. That step is what makes the
rule in ADR 0010 real rather than aspirational:

```bash
rm ~/.snowflake/rsa_key_prod.p8
```

Keep `rsa_key_prod.pub` — you need it to paste into `03`.

## Pasting the public key

Snowflake wants the body only. Strip the `-----BEGIN PUBLIC KEY-----` and
`-----END PUBLIC KEY-----` lines and join the remaining lines into one
string:

```bash
grep -v "^-----" ~/.snowflake/rsa_key_dev.pub | tr -d '\n'
```

## Verifying dev and prod really are separated

The whole point of two roles is that neither reaches the other's database.
Prove it:

```sql
USE ROLE RETAIL_TRANSFORMER_DEV;
SELECT COUNT(*) FROM RETAIL_PROD.MARTS.FCT_ORDERS;   -- must fail
```

If that returns a number, a grant has leaked and the separation is
decorative.

## Why dev and prod are structurally identical

Same schema names, same role capabilities, same warehouse. The *only*
difference between a dev and a prod dbt run is which database is addressed,
which user connects, and which key is used.

That is deliberate. If the prod role could do something the dev role could
not, a model could pass in dev and fail in prod on a permission error. If dev
could do more than prod, worse — the failure only appears after merge.

Keep the two grant blocks in `02` identical apart from the database name.
