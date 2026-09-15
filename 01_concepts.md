# Apache Iceberg — Concepts (for a Data Engineer)

Read this first. It's ~10 minutes and it will make the AWS steps obvious instead of magical.

## 1. The problem Iceberg solves

You already know the data lake pattern: dump files (CSV/Parquet) into object storage
(S3) and query them. It's cheap and scalable, but "just files in a folder" has painful gaps:

| You want to...                          | Plain files in S3        | Iceberg |
|-----------------------------------------|--------------------------|---------|
| Add rows without breaking readers       | Risky (partial reads)    | ✅ Atomic |
| Delete/update specific rows             | Rewrite whole partitions | ✅ Row-level |
| Add a column later                      | Breaks old files/queries | ✅ Safe |
| See the table as it was last Tuesday    | Restore a backup         | ✅ Time travel |
| Know exactly which files a query needs  | List the whole bucket    | ✅ Metadata tells it |
| Two jobs writing at once                | Corruption / races       | ✅ Conflict detection |

**Apache Iceberg is a table format.** It's a specification + metadata layer that sits
*on top of* your Parquet files and turns "a pile of files" into a real table with
database-like guarantees (ACID transactions, schema evolution, time travel) — while the
data stays as open files in your own storage (no proprietary engine required).

> Mental model: a data warehouse gives you a great table but locks your data inside it.
> A data lake gives you open, cheap storage but no table guarantees. A **lakehouse**
> (data lake + a table format like Iceberg) gives you both. Iceberg is the "table
> format" ingredient.

## 2. The three layers (this is the whole idea)

When you created `retail.sales` in the local demo, Iceberg wrote three kinds of files.
You saw them in Step 7:

```
warehouse/retail/sales/
├── metadata/
│   ├── 0000N-....metadata.json   ← (1) TABLE METADATA: schema, snapshot list, current version
│   ├── snap-....avro             ← (2) MANIFEST LIST: which manifests belong to a snapshot
│   └── ....avro (m0)             ← (3) MANIFEST: which data files exist + stats (min/max, counts)
└── data/
    └── 00000-....parquet         ←     DATA FILES: your actual rows (plain Parquet)
```

1. **Metadata file** (`.metadata.json`) — the "table of contents." Points to the current
   snapshot and lists the schema. Every change writes a *new* metadata file; the catalog
   just updates a pointer to the latest one. This atomic pointer-swap is what gives you
   ACID.
2. **Manifest list** (`snap-*.avro`) — one per snapshot. Lists the manifests in that
   snapshot.
3. **Manifest** (`*-m0.avro`) — lists actual data files plus per-file statistics
   (row counts, min/max per column). This is how a query engine *skips* files it doesn't
   need without opening them.

**Why this matters for you as a DE:** query planning reads metadata, not the whole
bucket. On a 100,000-file table, a `WHERE order_date = '2026-01-05'` reads a few small
metadata files, uses min/max stats to pick only relevant Parquet files, and skips the
rest. That's the performance win.

## 3. Snapshots = every change is a new version

Each write (append/update/delete) creates a **snapshot** — an immutable picture of the
whole table at that moment. In the demo you saw two snapshots after two appends. Because
old snapshots still point at their old files:

- **Time travel** = "read snapshot X" (you did this in Step 5).
- **Rollback** = "make snapshot X the current one again" (undo a bad load instantly).
- **Audit** = the snapshot history is a built-in changelog.

Old snapshots keep old files alive, so you periodically run **maintenance**
(expire snapshots, compact small files) to reclaim space. Note this for later — it's a
real ops cost.

## 4. The catalog — the one piece that changes between local and AWS

The **catalog** answers one question: "for table `retail.sales`, where is the *current*
metadata file?" It's the thing that makes the atomic pointer-swap safe.

- **Local demo:** the catalog is a **SQLite** file (`catalog.db`).
- **On AWS:** the catalog is the **AWS Glue Data Catalog** (a managed service).

That's the *only* conceptual swap. Your table data lives in a "warehouse" location:
- **Local:** a `file://` folder.
- **On AWS:** an `s3://` bucket.

Everything else — schemas, snapshots, time travel, evolution — is identical. That is why
the same PyIceberg code you ran locally works against AWS with just different catalog
config.

## 5. Iceberg vs. the other names you'll hear

- **Delta Lake** and **Apache Hudi** are competing table formats. Same problem space.
  Iceberg has the broadest engine support (Athena, Spark, Trino, Snowflake, Flink…) and
  is a vendor-neutral Apache project — a safe default to learn.
- **Parquet** is *not* a competitor — it's the underlying file format Iceberg stores rows
  in. Iceberg is a layer *above* Parquet.
- **Hive tables** are the older approach Iceberg replaces (Hive tracked partitions as
  folder paths, which caused most of the pain in the table above).

## 6. How this fits YOUR MLOps roadmap

You're a DE learning ML/MLOps. Iceberg is a bridge skill that pays off later:

- **Reproducibility** — time travel lets you train on the *exact* data snapshot from a
  past run. That's the data-side twin of experiment tracking (your Stage 2 / MLflow).
- **Feature tables** — a governed, versioned Iceberg table is a solid foundation for a
  feature store.
- **Safe pipelines** — atomic appends + rollback mean a bad feature load can't corrupt
  training data.

---

Next: **`02_aws_guide.md`** — do everything above, but in your AWS account with S3 + Glue + Athena.
