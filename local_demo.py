"""
Apache Iceberg — Local hands-on POC
===================================

This script runs a FULL Iceberg lifecycle on your own machine using PyIceberg:
  1. Create a catalog (the "phone book" that tracks tables)
  2. Create a table with a schema
  3. Insert data (retail sales — matching your finance/retail interest)
  4. Query it back
  5. Append MORE data (a second snapshot)
  6. Time-travel: read the table AS IT WAS at the first snapshot
  7. Schema evolution: add a column without rewriting old data
  8. Inspect the metadata that makes all of this possible

The SAME PyIceberg code works against AWS Glue + S3 — only the catalog
configuration changes. See aws_guide.md for that mapping.

Run:  python local_demo.py
"""

import os
import shutil
import pyarrow as pa
from pyiceberg.catalog.sql import SqlCatalog
from pyiceberg.types import StringType

# ---------------------------------------------------------------------------
# STEP 0: Set up local storage locations
# ---------------------------------------------------------------------------
# In AWS, "warehouse" would be an S3 path like s3://my-bucket/warehouse
# and the catalog would be AWS Glue. Here we use a local folder + SQLite.
BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "warehouse")
if os.path.exists(BASE):
    shutil.rmtree(BASE)  # clean slate every run so the demo is repeatable
os.makedirs(BASE, exist_ok=True)


def banner(title):
    print("\n" + "=" * 70)
    print(f"  {title}")
    print("=" * 70)


# ---------------------------------------------------------------------------
# STEP 1: Create the catalog
# ---------------------------------------------------------------------------
banner("STEP 1: Create an Iceberg catalog (local SQLite)")
catalog = SqlCatalog(
    "poc_catalog",
    **{
        "uri": f"sqlite:///{BASE}/catalog.db",  # tracks table metadata pointers
        "warehouse": f"file://{BASE}",           # where table data/metadata files live
    },
)
print("Catalog created. It knows about these namespaces:", catalog.list_namespaces())

# A namespace is like a database/schema — a folder for grouping tables.
catalog.create_namespace_if_not_exists("retail")
print("Created namespace 'retail'. Namespaces now:", catalog.list_namespaces())


# ---------------------------------------------------------------------------
# STEP 2: Define a schema and create a table
# ---------------------------------------------------------------------------
banner("STEP 2: Create an Iceberg table with a schema")

# We describe the shape of our data using a PyArrow schema.
# PyIceberg converts this into an Iceberg schema automatically.
schema = pa.schema([
    ("order_id", pa.int64()),
    ("customer_id", pa.int64()),
    ("product", pa.string()),
    ("amount", pa.float64()),
    ("order_date", pa.string()),
])

table = catalog.create_table("retail.sales", schema=schema)
print("Created table 'retail.sales'")
print("Data + metadata are stored under:", table.location())


# ---------------------------------------------------------------------------
# STEP 3: Insert the first batch of data (creates snapshot #1)
# ---------------------------------------------------------------------------
banner("STEP 3: Insert first batch of sales (Snapshot #1)")

batch1 = pa.Table.from_pylist([
    {"order_id": 1, "customer_id": 101, "product": "Coffee Maker", "amount": 79.99,  "order_date": "2026-01-05"},
    {"order_id": 2, "customer_id": 102, "product": "Headphones",   "amount": 149.50, "order_date": "2026-01-06"},
    {"order_id": 3, "customer_id": 101, "product": "Notebook",     "amount": 12.00,  "order_date": "2026-01-06"},
], schema=schema)

table.append(batch1)
print(f"Inserted {batch1.num_rows} rows.")

df = table.scan().to_pandas()
print("\nCurrent table contents:")
print(df.to_string(index=False))


# ---------------------------------------------------------------------------
# STEP 4: Capture the snapshot id, then append MORE data (snapshot #2)
# ---------------------------------------------------------------------------
banner("STEP 4: Append more sales (Snapshot #2)")

# Remember where we are now — we'll time-travel back here later.
snapshot_1_id = table.current_snapshot().snapshot_id
print(f"Snapshot #1 id = {snapshot_1_id}")

batch2 = pa.Table.from_pylist([
    {"order_id": 4, "customer_id": 103, "product": "Desk Lamp", "amount": 34.99, "order_date": "2026-01-10"},
    {"order_id": 5, "customer_id": 102, "product": "Keyboard",  "amount": 89.00, "order_date": "2026-01-11"},
], schema=schema)

table.append(batch2)
print(f"Inserted {batch2.num_rows} more rows.")

df = table.scan().to_pandas()
print("\nTable contents NOW (both batches):")
print(df.to_string(index=False))


# ---------------------------------------------------------------------------
# STEP 5: TIME TRAVEL — read the table as it was at snapshot #1
# ---------------------------------------------------------------------------
banner("STEP 5: Time travel back to Snapshot #1")
print("This is Iceberg's superpower: query old versions WITHOUT restoring backups.\n")

old_df = table.scan(snapshot_id=snapshot_1_id).to_pandas()
print("Table AS IT WAS at Snapshot #1 (only the first 3 rows exist):")
print(old_df.to_string(index=False))

print("\nAll snapshots in history:")
for snap in table.snapshots():
    print(f"  - snapshot {snap.snapshot_id}  operation={snap.summary.operation}")


# ---------------------------------------------------------------------------
# STEP 6: SCHEMA EVOLUTION — add a column, no data rewrite needed
# ---------------------------------------------------------------------------
banner("STEP 6: Schema evolution — add a 'channel' column")
print("Old files are untouched; Iceberg fills missing values as null.\n")

with table.update_schema() as update:
    update.add_column("channel", StringType())

# New data can now use the new column.
batch3 = pa.Table.from_pylist([
    {"order_id": 6, "customer_id": 104, "product": "Monitor", "amount": 199.99,
     "order_date": "2026-01-15", "channel": "online"},
], schema=table.schema().as_arrow())

table.append(batch3)

df = table.scan().to_pandas()
print("Table after adding 'channel' (older rows show null/None):")
print(df.to_string(index=False))


# ---------------------------------------------------------------------------
# STEP 7: Peek at the metadata that powers all of this
# ---------------------------------------------------------------------------
banner("STEP 7: What's actually on disk?")
print("Iceberg is 'just files' — data files + metadata files in your warehouse.")
print("Table location:", table.location())
print("\nDirectory tree:")
for root, dirs, files in os.walk(BASE):
    depth = root.replace(BASE, "").count(os.sep)
    indent = "  " * depth
    print(f"{indent}{os.path.basename(root) or 'warehouse'}/")
    for f in sorted(files):
        print(f"{indent}  {f}")

banner("DONE — you just ran a full Iceberg lifecycle locally!")
print("Next: open aws_guide.md to do the same thing in your AWS account.")
