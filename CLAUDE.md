# Citi Bike Athena Iceberg — Reference Architecture

A small but complete AWS data lake reference built on Citi Bike trip data. Demonstrates how to combine IaC, governance, transformation, BI, and observability without bespoke glue code.

## Architecture Pillars

| Concern | Tool | Where it lives |
|---|---|---|
| 1. IaC / DevOps | **Terraform** | [terraform/](terraform/) |
| 2. Catalog governance | **Lake Formation** (optional, flag-gated) | [terraform/lakeformation.tf](terraform/lakeformation.tf) |
| 3. Transformation (Medallion) | **dbt** on Athena Iceberg | [dbt/](dbt/) |
| 4. BI / Visualization | **Metabase** on ECS Fargate + RDS | [terraform/metabase.tf](terraform/metabase.tf), [scripts/setup_metabase.py](scripts/setup_metabase.py) |
| 5. Observability | **EventBridge → Step Functions → Lambda → Athena** | [terraform/data_quality_events.tf](terraform/data_quality_events.tf), [src/lambda/process_glue_dq_event.py](src/lambda/process_glue_dq_event.py) |
| 6. Resilience (opt-in) | **AWS Batch (Fargate) dbt runner + Step Functions auto-heal pipeline + SNS alerts** | [terraform/dbt_runner.tf](terraform/dbt_runner.tf), [terraform/pipeline.tf](terraform/pipeline.tf), [terraform/triggers.tf](terraform/triggers.tf), [terraform/alerts.tf](terraform/alerts.tf), [terraform/quarantine.tf](terraform/quarantine.tf) |

Storage is S3 with Glue Data Catalog. Compute is Athena (engine v3) for SQL and Lambda for ingest + DQ event processing. Quality is declarative via Glue Data Quality DQDL.

## Data Flow

```
Citi Bike public ZIPs
        │
        ▼  (Lambda: src/lambda/ingest_citibike.py)
s3://…-raw/raw/citibike/trips/year=YYYY/month=MM/*.csv
        │
        ▼  (Athena named queries: terraform/sql/01..04)
Glue Catalog: citibike_lake_dev.citibike_trips_raw  (CSV, external)
        │
        ▼  (dbt: dbt/models/silver/citibike_trips_silver.sql, incremental MERGE)
citibike_trips_silver                                  ← Bronze→Silver
citibike_trips_silver_observability                    ← Silver quality metrics
        │
        ▼  (dbt: dbt/models/gold/citibike_daily_ridership_gold.sql)
citibike_daily_ridership_gold                          ← Silver→Gold
        │
        ▼  (Metabase dashboards via Athena)
"Citi Bike Gold Ridership", "Citi Bike Silver Observability"
```

Parallel to dbt, a Glue Data Quality DQDL ruleset evaluates the Silver Iceberg table. Result events fan out through EventBridge → Step Functions → Lambda, which writes flattened JSONL to S3, surfaced as Athena partition-projected tables (`citibike_glue_dq_run_events`, `citibike_glue_dq_rule_results`).

## Resilience and Auto-Heal (enable_pipeline_orchestration)

When `var.enable_pipeline_orchestration = true`, an additional Step Functions–driven layer wraps the whole pipeline:

```
S3 ObjectCreated (raw/citibike/trips/year=YYYY/month=MM/*)
       │             ┌────────── daily cron safety net ──────────┐
       └─→ EventBridge ─→ pipeline_kicker Lambda ─→ Step Functions ↩
                                                       │
                          ┌────────────────────────────┴────────────────────────────┐
                          │ ParseInput → ClearStaleQuarantine (Athena UPDATE)       │
                          │ → InvokeIngest (Lambda)                                  │
                          │ → MSCK Repair (Athena .sync)                             │
                          │ → dbt build silver+ (Batch Fargate .sync)                │
                          │ → Start Glue DQ + poll until terminal                    │
                          │ → Choice:                                                │
                          │     PASS → dbt build gold+ → Succeed                     │
                          │     FAIL → INSERT INTO quarantine ledger                 │
                          │             → dbt run silver (refilter, post-hook DELETE)│
                          │             → SNS alert → Fail                           │
                          └─────────────────────────────────────────────────────────┘
```

