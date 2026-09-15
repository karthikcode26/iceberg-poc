# Apache Iceberg on AWS — Step-by-Step POC

Goal: recreate the local `retail.sales` demo entirely in your AWS account, using the
**Athena + Glue + S3** stack. This is the fastest, cheapest, fully-serverless way to try
Iceberg on AWS — no clusters, no servers, pay-per-query.

> **Cost expectation:** This POC costs pennies. S3 stores a few KB. Athena bills
> ~$5 per TB scanned — our data scans are megabytes, effectively free. **Remember to run
> the cleanup step at the end** so nothing lingers.

## The mapping (local demo → AWS)

| Local demo piece            | AWS equivalent                        |
|-----------------------------|----------------------------------------|
| `warehouse/` folder          | An **S3 bucket** path                  |
| SQLite `catalog.db`          | **AWS Glue Data Catalog** (a database) |
| `catalog.create_table(...)`  | Athena `CREATE TABLE ... TBLPROPERTIES ('table_type'='ICEBERG')` |
| `table.append(...)`          | Athena `INSERT INTO`                   |
| `table.scan(snapshot_id=..)` | Athena `FOR TIMESTAMP AS OF` / `FOR VERSION AS OF` |
| `update_schema()`            | Athena `ALTER TABLE ... ADD COLUMNS`   |

**Key insight from the concepts doc:** on AWS you do NOT create an "Iceberg catalog"
separately. Glue *is* the catalog. You just tag the table as Iceberg via table
properties. Athena handles all the metadata/manifest/snapshot machinery for you.

---

## Prerequisites (one-time)

1. An AWS account with access to the **Athena**, **S3**, and **Glue** consoles.
2. An IAM user/role with permissions for Athena, Glue, and S3 (the AWS managed policies
   `AmazonAthenaFullAccess` + `AmazonS3FullAccess` + `AWSGlueConsoleFullAccess` are fine
   for a POC; tighten later for production).
3. Pick a region and stay in it the whole time (e.g. `us-east-1`). Iceberg tables,
   the bucket, and Athena must all be in the same region.

---

## Step 1 — Create two S3 buckets (or one bucket, two prefixes)

You need storage for (a) the table data and (b) Athena's query results.

**Console:** S3 → Create bucket. Names must be globally unique, so add a suffix.

- Data warehouse:   `s3://iceberg-poc-<yourname>/warehouse/`
- Athena results:   `s3://iceberg-poc-<yourname>/athena-results/`

**CLI equivalent:**
```bash
aws s3 mb s3://iceberg-poc-yourname --region us-east-1
```
(The `warehouse/` and `athena-results/` prefixes are created automatically when first
written to.)

---

## Step 2 — Point Athena at a results location

**Console:** Open **Athena** → Query editor → **Settings** tab → **Manage** →
set *Location of query result* to `s3://iceberg-poc-<yourname>/athena-results/` → Save.

Athena won't run a query until this is set. This is a common first-time gotcha.

---

## Step 3 — Create a Glue database (the namespace)

This is the equivalent of `create_namespace("retail")` in the local demo. In Athena's
query editor, run:

```sql
CREATE DATABASE IF NOT EXISTS retail;
```

Behind the scenes this creates a **database in the Glue Data Catalog**. Confirm it in the
Glue console under *Data Catalog → Databases*.

---

## Step 4 — Create the Iceberg table

Select the `retail` database in the editor's left panel, then run. **This is the one
statement that makes it an Iceberg table** — note the `table_type` property and the
`location` pointing at your S3 warehouse:

```sql
CREATE TABLE retail.sales (
    order_id     bigint,
    customer_id  bigint,
    product      string,
    amount       double,
    order_date   string
)
LOCATION 's3://iceberg-poc-yourname/warehouse/retail/sales/'
TBLPROPERTIES (
    'table_type' = 'ICEBERG',
    'format'     = 'parquet'
);
```

After this runs, look in your S3 bucket: you'll see a `metadata/` folder appear with a
`.metadata.json` file — exactly like the local demo's Step 7. Iceberg wrote its table of
contents.

> **Partitioning (optional but the real power move):** for a bigger table you'd add
> `PARTITIONED BY (month(order_date_as_date))`. Iceberg supports *hidden partitioning* —
> you query `WHERE order_date >= ...` and Iceberg prunes partitions automatically, so you
> never manage partition folders by hand like in old Hive tables. Skip it for this POC.

---

## Step 5 — Insert data (Snapshot #1)

