# AWS Auto-Healing Data Lake — Reference Architecture

A blueprint for an AWS data lake that closes the loop between data quality and downstream transformation: when corrected data lands in raw, Silver and Gold rebuild themselves without human intervention. The pattern combines Iceberg medallion transformation on Athena, declarative Glue Data Quality, a quarantine ledger, and a Step Functions orchestrator. Lake Formation governs the catalog and Metabase consumes Gold.

This document describes the pattern. A working reference implementation lives in this repository against open [Citi Bike](https://citibikenyc.com/system-data) monthly trip data; see [Reference implementation](#reference-implementation-citi-bike) and [Deploy and operate](#deploy-and-operate) below. The pattern is dataset-neutral — most teams adapt it by swapping the ingest Lambda, the raw table DDL, the dbt models, and the DQDL ruleset (see [Adapting to your dataset](#adapting-to-your-dataset)).

---

## Problem statement

Most "AWS data lake" references stop after demonstrating ingest → Bronze → Silver → Gold → BI. In production three failure modes show up that aren't addressed by that wiring:

1. **Silent bad data.** Quality runs as a side-channel job, but a failure produces a row in a metrics table and nothing else. Gold keeps serving wrong numbers.
2. **Manual heal toil.** When a publisher republishes a corrected file, an engineer has to remember which downstream tables to re-run, in what order, with what filters. This is error-prone and gets skipped under load.
3. **No transformation-layer feedback loop.** dbt has no awareness of Glue DQ results. The dbt test suite and the DQ ruleset evolve independently, and Gold ends up reflecting partitions that are currently red.

This pattern guarantees: **if a corrected file lands at the same raw S3 key, Silver and Gold are correct within one state-machine execution, with no human in the loop.** A failed quality check quarantines the offending partition until it's corrected; an alert fires; Gold never reflects bad data.

---

## Pattern at a glance

```
        ┌────────────────────────── triggers ──────────────────────────┐
        │  S3 ObjectCreated         daily cron        manual SFN start │
        └──────────────────────┬──────────────────────┬────────────────┘
                               │                      │
                               ▼                      ▼
                       ┌────────────────────────────────────┐
                       │   Step Functions orchestrator      │
                       │                                    │
                       │  1. ClearStaleQuarantine (Athena)  │
                       │  2. Ingest (Lambda)                │──► s3://raw/
                       │  3. MSCK Repair (Athena)           │──► Glue catalog
                       │  4. dbt build silver+ (Batch)      │──► s3://warehouse/silver
                       │  5. Glue DQ on Silver (poll)       │
                       │                                    │
                       │     ┌────── PASS ────┐  ┌── FAIL ──┴─────┐
                       │     ▼                │  ▼                │
                       │  6. dbt build gold+  │  Quarantine row   │
                       │     (Batch)          │  + dbt refilter   │
                       │     │                │  + SNS alert      │
                       │     ▼                │  ▼                │
                       │   Succeed            │  Fail             │
                       └────────────────────────────────────────────┘
                               │                      │
                               ▼                      ▼
                       ┌──────────────┐       ┌──────────────┐
                       │   Metabase   │       │     SNS      │──► email/Slack
                       └──────────────┘       └──────────────┘
                          (BI surface)       (parallel DQ-event alert)
```

Five load-bearing properties hold the pattern together:

- **Medallion with full-scan MERGE on Iceberg.** Silver MERGEs by record key, Gold MERGEs by aggregate grain. No `is_incremental()` watermark — every run is a full recompute against the source. Corrected rows always overwrite stale ones; affected aggregates always recompute.
- **DQDL as the only quality language.** Rules live in one declarative ruleset; no Python validators, no test gates duplicated between dbt and Spark. Glue DQ emits results to EventBridge; everything else consumes those events.
- **Quarantine as a logical filter, not a physical move.** A small Iceberg ledger records which `(source_year, source_month)` partitions are currently red. Silver anti-joins the ledger and a post-hook `DELETE` cleans previously-merged rows. Gold never sees quarantined data.
- **Step Functions owns the chain.** Orchestration logic lives in one place. Retries, branching on DQ result, and SNS alerts all live in the state machine — no glue scripts.
- **Event-driven with a safety net.** S3 `ObjectCreated` events fire the chain near-real-time; a daily cron backstops in case events are lost. Both routes go through the same Lambda kicker and start the same state machine.

---

## Component map

| Layer | Concern | AWS service | Why this choice | Reference file |
|---|---|---|---|---|
| Raw ingest | Pull source data into S3 | Lambda (or Batch for large) | Simple, cheap, easy to wrap in Step Functions | [src/lambda/ingest_citibike.py](src/lambda/ingest_citibike.py) |
| Catalog | Table metadata + partition discovery | Glue Data Catalog + Athena MSCK | Serverless, integrates natively with Athena/Iceberg/Lake Formation | [terraform/main.tf](terraform/main.tf) |
| Bronze | External CSV on S3 | Athena external table | Zero-copy view of raw drops; partition projection avoids `MSCK` for query path | [terraform/sql/01_create_raw_table.sql.tftpl](terraform/sql/01_create_raw_table.sql.tftpl) |
| Silver / Gold | Typed, deduped, BI-ready tables | dbt-athena → Athena Iceberg | dbt gives lineage + tests; Iceberg gives MERGE + time travel | [dbt/models/](dbt/models/) |
| Quality rules | Declarative DQ on Silver | Glue Data Quality (DQDL) | Declarative, catalog-native, emits events | [terraform/dqdl/](terraform/dqdl/) |
| Quality observability | Persist DQ results for BI + tests | EventBridge → Step Functions → Lambda → Athena tables | Decouples DQ runner from consumers; tables are partition-projected | [terraform/data_quality_events.tf](terraform/data_quality_events.tf), [src/lambda/process_glue_dq_event.py](src/lambda/process_glue_dq_event.py) |
| Quarantine | Logical filter on bad partitions | Athena Iceberg ledger table | Tiny, Iceberg-managed, joinable from dbt models | [terraform/quarantine.tf](terraform/quarantine.tf) |
| Transformation runner | Execute dbt in CI/orchestrator | AWS Batch on Fargate | No 15-min Lambda limit; ECR image holds dbt project | [terraform/dbt_runner.tf](terraform/dbt_runner.tf), [docker/dbt-runner/](docker/dbt-runner/) |
| Orchestrator | Chain ingest → repair → Silver → DQ → Gold | Step Functions | Visible, retryable, branches on DQ result, native `.sync` for Athena + Batch | [terraform/pipeline.tf](terraform/pipeline.tf), [terraform/pipeline_state_machine.json.tftpl](terraform/pipeline_state_machine.json.tftpl) |
| Triggers | Event-driven + scheduled entry points | S3 EventBridge + EventBridge cron + Lambda kicker | One Lambda normalizes all triggers and dedupes via state-machine execution name | [terraform/triggers.tf](terraform/triggers.tf), [src/lambda/pipeline_kicker.py](src/lambda/pipeline_kicker.py) |
| Alerting | Notify on DQ failure | SNS + EventBridge rule | Topic is independent of the orchestrator so manual DQ runs also alert | [terraform/alerts.tf](terraform/alerts.tf) |
| Governance | Fine-grained table/column access | Lake Formation | Replaces `IAM_ALLOWED_PRINCIPALS` with explicit grants per role | [terraform/lakeformation.tf](terraform/lakeformation.tf) |
| BI surface | Dashboards over Gold | Metabase on ECS Fargate + RDS | Native Athena driver; one task to seed dashboards | [terraform/metabase.tf](terraform/metabase.tf), [scripts/setup_metabase.py](scripts/setup_metabase.py) |

---

## The auto-heal contract

"Auto-heal" means: **the system reaches the correct end state for any (year, month) partition after the orchestrator runs against it once.** No manual cleanup, no out-of-band scripts, no inconsistent dashboards.

The contract relies on three deliberate design choices:

### Silver — full-scan MERGE by record key

Silver is configured as a dbt Iceberg incremental model with `incremental_strategy='merge'`, `unique_key='ride_id'` (or your equivalent record key), and **no `is_incremental()` watermark**. Every run reads the entire Bronze partition set, joins against the quarantine filter to drop currently-red partitions, and MERGEs by record key. A corrected row with the same key updates the existing Silver row. A post-hook then DELETEs rows whose `(source_year, source_month)` is in the active quarantine set:

```sql
{{
  config(
    materialized='incremental',
    table_type='iceberg',
    incremental_strategy='merge',
    unique_key='ride_id',
    unique_tmp_table_suffix=true,
    post_hook=[
      "delete from {{ this }} where (source_year, source_month) in "
      "(select source_year, source_month from {{ ref('quarantine_filter') }})"
    ]
  )
}}
```

### Gold — full-scan aggregation MERGED by grain

Gold is configured similarly: incremental Iceberg MERGE, `unique_key='trip_date'` (or your aggregate grain), no `is_incremental()` filter. Every run aggregates the *current* Silver by the grain key. If a corrected record shifted the date of a trip from Jan 15 to Jan 16, both the Jan 15 and Jan 16 aggregates are recomputed and MERGEd in one pass. Affected dates always reach the right value.

### Quarantine ledger

A small Iceberg table tracks which `(source_year, source_month)` partitions are currently failing. The Step Functions orchestrator:

1. **Before** ingest, `UPDATE`s the ledger to set `cleared_at = current_timestamp` for the partition being processed. A successful re-ingest naturally exits quarantine.
2. **On DQ failure**, `INSERT`s a new active row (`cleared_at IS NULL`). The follow-up dbt Silver refilter run picks up the new ledger entry and the post-hook DELETE removes any already-merged bad rows.
3. Gold sees only the partitions that passed DQ, by virtue of Silver having dropped them.

### End-to-end walkthrough

```
T+0   bad CSV uploaded → S3 ObjectCreated event
T+1   pipeline_kicker Lambda extracts (year, month), starts state machine
T+2   ClearStaleQuarantine (Athena)
T+3   Ingest Lambda re-downloads or no-ops
T+4   MSCK Repair Table
T+5   Batch dbt build silver+ (full-scan MERGE)
T+6   Glue DQ on silver — FAILS (e.g. duplicate ride_id)
T+7   INSERT quarantine row for (2026, 04)
T+8   Batch dbt run silver — post-hook DELETE removes bad partition from Silver
T+9   SNS publishes alert; state machine ends in Failed

…later, corrected CSV uploaded at same key…

T+0'  S3 ObjectCreated event again
T+1'  pipeline_kicker starts state machine
T+2'  ClearStaleQuarantine sets cleared_at = now() for (2026, 04)
T+3'  Ingest overwrites raw
T+4'  MSCK Repair Table
T+5'  Batch dbt build silver+ — quarantine filter now empty, partition re-included,
       MERGE overwrites stale ride_id rows with corrected values
T+6'  Glue DQ passes
T+7'  Batch dbt build gold+ — recomputes aggregates for affected dates
T+8'  Succeed
```

---

## Layers in detail

### Bronze: raw ingest

A small Lambda function fetches source files (HTTP, S3 sync, API pull, queue drain — your choice) and writes them to a partitioned prefix on the raw bucket. Idempotency comes from writing to deterministic keys (`year=YYYY/month=MM/<file>`), so re-ingest naturally overwrites. The bucket has S3 versioning enabled for rollback.

### Catalog and partition discovery

The raw layer is an Athena `EXTERNAL TABLE` over the partitioned S3 prefix. The orchestrator runs `MSCK REPAIR TABLE` after each ingest to register new partitions. (For higher-throughput use cases, partition projection on a `year`/`month` key avoids MSCK entirely.)

### Silver: typed, deduped, merged

dbt-athena materializes Silver as an Iceberg incremental MERGE model. Typing happens here via `try_cast`, and the model deduplicates with `row_number() over (partition by record_key order by …)`. The Silver SELECT anti-joins the quarantine filter; the post-hook DELETEs already-merged quarantined rows.

### Quality gate: declarative DQDL

A Glue Data Quality ruleset (DQDL) evaluates Silver after every Step Functions run. Rules cover row count, uniqueness, value ranges, accepted enums, and column completeness. Glue emits an EventBridge event when each run finishes. Two consumers attach to that event:

1. **Observability path.** A separate Step Functions workflow + Lambda persists every result to Athena tables (`glue_dq_run_events`, `glue_dq_rule_results`) for historical reporting and dbt visibility.
2. **Alert path.** A parallel EventBridge rule routes any non-`SUCCEEDED` event to SNS.

The main pipeline orchestrator polls Glue DQ directly via `aws-sdk:glue:getDataQualityRulesetEvaluationRun` and branches on the result.

### Gold: BI-ready aggregates

dbt-athena materializes Gold the same way as Silver: full-scan recompute, Iceberg MERGE by aggregate grain. A separate Gold view joins ridership-style aggregates with the latest DQ run's status, surfacing `quarantined` and `latest_dq_failing_rule_names` as columns for Metabase. A dbt singular test gates the run: it fails if Gold contains a `trip_date` whose `(source_year, source_month)` is failing DQ and is not currently quarantined.

### Resilience: Step Functions + Batch + alerts

The orchestrator (state machine) is the only thing that knows the order of operations. dbt jobs run in AWS Batch on Fargate — a Docker image with `dbt-athena-community` and the dbt project, pushed to ECR at apply time. Step Functions submits jobs via `.sync` integration and waits for completion. Alerts route through SNS regardless of who triggered the run.

### Governance: Lake Formation (optional)

When enabled, the raw and warehouse buckets are registered as Lake Formation resources, a dedicated data-access role vends S3 credentials, and `IAM_ALLOWED_PRINCIPALS` grants are replaced with explicit Lake Formation grants per consumer (Metabase, Glue DQ, dbt runner). The orchestrator role receives table-level grants on the Citi Bike database wildcard, so it can `INSERT` into the quarantine ledger and `ALTER` the raw table for MSCK.

### BI surface: Metabase

A Fargate ECS task runs Metabase, fronted by an ALB and backed by RDS PostgreSQL. A bootstrap script ([scripts/setup_metabase.py](scripts/setup_metabase.py)) creates the admin user, registers the Athena database, and seeds two dashboards — one for Gold ridership and one for the DQ status feed.

---

## Adapting to your dataset

The pattern is dataset-neutral. To retarget it, swap five files. Everything else — the orchestrator, the quarantine ledger, the dbt-DQ integration, the alerting, the Lake Formation wiring — is reused unchanged.

| # | What to swap | Path | Note |
|---|---|---|---|
| 1 | Ingest logic | [src/lambda/ingest_citibike.py](src/lambda/ingest_citibike.py) | Replace with your fetch logic. Keep the payload schema `{"months": [...], "include_jc": false}` or update the state-machine input transformer in [terraform/pipeline_state_machine.json.tftpl](terraform/pipeline_state_machine.json.tftpl). |
| 2 | Raw table DDL | [terraform/sql/01_create_raw_table.sql.tftpl](terraform/sql/01_create_raw_table.sql.tftpl) | Adjust columns, format, and partition keys. Keep `year=`/`month=` partition style if you reuse the kicker Lambda's key regex. |
| 3 | Silver and Gold dbt models | [dbt/models/](dbt/models/) | Replace `citibike_trips_silver.sql` and `citibike_daily_ridership_gold.sql`. Preserve the `incremental_strategy='merge'`, `unique_tmp_table_suffix=true`, and post-hook DELETE pattern. |
| 4 | DQDL ruleset | [terraform/dqdl/citibike_trips_silver.dqdl.tftpl](terraform/dqdl/citibike_trips_silver.dqdl.tftpl) | Write rules that target your Silver table. The state machine reads the ruleset name from the Terraform output, so renames flow automatically. |
| 5 | Metabase dashboards | [scripts/setup_metabase.py](scripts/setup_metabase.py) | Replace the question + dashboard definitions, or skip and curate dashboards in the Metabase UI after deploy. |

Optional swap-points: the kicker Lambda's regex if your S3 key shape differs ([src/lambda/pipeline_kicker.py](src/lambda/pipeline_kicker.py)), and the alert SNS subject/message template ([terraform/alerts.tf](terraform/alerts.tf)).

What you do **not** rewrite: the Step Functions state machine definition, the IAM roles, the Batch compute environment, the quarantine ledger schema, the EventBridge/SNS wiring, the dbt-DQ source declarations.

---

## Reference implementation: Citi Bike

This repository deploys the pattern against open [Citi Bike monthly trip CSV files](https://citibikenyc.com/system-data). The included Lambda downloads ZIP files from `s3://tripdata` and writes extracted CSVs to the raw bucket; the dbt models type and dedupe rides; the DQDL ruleset checks `ride_id` uniqueness, valid durations, station completeness, and geographic bounds; the Metabase seed script builds a daily ridership dashboard. The data is small enough to run end-to-end in a dev account in minutes.

---

## Project layout

```
.
├── terraform/                        # Terraform root module
│   ├── main.tf                       # S3, Glue DB, Athena, ingest Lambda
│   ├── data_quality.tf               # DQDL ruleset + execution role
│   ├── data_quality_events.tf        # DQ event observability state machine
│   ├── lakeformation.tf              # LF registration + grants
│   ├── metabase.tf                   # VPC, ALB, ECS, RDS
│   ├── dbt_runner.tf                 # ECR + Batch Fargate dbt runner
│   ├── pipeline.tf                   # Auto-heal orchestrator state machine
│   ├── pipeline_state_machine.json.tftpl
│   ├── triggers.tf                   # S3 events + daily cron + kicker Lambda
│   ├── alerts.tf                     # SNS topic + DQ-failure rule
│   ├── quarantine.tf                 # Iceberg ledger + Athena DDL bootstrap
│   ├── variables.tf  outputs.tf  versions.tf  terraform.tfvars.example
│   ├── sql/                          # Athena SQL templates
│   └── dqdl/                         # DQDL ruleset template
├── src/lambda/                       # Python: ingest + DQ event proc + kicker
├── dbt/                              # dbt project (Silver + Gold + DQ views)
├── docker/dbt-runner/                # Dockerfile for the Batch dbt image
├── scripts/                          # Shell + Python helpers
├── build/                            # Lambda zip + docker context artifacts (gitignored)
└── .terraform-state/                 # Local backend state (gitignored)
```

The Terraform root is [terraform/](terraform/), not the repository root. Run `terraform -chdir=terraform …` or `cd terraform` first. The state backend is configured in [terraform/versions.tf](terraform/versions.tf) to write to `../.terraform-state/terraform.tfstate`.

---

## Deploy and operate

### AWS prerequisites

- Target account ID + region
- AWS credentials with permission for S3, Glue, Athena, Lambda, IAM, EventBridge, Step Functions, SNS, ECR, Batch, ECS, RDS, Secrets Manager, VPC, Lake Formation, CloudWatch Logs
- A Lake Formation administrator principal ARN (typically your IAM Identity Center admin role)
- `docker buildx` and the `aws` CLI installed locally — both are invoked at apply time via `null_resource` (Docker image build, Athena DDL bootstrap)

### Quickstart

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your account ID, region, LF admin ARN, alert_email

terraform init
terraform apply
```

First apply takes ~10 minutes: most of it is the Docker image build for the dbt-runner. Subsequent applies that don't change the image are fast.

To turn on the orchestrated auto-heal pipeline, set:

```hcl
enable_pipeline_orchestration = true
enable_glue_data_quality      = true   # required prerequisite
alert_email                   = "you@example.com"
# alert_slack_webhook_url     = "https://hooks.slack.com/..."   # optional
# pipeline_schedule_expression = "cron(0 6 * * ? *)"            # daily safety net
```

Without `enable_pipeline_orchestration`, the foundational layer (SNS alerts on DQ failures, quarantine ledger, dbt-DQ source integration) still deploys; just the Step Functions chain and triggers are skipped.

### Feature flags

| Variable | Default | Effect |
|---|---|---|
| `enable_glue_data_quality` | `true` | DQDL ruleset + execution role + Lake Formation grants |
| `enable_glue_data_quality_event_observability` | `true` | EventBridge → Step Functions → Lambda → Athena observability path |
| `enable_lake_formation_governance` | `true` | Registers raw + warehouse, switches grants from `IAM_ALLOWED_PRINCIPALS` to explicit LF grants |
| `enable_metabase` | `true` | Metabase ECS service + RDS |
| `enable_monthly_ingestion_schedule` | `false` | Direct monthly invocation of the ingest Lambda (bypasses orchestrator) |
| `enable_pipeline_orchestration` | `false` | Batch dbt runner + Step Functions auto-heal pipeline + S3/cron triggers + quarantine bootstrap |
| `alert_email` | `""` | Email subscribed to the SNS alerts topic |
| `alert_slack_webhook_url` | `""` | Slack webhook subscribed to SNS |
| `pipeline_schedule_expression` | `cron(0 6 * * ? *)` | Daily safety-net cron; empty disables |

### Common operations

```bash
# Trigger the pipeline manually for one partition
aws stepfunctions start-execution \
  --state-machine-arn "$(terraform -chdir=terraform output -raw pipeline_state_machine_arn)" \
  --input '{"year":"2026","month":"04","include_jc":false,"trigger_source":"manual"}'

# Inspect active quarantine entries
aws athena start-query-execution \
  --work-group "$(terraform -chdir=terraform output -raw athena_workgroup_name)" \
  --query-execution-context "Database=$(terraform -chdir=terraform output -raw glue_database_name)" \
  --query-string "SELECT * FROM citibike_quarantined_partitions WHERE cleared_at IS NULL"

# Run dbt against the dev profile (uses local AWS creds, bypasses Batch)
AWS_PROFILE=… ./scripts/run_dbt.sh build --select citibike_trips_silver+

# Re-ingest a month directly
aws lambda invoke \
  --function-name "$(terraform -chdir=terraform output -raw citibike_ingest_lambda_name)" \
  --payload '{"months":["202604"],"include_jc":false}' --cli-binary-format raw-in-base64-out /tmp/out.json
```

---

## CI/CD and ownership model

The repo separates **DevOps** (infrastructure) from **pipeline code** (transformation logic, quality rules, Lambda business logic). Each lifecycle has its own GitHub Actions workflow under [.github/workflows/](.github/workflows/), and a [.github/CODEOWNERS](.github/CODEOWNERS) file routes PR review to the right team by path.

Two IAM roles trust the GitHub OIDC provider (no long-lived secrets):

- **`citibike-lake-dev-gha-infra`** — assumed by `infra-*.yml` workflows. Terraform admin permissions. Used for `terraform plan` and `terraform apply`.
- **`citibike-lake-dev-gha-pipeline`** — assumed by `dbt-cd.yml`, `dqdl-cd.yml`, `lambda-cd.yml`, `image-cd.yml`. Narrow scope: S3 PutObject on the artifacts bucket, ECR push on the dbt-runner repo, `lambda:UpdateFunctionCode` on the project Lambdas, `glue:UpdateDataQualityRuleset`, Lake Formation tag application.

### Workflow set

| Workflow | Trigger (path filter) | What it does |
|---|---|---|
| [infra-ci.yml](.github/workflows/infra-ci.yml) | PR on `terraform/**` | fmt, validate, `terraform plan`, post plan as PR comment |
| [infra-cd.yml](.github/workflows/infra-cd.yml) | push to main on `terraform/**` | plan → GitHub Environment approval → `terraform apply` |
| [dbt-ci.yml](.github/workflows/dbt-ci.yml) | PR on `dbt/**` | install dbt-athena, `dbt parse` |
| [dbt-cd.yml](.github/workflows/dbt-cd.yml) | push to main on `dbt/**` | tar dbt project, upload to `s3://artifacts/dbt/<sha>.tar.gz` + bump `latest.tar.gz` |
| [dqdl-ci.yml](.github/workflows/dqdl-ci.yml) | PR on `terraform/dqdl/**` | render template, structural check |
| [dqdl-cd.yml](.github/workflows/dqdl-cd.yml) | push to main on `terraform/dqdl/**` | render, archive to S3, `aws glue update-data-quality-ruleset` |
| [lambda-cd.yml](.github/workflows/lambda-cd.yml) | push to main on `src/lambda/**` | zip per Lambda, upload to S3, `aws lambda update-function-code` |
| [image-cd.yml](.github/workflows/image-cd.yml) | push to main on `docker/dbt-runner/**` | `docker buildx build --push` to ECR (rare; project code is no longer in the image) |

### How pipeline code reaches the runtime

The Docker image at [docker/dbt-runner/](docker/dbt-runner/) installs `dbt-athena-community` only — the dbt project is **not** baked in. At Batch job startup, [docker/dbt-runner/entrypoint.sh](docker/dbt-runner/entrypoint.sh) downloads the project tarball from S3 (`s3://<artifacts>/dbt/latest.tar.gz`, set as `DBT_PROJECT_S3_URI` on the Batch job definition) and extracts it into `/opt/dbt`. A dbt model change ships as a single `aws s3 cp` from CI — no Docker rebuild, no terraform apply.

The Glue DQ ruleset, the three Lambda function codes, and the dbt-runner image are all created initially by Terraform but managed in steady state by CI: Terraform's `lifecycle { ignore_changes = … }` blocks tell it not to revert mutations made by the pipeline workflows.

### Governance tag flow

Lake Formation tag taxonomy ([terraform/governance_tags.tf](terraform/governance_tags.tf)) is platform-owned: tag keys (`domain`, `pii_level`, `freshness_tier`, `layer`), allowed values, and tag-based grants (e.g., any principal can `SELECT` from `pii_level in {none, low}` tables). Tag *assignment* per model lives in dbt: each model's `config()` block sets `lf_tags_config` with the values that apply. dbt-athena pushes the tags on every materialization, so a model rename or tag-value change ships through `dbt-cd.yml` like any other pipeline change.

### Required GitHub configuration

For the workflows above to run, configure on the repo:

| Setting | Value |
|---|---|
| Actions variable `AWS_ACCOUNT_ID` | Your account ID |
| Actions variable `AWS_REGION` | e.g. `us-east-1` |
| Environment `production-apply` | Add required reviewers; `infra-cd.yml` blocks here |
| CODEOWNERS | Replace `@harichinnan` with your team handles |

### Adapting to multiple environments

For a real production deployment, duplicate the OIDC roles and S3 artifacts bucket per environment (separate AWS accounts), parameterize the workflows by environment name (matrix or per-env workflow), and tag the trust policy with environment-specific `sub` constraints (e.g. `repo:org/repo:environment:prod`). The reference deploys a single environment; the workflow files are written so this extension is mostly a copy-rename.

## Operations and gotchas

- **dbt-athena Iceberg incremental needs `unique_tmp_table_suffix=true`.** Without it, the `__dbt_tmp` table name is shared across runs and Iceberg's "non-empty location" check fires intermittently. All incremental Iceberg models in [dbt/models/](dbt/models/) set this.
- **Stale `__dbt_tmp/<uuid>/` artifacts can block CTAS.** If a Batch dbt job is killed mid-build, the next run may hit `ICEBERG_FILESYSTEM_ERROR: Cannot create a table on a non-empty location`. Clean with `aws s3 rm s3://<warehouse>/warehouse/<schema>/<table>__dbt_tmp/ --recursive`. Also clean `s3://<athena-results>/athena-results/tables/`.
- **First apply needs `docker buildx` and `aws` CLI on the local machine.** Both are invoked through `null_resource`'s `local-exec`. The dbt-runner image is built `--platform linux/amd64` to match Fargate.
- **Apple Silicon traps: Intel Homebrew terraform crashes Rosetta.** The AWS provider plugin (~900 MB) hits a JIT assertion. Use the ARM Homebrew at `/opt/homebrew/` and install via `brew install hashicorp/tap/terraform`. See [CLAUDE.md](CLAUDE.md) for full details.
- **`enable_pipeline_orchestration = true` requires `enable_glue_data_quality = true`.** The orchestrator and its IAM grants depend on the DQDL ruleset and Glue role existing.
- **The Step Functions `aws-sdk:glue:startDataQualityRulesetEvaluationRun` integration is not `.sync`-capable.** The state machine polls `getDataQualityRulesetEvaluationRun` in a `Wait` + `Choice` loop.
- **Lake Formation requires every consumer role to be granted explicit table/data-location access.** [terraform/lakeformation.tf](terraform/lakeformation.tf) handles Metabase, Glue DQ, and (when orchestration is on) the dbt runner and SFN role. Custom roles need their own `aws_lakeformation_permissions` entry.

---

## Further reading

### AWS service docs used by this pattern

- Athena Iceberg tables: <https://docs.aws.amazon.com/athena/latest/ug/querying-iceberg-creating-tables.html>
- Athena `MERGE INTO` for Iceberg: <https://docs.aws.amazon.com/athena/latest/ug/merge-into-statement.html>
- Glue Data Quality DQDL: <https://docs.aws.amazon.com/glue/latest/dg/dqdl.html>
- Glue Data Quality EventBridge alerts: <https://docs.aws.amazon.com/glue/latest/dg/data-quality-alerts.html>
- Lake Formation registered data locations: <https://docs.aws.amazon.com/lake-formation/latest/dg/register-data-lake.html>
- Step Functions Lambda + Batch + Athena integrations: <https://docs.aws.amazon.com/step-functions/latest/dg/connect-to-services.html>
- Step Functions AWS SDK service integrations: <https://docs.aws.amazon.com/step-functions/latest/dg/supported-services-awssdk.html>
- AWS Batch on Fargate: <https://docs.aws.amazon.com/batch/latest/userguide/fargate.html>
- Metabase Athena driver: <https://www.metabase.com/docs/latest/databases/connections/athena>

### Conceptual references

- Medallion architecture (Databricks original, conceptually transferable): <https://learn.microsoft.com/azure/databricks/lakehouse/medallion>
- dbt incremental materializations: <https://docs.getdbt.com/docs/build/incremental-models>
- dbt-athena adapter: <https://github.com/dbt-athena/dbt-athena>
- Citi Bike system data (the example dataset): <https://citibikenyc.com/system-data>