The auto-heal contract: drop a corrected month file at the same S3 key. S3 EventBridge fires. The state machine clears the stale quarantine row first, re-ingests, rebuilds Silver (full-scan MERGE on `ride_id` overwrites the bad rows), re-evaluates Glue DQ, and if green, rebuilds Gold (full-scan recompute on `trip_date` heals affected aggregates). No human intervention required.

### Components added by the resilience layer

| Component | File |
|---|---|
| SNS topic + email/Slack subscriptions + DQ-failure EventBridge rule | [terraform/alerts.tf](terraform/alerts.tf) |
| Quarantine Iceberg ledger (`citibike_quarantined_partitions`) + Athena DDL + bootstrap | [terraform/quarantine.tf](terraform/quarantine.tf), [terraform/sql/06_create_quarantine_ledger.sql.tftpl](terraform/sql/06_create_quarantine_ledger.sql.tftpl) |
| dbt sources for DQ events + quarantine | [dbt/models/sources.yml](dbt/models/sources.yml) |
| Silver anti-join + post-hook DELETE on quarantined partitions | [dbt/models/silver/citibike_trips_silver.sql](dbt/models/silver/citibike_trips_silver.sql), [dbt/models/silver/citibike_quarantine_filter.sql](dbt/models/silver/citibike_quarantine_filter.sql) |
| Gold DQ-status view consumed by Metabase | [dbt/models/gold/citibike_daily_dq_status_gold.sql](dbt/models/gold/citibike_daily_dq_status_gold.sql) |
| Singular test gating Gold on DQ pass | [dbt/tests/gold_only_for_dq_passing_data.sql](dbt/tests/gold_only_for_dq_passing_data.sql) |
| AWS Batch Fargate dbt runner + ECR image | [terraform/dbt_runner.tf](terraform/dbt_runner.tf), [docker/dbt-runner/](docker/dbt-runner/) |
| Step Functions state machine + IAM | [terraform/pipeline.tf](terraform/pipeline.tf), [terraform/pipeline_state_machine.json.tftpl](terraform/pipeline_state_machine.json.tftpl) |
| Triggers (S3 EventBridge + daily cron + kicker Lambda) | [terraform/triggers.tf](terraform/triggers.tf), [src/lambda/pipeline_kicker.py](src/lambda/pipeline_kicker.py) |

## Project Layout

```
.
├── terraform/             # Terraform root module
│   ├── main.tf            # S3, Glue DB, Athena workgroup, ingest Lambda, IAM
│   ├── data_quality.tf    # Glue DQ ruleset + execution role
│   ├── data_quality_events.tf  # EventBridge + Step Functions + DQ event Lambda
│   ├── lakeformation.tf   # Lake Formation registration + grants (flag-gated)
│   ├── metabase.tf        # VPC, ALB, ECS Fargate, RDS, Secrets Manager
│   ├── variables.tf       # All input variables with descriptions
│   ├── outputs.tf
│   ├── versions.tf        # Provider versions + local backend → ../.terraform-state/
│   ├── terraform.tfvars.example
│   ├── sql/               # Athena named-query templates (.tftpl)
│   └── dqdl/              # Glue DQDL ruleset template
├── src/lambda/            # Lambda Python sources
│   ├── ingest_citibike.py
│   └── process_glue_dq_event.py
├── dbt/                   # dbt project (medallion: Silver + Gold)
│   ├── models/silver/
│   ├── models/gold/
│   ├── models/sources.yml
│   ├── tests/             # singular tests (DQ gates)
│   ├── dbt_project.yml
│   └── profiles.yml       # Athena adapter, s3_data_naming = schema_table_unique
├── scripts/               # Helpers — all call `terraform -chdir=terraform`
│   ├── run_dbt.sh
│   ├── run_glue_data_quality.sh
│   ├── run_named_query.sh
│   ├── revoke_lakeformation_iam_allowed_principals.sh
│   └── setup_metabase.py
├── build/                 # Lambda zip artifacts (gitignored)
└── .terraform-state/      # Local Terraform state (gitignored)
```

## Feature Flags (in `terraform.tfvars`)