Mirrors `table.append(batch1)`:

```sql
INSERT INTO retail.sales VALUES
    (1, 101, 'Coffee Maker', 79.99,  '2026-01-05'),
    (2, 102, 'Headphones',   149.50, '2026-01-06'),
    (3, 101, 'Notebook',     12.00,  '2026-01-06');
```

Query it back:
```sql
SELECT * FROM retail.sales ORDER BY order_id;
```

Check S3 again — a `data/` folder now holds a Parquet file, and `metadata/` has grown a
new snapshot. Same three-layer structure from the concepts doc.

---

## Step 6 — Append more data (Snapshot #2)

```sql
INSERT INTO retail.sales VALUES
    (4, 103, 'Desk Lamp', 34.99, '2026-01-10'),
    (5, 102, 'Keyboard',  89.00, '2026-01-11');
```

---

## Step 7 — Time travel 🎉

This is the payoff. Iceberg records every snapshot with a timestamp and an ID. Inspect
the history first:

```sql
SELECT * FROM "retail"."sales$snapshots" ORDER BY committed_at;
```

You'll see two rows (two `INSERT`s). Now query the table **as it was in the past**:

```sql
-- By time: table state 5 minutes ago (before your 2nd insert)
SELECT * FROM retail.sales
FOR TIMESTAMP AS OF (current_timestamp - interval '5' minute);

-- By snapshot id: grab a snapshot_id from the $snapshots query above
SELECT * FROM retail.sales
FOR VERSION AS OF 1234567890123456789;
```

This is the AWS equivalent of the local demo's `table.scan(snapshot_id=snapshot_1_id)`.
No backups restored — just metadata pointers.

---

## Step 8 — Schema evolution

Mirrors the local demo's `add_column("channel", ...)`:

```sql
ALTER TABLE retail.sales ADD COLUMNS (channel string);

INSERT INTO retail.sales VALUES
    (6, 104, 'Monitor', 199.99, '2026-01-15', 'online');

SELECT * FROM retail.sales ORDER BY order_id;
```

Older rows show `NULL` for `channel` — no old Parquet files were rewritten. Exactly the
local behavior.

---

## Step 9 — Row-level UPDATE / DELETE (something the local demo skipped)

A big reason to use Iceberg over plain files: you can update/delete individual rows with
plain SQL. Try it:

```sql
UPDATE retail.sales SET amount = 84.99 WHERE order_id = 1;
DELETE FROM retail.sales WHERE order_id = 3;
SELECT * FROM retail.sales ORDER BY order_id;
```

Each of these creates a new snapshot too — so it's all still time-travelable and
reversible.

---

## Step 10 — Cleanup (do this to avoid lingering resources)

```sql
DROP TABLE retail.sales;      -- run in Athena; also removes data when table_type=ICEBERG
DROP DATABASE retail;
```
Then empty/delete the S3 bucket:
```bash
aws s3 rm s3://iceberg-poc-yourname --recursive
aws s3 rb s3://iceberg-poc-yourname
```
Confirm the Glue database is gone in the Glue console.

---

## Newer alternative: Amazon S3 Tables (worth knowing, not required today)

AWS now offers **S3 Tables** — S3 buckets with *built-in* Iceberg support and automatic
maintenance (compaction, snapshot expiration) managed for you. It removes the manual
maintenance chore mentioned in the concepts doc. For a first POC, the Athena + Glue + S3
path above teaches you the moving parts better; once you understand them, S3 Tables is
the more hands-off production option. (Reference:
[S3 Tables docs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-create.html).)

---

## Troubleshooting quick reference

| Symptom | Likely cause / fix |
|---|---|
| "No output location provided" | Step 2 not done — set Athena query results location |
| `CREATE TABLE` succeeds but it's not Iceberg | Missing `'table_type'='ICEBERG'` in TBLPROPERTIES |
| Time-travel query errors | Table must be Iceberg; use `$snapshots` to get valid IDs/timestamps |
| Access denied | IAM role missing Athena/Glue/S3 permissions, or bucket in a different region |
| Can't see the table in Glue | You're viewing the wrong region — match your Athena region |

Sources: [Athena – Create Iceberg tables](https://docs.aws.amazon.com/athena/latest/ug/querying-iceberg-creating-tables.html),
[Iceberg on AWS – Getting started](https://docs.aws.amazon.com/prescriptive-guidance/latest/apache-iceberg-on-aws/getting-started.html).
Content was rephrased for compliance with licensing restrictions.
