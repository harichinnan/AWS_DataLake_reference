# Citi Bike Athena Iceberg Data Lake

This Terraform project creates a small Athena-based data lake for modern Citi Bike trip data:

- S3 raw, warehouse, and Athena result buckets
- Glue Data Catalog database
- Athena workgroup pinned to engine version 3
- Saved Athena SQL queries for raw CSV table setup and compatibility samples
- dbt project for Silver and Gold Iceberg transformations
- AWS Glue Data Quality DQDL ruleset for the Silver Iceberg table
- EventBridge and Step Functions pipeline that persists Glue Data Quality result events into Athena tables
- Lake Formation registration and table permissions for data lake S3 locations
- Optional AWS-hosted Metabase on ECS Fargate with RDS PostgreSQL
- Lambda ingestion function that downloads monthly Citi Bike ZIP CSV files and writes extracted CSVs to S3
- Optional EventBridge monthly ingestion trigger
- IAM policy you can attach to a user or role that will run ingestion and Athena setup queries

## Layout

```
.
├── terraform/             # All Terraform root module files (.tf, .tfvars, lock file)
│   ├── sql/               # Athena SQL templates referenced by Terraform
│   └── dqdl/              # Glue Data Quality DQDL template
├── src/
│   └── lambda/            # Python source for the ingest + DQ event Lambdas
├── dbt/                   # dbt project (Silver and Gold Iceberg models)
├── scripts/               # Shell + Python helpers (invoke `terraform -chdir=terraform`)
├── build/                 # Built Lambda zip artifacts (gitignored)
└── .terraform-state/      # Local Terraform state (gitignored)
```

The Terraform root module lives in [terraform/](terraform/). Run all `terraform` commands either from inside that directory or via `terraform -chdir=terraform ...`. The shell and Python helpers in [scripts/](scripts/) already pass `-chdir=terraform` automatically. Local state is written under `.terraform-state/` (configured via the `local` backend in [terraform/versions.tf](terraform/versions.tf)).

## AWS Inputs Needed

You need these from AWS before applying:

- Target AWS account ID, set as `allowed_account_id`
- Target AWS region, for example `us-east-1`
- AWS credentials/profile with permission to create S3, Glue, Athena, IAM, Lambda, CloudWatch Logs, and optionally EventBridge resources
- For Glue DQ event observability: permission to create EventBridge rules/targets and Step Functions state machines
- For Metabase: permission to create VPC, EC2 networking, ALB, ECS, RDS, Secrets Manager, and IAM role resources
- For Lake Formation: a Lake Formation data lake administrator principal ARN, usually the AWS IAM Identity Center administrator role ARN
- A globally unique S3 bucket prefix if the default naming pattern is already taken
- Confirmation whether Lake Formation should govern Glue/S3. If enabled, Terraform registers the raw and warehouse buckets with Lake Formation and creates a dedicated Lake Formation data access role for credential vending
- Any organization constraints such as required tags, bucket naming rules, SCP restrictions, or mandatory KMS keys

## Deploy

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with the real AWS account ID and any naming changes.
terraform init
terraform plan
terraform apply
```

Or stay at the project root and pass `-chdir`:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan
terraform -chdir=terraform apply
```

The checked-in example uses a sample modern-schema month. The local `terraform.tfvars` for this deployment is set to the available 2026 files from January through April.

## Ingest Data

After `terraform apply`, run:

```bash
terraform -chdir=terraform output -raw citibike_ingest_example_command
```

Then run the command it prints. You can also invoke a specific month directly:

```bash
aws lambda invoke \
  --function-name "$(terraform -chdir=terraform output -raw citibike_ingest_lambda_name)" \
  --payload '{"months":["202401"],"include_jc":false}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/citibike-ingest.json \
  --region "$(terraform -chdir=terraform output -raw aws_region)"
```

The Lambda tries both current and older monthly file naming patterns, including:

```text
https://s3.amazonaws.com/tripdata/202601-citibike-tripdata.zip
https://s3.amazonaws.com/tripdata/202401-citibike-tripdata.csv.zip
```

