# Clone & Deploy via CLI — Step by Step

This guide covers two things you asked for:
1. **Clone** this repo to your machine.
2. **Deploy** the Iceberg POC to AWS using the **AWS CLI** (no console clicking).

Run all of this in **your own terminal** (laptop / workstation), not in Kiro.

---

## Part A — Clone the repo

```bash
# 1. Clone over HTTPS
git clone https://github.com/karthikcode26/iceberg-poc.git

# 2. Go into it
cd iceberg-poc

# 3. Look around
ls -la
```

You should see `local_demo.py`, `01_concepts.md`, `02_aws_guide.md`,
`deploy/aws_cli_deploy.sh`, and this file.

> Prefer SSH? Use `git clone git@github.com:karthikcode26/iceberg-poc.git`
> (requires an SSH key added to your GitHub account).

### (Optional) Run the local demo first — no AWS needed
```bash
python -m venv .venv && source .venv/bin/activate   # optional but recommended
pip install -r requirements.txt
python local_demo.py
```

---

## Part B — One-time AWS CLI setup

```bash
# 1. Confirm the AWS CLI is installed (need v2)
aws --version

# 2. Configure credentials + default region
aws configure
#   AWS Access Key ID:      <your key>
#   AWS Secret Access Key:  <your secret>
#   Default region name:    us-east-1
#   Default output format:  json

# 3. Verify you're authenticated as the right account/identity
aws sts get-caller-identity
```

You need permissions for **Athena**, **Glue**, and **S3**. For a POC, the managed
policies `AmazonAthenaFullAccess`, `AWSGlueConsoleFullAccess`, and `AmazonS3FullAccess`
are enough (tighten for production later).

---

## Part C — Deploy with the CLI script

The repo ships a helper script `deploy/aws_cli_deploy.sh` that runs each step of the
POC through the AWS CLI. **Run the steps in order** so you see each piece work.

```bash
# Pick a region and a globally-unique bucket name (edit to your own):
export AWS_REGION=us-east-1
export ICEBERG_BUCKET=iceberg-poc-karthik-001   # must be globally unique

cd deploy
chmod +x aws_cli_deploy.sh    # first time only

# Step 1: create the S3 bucket + Glue database
./aws_cli_deploy.sh setup

# Step 2: create the Iceberg table (note table_type=ICEBERG)
./aws_cli_deploy.sh create

# Step 3: insert first batch (creates snapshot #1)
./aws_cli_deploy.sh insert

# Step 4: insert second batch (creates snapshot #2)
./aws_cli_deploy.sh insert2

# Step 5: query all rows
./aws_cli_deploy.sh query

# Step 6: list snapshots (grab an id for time travel)
./aws_cli_deploy.sh snapshots
```

Or run the whole happy path at once:
```bash
./aws_cli_deploy.sh all
```

### What the script does under the hood
- `aws s3api create-bucket` — makes the warehouse + results bucket.
- `aws glue create-database` — the Iceberg namespace (`retail`).
- `aws athena start-query-execution` — runs each SQL statement; the script **polls**
  `get-query-execution` until it succeeds, then prints results via `get-query-results`.

This is the exact CLI pattern for automating Athena: **start → poll status → fetch
results.** Once you're comfortable, this same pattern drops straight into a CI/CD pipeline
or a Lambda.

---

## Part D — Time travel from the CLI

After `snapshots` prints the snapshot ids, edit the query or run directly:

```bash
aws athena start-query-execution \
  --region "$AWS_REGION" \
  --query-string "SELECT * FROM retail.sales FOR VERSION AS OF <SNAPSHOT_ID>;" \
  --query-execution-context "Database=retail" \
  --result-configuration "OutputLocation=s3://$ICEBERG_BUCKET/athena-results/"
```

---

## Part E — Cleanup (do this so nothing lingers / bills)

```bash
./aws_cli_deploy.sh cleanup
```
This drops the table + database and deletes the bucket. Confirm in the Glue and S3
consoles that everything is gone.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Unable to locate credentials` | Run `aws configure` (Part B) |
| `BucketAlreadyExists` / `...OwnedByYou` | Bucket names are global — change `ICEBERG_BUCKET` |
| Athena `No output location` | The script sets `OutputLocation`; ensure `ICEBERG_BUCKET` is exported |
| `AccessDenied` | IAM identity missing Athena/Glue/S3 permissions |
| Region mismatch (table not found) | Keep `AWS_REGION` the same across all steps |

Sources: [Athena `start-query-execution` CLI reference](https://docs.aws.amazon.com/cli/latest/reference/athena/start-query-execution.html).
Content was rephrased for compliance with licensing restrictions.
