#!/usr/bin/env bash
#
# aws_cli_deploy.sh — Deploy the Iceberg retail.sales POC to AWS using ONLY the AWS CLI.
# ============================================================================
# This mirrors 02_aws_guide.md, but instead of clicking in the Athena console you
# run everything from the command line. It creates:
#   - an S3 bucket (warehouse + athena results)
#   - a Glue database  (the "namespace")
#   - an Iceberg table via Athena
#   - inserts data, queries it, and demonstrates time travel
#
# It is SAFE and REPEATABLE. Run ./aws_cli_deploy.sh <command> for each step.
#
# PREREQUISITES
#   1. AWS CLI v2 installed:            aws --version
#   2. Credentials configured:          aws configure     (or SSO / env vars)
#   3. Permissions: Athena + Glue + S3  (POC: broad managed policies are fine)
#
# USAGE (run steps in order so you learn each piece):
#   ./aws_cli_deploy.sh setup       # create bucket + Glue database
#   ./aws_cli_deploy.sh create      # create the Iceberg table
#   ./aws_cli_deploy.sh insert      # insert first batch (snapshot #1)
#   ./aws_cli_deploy.sh insert2     # insert second batch (snapshot #2)
#   ./aws_cli_deploy.sh query       # select all rows
#   ./aws_cli_deploy.sh snapshots   # list snapshots (for time travel)
#   ./aws_cli_deploy.sh cleanup     # DROP table+db and delete the bucket
#   ./aws_cli_deploy.sh all         # setup -> create -> insert -> insert2 -> query
# ============================================================================

set -euo pipefail

# ------------------- CONFIG (edit these two lines) --------------------------
REGION="${AWS_REGION:-us-east-1}"
# Bucket names are globally unique — change the suffix to something yours:
BUCKET="${ICEBERG_BUCKET:-iceberg-poc-karthik-$(echo $RANDOM)}"
# ----------------------------------------------------------------------------

DB="retail"
TABLE="sales"
WAREHOUSE="s3://${BUCKET}/warehouse"
RESULTS="s3://${BUCKET}/athena-results"

# --- helper: run an Athena query and wait for it to finish, printing results -
run_athena() {
    local sql="$1"
    echo ">>> Athena SQL: ${sql}"
    local qid
    qid=$(aws athena start-query-execution \
        --region "$REGION" \
        --query-string "$sql" \
        --query-execution-context "Database=${DB}" \
        --result-configuration "OutputLocation=${RESULTS}/" \
        --query 'QueryExecutionId' --output text)

    echo "    query id: ${qid} — waiting..."
    # poll until the query leaves the RUNNING/QUEUED state
    while true; do
        local state
        state=$(aws athena get-query-execution --region "$REGION" \
            --query-execution-id "$qid" \
            --query 'QueryExecution.Status.State' --output text)
        case "$state" in
            SUCCEEDED) echo "    SUCCEEDED"; break ;;
            FAILED|CANCELLED)
                echo "    $state"
                aws athena get-query-execution --region "$REGION" \
                    --query-execution-id "$qid" \
                    --query 'QueryExecution.Status.StateChangeReason' --output text
                return 1 ;;
            *) sleep 2 ;;
        esac
    done

    # print the tabular results (SELECTs only — DDL returns nothing useful)
    aws athena get-query-results --region "$REGION" \
        --query-execution-id "$qid" \
        --query 'ResultSet.Rows[].Data[].VarCharValue' \
        --output text 2>/dev/null || true
    echo ""
}

cmd_setup() {
    echo "== Creating S3 bucket: ${BUCKET} (region ${REGION}) =="
    if [ "$REGION" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
    else
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
            --create-bucket-configuration "LocationConstraint=${REGION}"
    fi
    echo "== Creating Glue database: ${DB} =="
    aws glue create-database --region "$REGION" \
        --database-input "Name=${DB}" 2>/dev/null || echo "    (database already exists)"
    echo ""
    echo "Warehouse : ${WAREHOUSE}"
    echo "Results   : ${RESULTS}"
    echo "Save this bucket name! export ICEBERG_BUCKET=${BUCKET}"
}

cmd_create() {
    run_athena "CREATE TABLE ${DB}.${TABLE} (
        order_id bigint,
        customer_id bigint,
        product string,
        amount double,
        order_date string
    )
    LOCATION '${WAREHOUSE}/${DB}/${TABLE}/'
    TBLPROPERTIES ('table_type'='ICEBERG', 'format'='parquet');"
}

cmd_insert() {
    run_athena "INSERT INTO ${DB}.${TABLE} VALUES
        (1, 101, 'Coffee Maker', 79.99, '2026-01-05'),
        (2, 102, 'Headphones',   149.50,'2026-01-06'),
        (3, 101, 'Notebook',     12.00, '2026-01-06');"
}

cmd_insert2() {
    run_athena "INSERT INTO ${DB}.${TABLE} VALUES
        (4, 103, 'Desk Lamp', 34.99, '2026-01-10'),
        (5, 102, 'Keyboard',  89.00, '2026-01-11');"
}

cmd_query() {
    run_athena "SELECT * FROM ${DB}.${TABLE} ORDER BY order_id;"
}

cmd_snapshots() {
    run_athena "SELECT snapshot_id, committed_at, operation
                FROM \"${DB}\".\"${TABLE}\$snapshots\" ORDER BY committed_at;"
    echo "Time-travel later with:  SELECT * FROM ${DB}.${TABLE} FOR VERSION AS OF <snapshot_id>;"
}

cmd_cleanup() {
    echo "== Dropping table + database =="
    run_athena "DROP TABLE ${DB}.${TABLE};" || true
    run_athena "DROP DATABASE ${DB};" || true
    echo "== Emptying + deleting bucket ${BUCKET} =="
    aws s3 rm "s3://${BUCKET}" --recursive || true
    aws s3 rb "s3://${BUCKET}" || true
    echo "Cleanup complete."
}

cmd_all() {
    cmd_setup; cmd_create; cmd_insert; cmd_insert2; cmd_query
}

# ------------------------------- dispatch -----------------------------------
case "${1:-}" in
    setup)     cmd_setup ;;
    create)    cmd_create ;;
    insert)    cmd_insert ;;
    insert2)   cmd_insert2 ;;
    query)     cmd_query ;;
    snapshots) cmd_snapshots ;;
    cleanup)   cmd_cleanup ;;
    all)       cmd_all ;;
    *)
        echo "Usage: $0 {setup|create|insert|insert2|query|snapshots|cleanup|all}"
        echo "Config via env: AWS_REGION, ICEBERG_BUCKET"
        exit 1 ;;
esac