and writes extracted CSVs under:

```text
s3://<raw-bucket>/raw/citibike/trips/year=YYYY/month=MM/
```

## Create Raw Athena Table

Terraform stores the raw table setup SQL as named queries. Run them in this order after raw files are ingested:

1. `create_raw_table`
2. `repair_raw_partitions`

The `create_iceberg_table`, `merge_raw_to_iceberg`, and `sample_queries` named queries are still present for compatibility with the first single-table layout. Silver and Gold are now managed by dbt.

Get the query IDs:

```bash
terraform -chdir=terraform output athena_named_query_ids
```

Run a query by ID:

```bash
bash scripts/run_named_query.sh <named-query-id>
```

## Transform With dbt

Silver and Gold are managed by dbt:

- `dbt/models/silver/citibike_trips_silver.sql`: typed, normalized, deduplicated Iceberg trips keyed by `ride_id`
- `dbt/models/silver/citibike_trips_silver_observability.sql`: daily Silver quality metrics and pass/warn/fail status
- `dbt/models/gold/citibike_daily_ridership_gold.sql`: daily ridership metrics keyed by `trip_date`

Run locally:

```bash
python3 -m venv .venv-dbt
. .venv-dbt/bin/activate
pip install -r requirements-dbt.txt
AWS_PROFILE=citibike-lake-dev ./scripts/run_dbt.sh debug
AWS_PROFILE=citibike-lake-dev ./scripts/run_dbt.sh run --select citibike_trips_silver+
AWS_PROFILE=citibike-lake-dev ./scripts/run_dbt.sh test
```

The dbt profile uses `s3_data_naming: schema_table_unique` because Athena Iceberg full-refreshes need unique table locations during dbt's swap/backup flow.

The Silver model filters to actual trip dates on or after `2026-01-01`, deduplicates on `ride_id`, and writes Iceberg with dbt's merge incremental strategy. The Gold model aggregates daily metrics from Silver and merges on `trip_date`.

Silver observability is written to `citibike_lake_dev.citibike_trips_silver_observability`. It tracks daily row counts, duplicate IDs, invalid duration rates, missing station/geography rates, invalid enum counts, duration percentiles, and a `quality_status` of `pass`, `warn`, or `fail`. The singular dbt test `silver_observability_no_failures` fails the run when any day has a hard quality failure.

Example status query:

```sql
select
  quality_status,
  count(*) as days,
  sum(total_rides) as total_rides,
  max(invalid_duration_rate) as max_invalid_duration_rate,
  sum(duplicate_ride_ids) as duplicate_ride_ids
from citibike_lake_dev.citibike_trips_silver_observability
group by quality_status;
```

## Glue Data Quality DQDL

When `enable_glue_data_quality = true`, Terraform creates:

- `terraform/dqdl/citibike_trips_silver.dqdl.tftpl`: the declarative Silver quality rules
- `aws_glue_data_quality_ruleset.citibike_trips_silver`: the managed Glue Data Quality ruleset
- `citibike-lake-dev-glue-data-quality`: the Glue execution role
- Lake Formation `SELECT`/`DESCRIBE` grants for the Glue execution role

Run the Silver ruleset:

```bash
AWS_PROFILE=citibike-lake-dev bash scripts/run_glue_data_quality.sh
```

The script starts a Glue Data Quality evaluation run, waits for completion, prints the Glue run and rule result JSON, and exits nonzero if the run fails or any DQ rule is not `PASS`.

The rules validate row count, `ride_id` uniqueness, required timestamps and enums, 2026 trip dates, valid duration ratios, station/geography completeness, and expected Citi Bike latitude/longitude bounds.

When `enable_glue_data_quality_event_observability = true`, Terraform also creates an event-driven observability path:

- EventBridge captures `aws.glue-dataquality` result events for `citibike_trips_silver`
- Step Functions starts a workflow for each event
- `src/lambda/process_glue_dq_event.py` calls `glue:GetDataQualityResult`, flattens the run and rule-level results, and writes JSONL files to the warehouse bucket
- Athena reads those files through partition-projected Glue tables:
  - `citibike_glue_dq_run_events`
  - `citibike_glue_dq_rule_results`