| Variable | Default | Effect |
|---|---|---|
| `enable_glue_data_quality` | true | Creates the DQDL ruleset, execution role, and (with Lake Formation on) data access grants |
| `enable_glue_data_quality_event_observability` | true | Wires up the EventBridge → Step Functions → Lambda → Athena observability path |
| `enable_lake_formation_governance` | true | Registers raw + warehouse buckets, creates LF data access role, switches grants from `IAM_ALLOWED_PRINCIPALS` to explicit LF grants |
| `enable_metabase` | true | Stands up the Metabase ECS service + RDS |
| `enable_monthly_ingestion_schedule` | false | Creates an EventBridge schedule to invoke the ingest Lambda monthly (bypasses the orchestrator) |
| `enable_pipeline_orchestration` | false | Builds the AWS Batch dbt runner, Step Functions auto-heal pipeline, S3 + cron triggers, and quarantine ledger |
| `alert_email` | `""` | Email subscribed to the data alerts SNS topic; empty disables email |
| `alert_slack_webhook_url` | `""` | Slack incoming webhook subscribed to the SNS topic; empty disables Slack |
| `pipeline_schedule_expression` | `"cron(0 6 * * ? *)"` | Daily safety-net cron for the orchestrator; empty disables |

Toggle these to scope the deployment to just the pillars you want to study.

## Common Workflows

```bash
# Plan / apply (state lives in .terraform-state/, configured via local backend)
AWS_PROFILE=citibike-lake-dev terraform -chdir=terraform plan
AWS_PROFILE=citibike-lake-dev terraform -chdir=terraform apply

# Ingest a month
aws lambda invoke \
  --function-name "$(terraform -chdir=terraform output -raw citibike_ingest_lambda_name)" \
  --payload '{"months":["202601"],"include_jc":false}' \
  --cli-binary-format raw-in-base64-out /tmp/out.json

# Build raw Athena table (run the named queries in order)
bash scripts/run_named_query.sh "$(terraform -chdir=terraform output -json athena_named_query_ids | jq -r .create_raw_table)"
bash scripts/run_named_query.sh "$(terraform -chdir=terraform output -json athena_named_query_ids | jq -r .repair_raw_partitions)"

# dbt — Silver + Gold
AWS_PROFILE=citibike-lake-dev ./scripts/run_dbt.sh run --select citibike_trips_silver+
AWS_PROFILE=citibike-lake-dev ./scripts/run_dbt.sh test

# Glue Data Quality run + result observability lands automatically
AWS_PROFILE=citibike-lake-dev bash scripts/run_glue_data_quality.sh

# Metabase seed (creates admin user + Athena DB + 2 dashboards)
AWS_PROFILE=citibike-lake-dev python3 scripts/setup_metabase.py
```

## CI/CD layout

Pipeline-vs-infra separation lives in [.github/workflows/](.github/workflows/):

- `infra-ci.yml` / `infra-cd.yml` → Terraform plan on PR, apply on main (with `production-apply` Environment approval).
- `dbt-cd.yml` → on merge to main affecting `dbt/**`, tars the project to `s3://<artifacts>/dbt/<sha>.tar.gz` + `latest.tar.gz`. The Batch dbt-runner downloads `latest.tar.gz` at job startup via `DBT_PROJECT_S3_URI` (see [docker/dbt-runner/entrypoint.sh](docker/dbt-runner/entrypoint.sh)).
- `dqdl-cd.yml` → on merge to main affecting `terraform/dqdl/**`, calls `aws glue update-data-quality-ruleset`. The Terraform `aws_glue_data_quality_ruleset` resource has `lifecycle { ignore_changes = [ruleset] }` so subsequent applies don't revert.
- `lambda-cd.yml` → on merge to main affecting `src/lambda/**`, zips and updates each Lambda via `aws lambda update-function-code`. The Lambda resources have `lifecycle { ignore_changes = [filename, source_code_hash] }`.
- `image-cd.yml` → on merge to main affecting `docker/dbt-runner/**`. Rare — the project files were removed from the image.

AWS auth uses GitHub OIDC; two roles ([terraform/cicd.tf](terraform/cicd.tf)):
- `citibike-lake-dev-gha-infra` — Terraform admin (PowerUserAccess + IAMFullAccess)
- `citibike-lake-dev-gha-pipeline` — narrow scope (artifacts S3 PutObject, ECR push, lambda:UpdateFunctionCode, glue:UpdateDataQualityRuleset, LF tag mgmt)

Governance tags taxonomy in [terraform/governance_tags.tf](terraform/governance_tags.tf); per-model tag values in each dbt model's `lf_tags_config` block. dbt-athena applies the tags on every run.

