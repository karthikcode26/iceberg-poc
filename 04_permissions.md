# IAM Permissions for the Iceberg POC

The deploy user runs SQL through **Athena**, which is serverless and delegates to two
other services. So the user needs permissions across **three** services:

| Service | Why it's needed | Actions used |
|---------|-----------------|--------------|
| **Athena** | Runs the SQL (create table, insert, select, time travel) | `StartQueryExecution`, `GetQueryExecution`, `GetQueryResults`, `StopQueryExecution` |
| **Glue Data Catalog** | Athena stores the Iceberg table's schema + snapshot metadata here — Glue **is** the catalog | `CreateDatabase`, `Get*`, `CreateTable`, **`UpdateTable`**, `DeleteTable`, `DeleteDatabase` |
| **S3** | Holds the Parquet data, the Iceberg metadata files, and Athena query results | `CreateBucket`, `PutObject`, `GetObject`, `DeleteObject`, `ListBucket`, `GetBucketLocation`, `DeleteBucket` |

> **Why `glue:UpdateTable` matters:** Iceberg updates its table metadata pointer in Glue
> on *every* write (each insert/update/delete creates a new snapshot). A user who can
> `CreateTable` but not `UpdateTable` can make the table but every `INSERT` will fail.
> This trips up people used to plain-file S3 data lakes.

---

## Option 1 — Quick POC (broad, easiest)

Attach these AWS-managed policies to the IAM user:

- `AmazonAthenaFullAccess`
- `AWSGlueConsoleFullAccess`
- `AmazonS3FullAccess`

Fine for a throwaway sandbox account. **Too broad for production.**

---

## Option 2 — Least privilege (recommended)

Use the ready-made policy file **`deploy/iam-policy-least-privilege.json`**. It scopes S3
to *only* your POC bucket. Steps:

```bash
# 1. Edit the policy: replace BUCKET_NAME (2 places) with your bucket, e.g. iceberg-poc-karthik-001
#    (in the S3BucketLevel and S3ObjectLevel statements)

# 2. Create the managed policy
aws iam create-policy \
  --policy-name IcebergPocDeploy \
  --policy-document file://deploy/iam-policy-least-privilege.json

# 3. Attach it to your deploy user (replace YOUR_USER and ACCOUNT_ID)
aws iam attach-user-policy \
  --user-name YOUR_USER \
  --policy-arn arn:aws:iam::ACCOUNT_ID:policy/IcebergPocDeploy
```

Athena and Glue actions are left as `Resource: "*"` because Athena workgroup and Glue
catalog ARNs are account/region-scoped and awkward to pin for a POC; the S3 statements —
where your actual data lives — are tightly scoped to the one bucket. Tighten Athena/Glue
resources later for production.

---

## Notes for later (production hardening)

- **Encryption:** if your S3 bucket uses SSE-KMS, add `kms:GenerateDataKey` and
  `kms:Decrypt` on the key.
- **Lake Formation:** if your account uses AWS Lake Formation to govern the Glue catalog,
  IAM alone isn't enough — you'd also grant Lake Formation permissions on the database/table.
- **Separate roles:** in a real pipeline, split into a *deploy/DDL* role and a
  *read-only query* role. Least privilege per job is a core MLOps security habit.
- **S3 Tables:** the newer Amazon S3 Tables option uses a different permission model
  (Lake Formation grants + the Glue Iceberg REST endpoint). Not needed for this POC.

Sources: [Athena – Control access to S3](https://docs.aws.amazon.com/athena/latest/ug/s3-permissions.html),
[Lake Formation – Creating Iceberg tables](https://docs.aws.amazon.com/lake-formation/latest/dg/creating-iceberg-tables.html).
Content was rephrased for compliance with licensing restrictions.