No crawler or `MSCK REPAIR TABLE` is needed because the tables project the `event_date` partition from the S3 path.

Example queries:

```sql
select
  event_date,
  ruleset_name,
  state,
  score,
  rules_succeeded,
  rules_failed,
  rules_skipped
from citibike_lake_dev.citibike_glue_dq_run_events
where event_date >= '2026-01-01'
order by event_time desc
limit 20;
```

```sql
select
  event_date,
  rule_result,
  count(*) as rules
from citibike_lake_dev.citibike_glue_dq_rule_results
where event_date >= '2026-01-01'
group by event_date, rule_result
order by event_date desc, rule_result;
```

## Resilient Auto-Heal Pipeline

Set `enable_pipeline_orchestration = true` to stand up the Step Functions–driven auto-heal stack on top of the manual workflow. Terraform builds:

- A dedicated VPC + AWS Batch Fargate compute environment running a dbt-athena container (image pushed to ECR at apply time — requires `docker buildx` locally)
- An Iceberg ledger `citibike_quarantined_partitions` that records (year, month) partitions failing Glue Data Quality
- A Step Functions state machine that chains: clear stale quarantine → ingest → Athena `MSCK REPAIR` → dbt build Silver → start Glue DQ + poll → on FAIL insert quarantine row + dbt refilter + SNS alert, on PASS dbt build Gold
- An EventBridge → Lambda trigger on raw S3 `ObjectCreated` events that starts the state machine for the (year, month) extracted from the key
- A daily cron safety-net rule (configurable via `pipeline_schedule_expression`)
- An SNS topic (`citibike-lake-dev-data-alerts`) with optional email + Slack subscriptions and a parallel EventBridge rule that publishes any Glue DQ failure

```bash
# Once enabled, drop a corrected month at the same S3 key:
aws s3 cp 202602-citibike-tripdata-fixed.csv \
  "s3://$(terraform -chdir=terraform output -raw s3_buckets | jq -r .raw)/raw/citibike/trips/year=2026/month=02/citibike_202602-citibike-tripdata.csv"

# Watch the state machine self-heal:
aws stepfunctions list-executions \
  --state-machine-arn "$(terraform -chdir=terraform output -raw pipeline_state_machine_arn)" \
  --max-items 5
```

The auto-heal contract: Silver and Gold both use full-scan MERGE with no `is_incremental()` watermark, so corrected `ride_id`s overwrite Silver and the daily Gold aggregation recomputes affected `trip_date`s every run. The orchestrator's job is to fire the chain on data changes, gate Gold on DQ pass, alert on failures, and quarantine the offending (year, month) so Gold never reflects bad data.

Required variables when `enable_pipeline_orchestration = true`:

```hcl
enable_pipeline_orchestration = true
enable_glue_data_quality      = true   # already on by default
alert_email                   = "you@example.com"
# alert_slack_webhook_url     = "https://hooks.slack.com/..."
# pipeline_schedule_expression = "cron(0 6 * * ? *)"
# dbt_batch_vcpu              = 1
# dbt_batch_memory_mb         = 2048
```

The first apply pushes a docker image to a new ECR repo. Allow ~2-3 minutes for the build step.

## Lake Formation Governance

When `enable_lake_formation_governance = true`, Terraform moves data lake governance to Lake Formation for the raw and warehouse S3 buckets:

- Registers the raw and warehouse buckets as Lake Formation resources
- Uses a dedicated Lake Formation data access role for S3 credential vending
- Enables Lake Formation full-table external data access for Glue Spark-based quality checks
- Grants Metabase and Glue Data Quality read access to all tables in the Citi Bike Glue database, including the DQ event observability tables
- Grants data location access to the configured Lake Formation admin and the Glue Data Quality role

The current deployment keeps the dbt Silver observability table for historical BI trends, while Glue DQDL is the authoritative declarative quality rule layer.