Required repo configuration:
- Actions variables `AWS_ACCOUNT_ID` and `AWS_REGION`
- Environment `production-apply` with required reviewers
- CODEOWNERS handles (currently all `@harichinnan` — swap for real team handles)

## Conventions and Gotchas

- **Terraform root is `terraform/`, not the repo root.** Always pass `-chdir=terraform` (or `cd terraform`). The helper scripts handle this themselves via `$(dirname "$0")/../terraform`.
- **Local backend writes to `../.terraform-state/terraform.tfstate`.** That directory is gitignored except for a `.gitkeep`; on a fresh clone it already exists.
- **Lambda zips build into `build/` (gitignored).** Sources live in `src/lambda/`. The `archive_file` data sources in [terraform/main.tf](terraform/main.tf) and [terraform/data_quality_events.tf](terraform/data_quality_events.tf) reference `${path.module}/../src/lambda/...` and output to `${path.module}/../build/...`.
- **Lake Formation grants replace `IAM_ALLOWED_PRINCIPALS`.** Pre-existing tables created before `enable_lake_formation_governance = true` may still carry the legacy grant. Clean them up with [scripts/revoke_lakeformation_iam_allowed_principals.sh](scripts/revoke_lakeformation_iam_allowed_principals.sh) after confirming explicit grants are in place.
- **dbt uses `s3_data_naming: schema_table_unique`** because Athena Iceberg full-refreshes need unique table locations during dbt's swap/backup flow.
- **The Silver model filters `started_at >= 2026-01-01` and dedupes on `ride_id`.** Older Citi Bike file schemas differ — historical backfill should normalize in Glue/EMR before merging.
- **`citibike_glue_dq_run_events` and `citibike_glue_dq_rule_results` are partition-projected.** No crawler or `MSCK REPAIR TABLE` needed.
- **Metabase ALB is HTTP-only and CIDR-restricted via `metabase_allowed_cidr_blocks`.** For real use, add ACM + HTTPS + SSO.
- **Apple Silicon + Intel Homebrew is a trap.** The AWS provider plugin (~900 MB) crashes Rosetta with a JIT assertion. Install terraform from ARM Homebrew at `/opt/homebrew/` via `brew install hashicorp/tap/terraform`.
- **`enable_pipeline_orchestration = true` adds two host dependencies at apply time:** the `aws` CLI (used by [terraform/quarantine.tf](terraform/quarantine.tf) to bootstrap the Iceberg ledger via Athena) and `docker buildx` (used by [terraform/dbt_runner.tf](terraform/dbt_runner.tf) to build + push the dbt-runner image to ECR). On Apple Silicon both must be functional — the image is forced to `linux/amd64` to match Fargate.
- **Silver and Gold already auto-heal on corrected re-ingest.** Both dbt models use full-scan MERGE with no `is_incremental()` watermark — corrected `ride_id`s overwrite Silver, and the Gold aggregation recomputes all `trip_date`s every run. The resilience layer adds the *trigger, quarantine, and feedback loop* around these models, not the heal mechanic itself.
- **Quarantine is a logical filter, not a physical move.** The ledger entry causes Silver's `where` clause to skip the bad partition; a post-hook `DELETE FROM citibike_trips_silver WHERE (source_year, source_month) IN (quarantine)` removes any previously-merged rows. Once corrected data is re-ingested, Step Functions clears the ledger row (`cleared_at = now()`) and Silver re-includes the partition.

## Reference Material

- Athena Iceberg tables: https://docs.aws.amazon.com/athena/latest/ug/querying-iceberg-creating-tables.html
- Glue Data Quality DQDL: https://docs.aws.amazon.com/glue/latest/dg/dqdl.html
- Glue DQ EventBridge alerts: https://docs.aws.amazon.com/glue/latest/dg/data-quality-alerts.html
- Lake Formation registered data locations: https://docs.aws.amazon.com/lake-formation/latest/dg/register-data-lake.html
- Step Functions Lambda integration: https://docs.aws.amazon.com/step-functions/latest/dg/connect-lambda.html
- Metabase Athena driver: https://www.metabase.com/docs/latest/databases/connections/athena
- Medallion architecture: https://learn.microsoft.com/azure/databricks/lakehouse/medallion (conceptual; we apply it on AWS)