Existing Glue databases/tables created before Lake Formation governance may retain `IAM_ALLOWED_PRINCIPALS` grants. After confirming the required admin, BI, and DQ roles have explicit Lake Formation grants, revoke those legacy grants for the Citi Bike database:

```bash
AWS_PROFILE=citibike-lake-dev bash scripts/revoke_lakeformation_iam_allowed_principals.sh
```

## Visualize With Metabase

Set `enable_metabase = true` and restrict `metabase_allowed_cidr_blocks` to your current IP or corporate CIDR. Terraform deploys:

- A dedicated VPC with public subnets for the ALB/ECS task and private subnets for RDS
- ECS Fargate running `metabase/metabase:v0.61.2.x`
- RDS PostgreSQL for the Metabase application database
- Secrets Manager secrets for the initial admin login and Metabase encryption key
- An ECS task role that lets Metabase query Athena through the existing workgroup and read the lake buckets

After Terraform finishes and the ECS service is healthy, initialize Metabase and create an Athena Gold dashboard:

```bash
AWS_PROFILE=citibike-lake-dev python3 scripts/setup_metabase.py
```

The script creates the first admin user, adds an Athena database named `Citi Bike Athena`, and builds a `Citi Bike Gold Ridership` dashboard against `citibike_lake_dev.citibike_daily_ridership_gold`.
It also builds a `Citi Bike Silver Observability` dashboard against `citibike_lake_dev.citibike_trips_silver_observability` when that dbt model has been run.

Useful outputs:

```bash
terraform -chdir=terraform output -raw metabase_url
terraform -chdir=terraform output -raw metabase_admin_secret_arn
```

Fetch the generated admin credentials:

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(terraform -chdir=terraform output -raw metabase_admin_secret_arn)" \
  --query SecretString \
  --output text \
  --profile citibike-lake-dev \
  --region "$(terraform -chdir=terraform output -raw aws_region)"
```

## Notes And Limits

- This setup targets the modern Citi Bike schema with columns such as `ride_id`, `rideable_type`, `started_at`, and `member_casual`.
- Older historical Citi Bike files used different schemas. For a full historical backfill, create a separate normalization job in Glue or EMR before merging to Iceberg.
- Lambda is useful for small or monthly loads, but it is bounded by a 15 minute runtime and 10 GB `/tmp` storage. Large multi-year loads should use Spark.
- Terraform creates saved Athena queries, but does not execute DDL or DML automatically. Keeping query execution explicit avoids surprising query costs and long-running `terraform apply` operations.
- The Metabase ALB is HTTP-only for this dev deployment. For enterprise use, add an ACM certificate, HTTPS listener, authentication controls, and tighter network access.
- The `default` Glue database is intentionally left alone by the Citi Bike Lake Formation hardening script.

## References

- Athena Iceberg table creation: https://docs.aws.amazon.com/athena/latest/ug/querying-iceberg-creating-tables.html
- Athena `MERGE INTO` for Iceberg: https://docs.aws.amazon.com/athena/latest/ug/merge-into-statement.html
- Athena with Glue Data Catalog: https://docs.aws.amazon.com/athena/latest/ug/data-sources-glue.html
- AWS Glue Data Quality DQDL: https://docs.aws.amazon.com/glue/latest/dg/dqdl.html
- AWS Glue Data Quality EventBridge alerts: https://docs.aws.amazon.com/glue/latest/dg/data-quality-alerts.html
- Lake Formation registered data locations: https://docs.aws.amazon.com/lake-formation/latest/dg/register-data-lake.html
- Step Functions Lambda integration: https://docs.aws.amazon.com/step-functions/latest/dg/connect-lambda.html
- Metabase Docker deployment: https://www.metabase.com/docs/latest/installation-and-operation/running-metabase-on-docker
- Metabase Athena connection: https://www.metabase.com/docs/latest/databases/connections/athena
- Terraform `aws_athena_workgroup`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/athena_workgroup
- Terraform `aws_athena_named_query`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/athena_named_query
- Citi Bike system data: https://citibikenyc.com/system-data
