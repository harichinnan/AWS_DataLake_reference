import datetime as dt
import decimal
import json
import logging
import os
import re

import boto3

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

GLUE = boto3.client("glue")
S3 = boto3.client("s3")

SAFE_KEY_RE = re.compile(r"[^A-Za-z0-9_.=-]+")


def handler(event, _context):
    event = event or {}
    detail = event.get("detail") or {}
    result_id = detail.get("resultId") or detail.get("ResultId")
    if not result_id:
        raise ValueError("Glue Data Quality event did not include detail.resultId.")

    result = GLUE.get_data_quality_result(ResultId=result_id)
    target_ruleset = os.environ.get("TARGET_RULESET_NAME", "")
    if target_ruleset and result.get("RulesetName") != target_ruleset:
        LOG.info("Ignoring result %s for non-target ruleset %s", result_id, result.get("RulesetName"))
        return {"status": "ignored", "result_id": result_id, "ruleset_name": result.get("RulesetName")}

    bucket = require_env("OUTPUT_BUCKET")
    run_events_prefix = require_env("RUN_EVENTS_PREFIX").strip("/")
    rule_results_prefix = require_env("RULE_RESULTS_PREFIX").strip("/")

    event_time = parse_event_time(event.get("time"))
    event_date = event_time.date().isoformat()
    observed_at = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")

    run_record = build_run_record(event, result, event_time, observed_at)
    rule_records = build_rule_records(event, result, event_time, observed_at)

    event_id = safe_key(event.get("id", "manual"))
    result_key = safe_key(result_id)
    run_key = f"{run_events_prefix}/event_date={event_date}/{result_key}_{event_id}.json"
    rule_key = f"{rule_results_prefix}/event_date={event_date}/{result_key}_{event_id}.json"

    put_json_lines(bucket, run_key, [run_record])
    put_json_lines(bucket, rule_key, rule_records)

    LOG.info("Persisted Glue DQ result %s to s3://%s/%s and s3://%s/%s", result_id, bucket, run_key, bucket, rule_key)
    return {
        "status": "persisted",
        "result_id": result_id,
        "ruleset_name": result.get("RulesetName"),
        "run_events_s3_uri": f"s3://{bucket}/{run_key}",
        "rule_results_s3_uri": f"s3://{bucket}/{rule_key}",
        "rule_result_count": len(rule_records),
    }


def build_run_record(event, result, event_time, observed_at):
    detail = event.get("detail") or {}
    context = detail.get("context") or {}
    glue_table = (result.get("DataSource") or {}).get("GlueTable") or {}
    rule_results = result.get("RuleResults") or []
    counts = count_rule_results(rule_results)

    return {
        "event_id": event.get("id"),
        "event_time": format_timestamp(event_time),
        "observed_at": observed_at,
        "account_id": event.get("account"),
        "region": event.get("region"),
        "source": event.get("source"),
        "detail_type": event.get("detail-type"),
        "result_id": result.get("ResultId"),
        "profile_id": result.get("ProfileId"),
        "ruleset_name": result.get("RulesetName"),
        "ruleset_names": detail.get("rulesetNames") or ([result.get("RulesetName")] if result.get("RulesetName") else []),
        "state": detail.get("state") or result.get("State"),
        "score": result.get("Score", detail.get("score")),
        "rules_succeeded": first_present(detail, "rulesSucceeded", "numRulesSucceeded", default=counts["succeeded"]),
        "rules_failed": first_present(detail, "rulesFailed", "numRulesFailed", default=counts["failed"]),
        "rules_skipped": first_present(detail, "rulesSkipped", "numRulesSkipped", default=counts["skipped"]),
        "rules_other": counts["other"],
        "run_id": context.get("runId") or result.get("RulesetEvaluationRunId"),
        "context_type": context.get("contextType"),
        "catalog_id": context.get("catalogId") or glue_table.get("CatalogId"),
        "database_name": context.get("databaseName") or glue_table.get("DatabaseName"),
        "table_name": context.get("tableName") or glue_table.get("TableName"),
        "job_id": context.get("jobId"),
        "job_name": context.get("jobName"),
        "evaluation_context": context.get("evaluationContext"),
        "started_on": stringify(result.get("StartedOn")),
        "completed_on": stringify(result.get("CompletedOn")),
        "completed_run_id": result.get("RulesetEvaluationRunId"),
    }


def build_rule_records(event, result, event_time, observed_at):
    detail = event.get("detail") or {}
    context = detail.get("context") or {}
    glue_table = (result.get("DataSource") or {}).get("GlueTable") or {}

    records = []
    for rule in result.get("RuleResults") or []:
        records.append({
            "event_id": event.get("id"),
            "event_time": format_timestamp(event_time),
            "observed_at": observed_at,
            "result_id": result.get("ResultId"),
            "profile_id": result.get("ProfileId"),
            "ruleset_name": result.get("RulesetName"),
            "run_id": context.get("runId") or result.get("RulesetEvaluationRunId"),
            "database_name": context.get("databaseName") or glue_table.get("DatabaseName"),
            "table_name": context.get("tableName") or glue_table.get("TableName"),
            "state": detail.get("state") or result.get("State"),
            "score": result.get("Score", detail.get("score")),
            "rule_name": rule.get("Name"),
            "rule_description": rule.get("Description"),
            "rule_result": rule.get("Result"),
            "evaluation_message": rule.get("EvaluationMessage"),
            "evaluated_metrics_json": json.dumps(rule.get("EvaluatedMetrics") or {}, default=json_default, sort_keys=True),
        })
    return records


def count_rule_results(rule_results):
    counts = {"succeeded": 0, "failed": 0, "skipped": 0, "other": 0}
    for rule in rule_results:
        result = (rule.get("Result") or "").upper()
        if result == "PASS":
            counts["succeeded"] += 1
        elif result == "FAIL":
            counts["failed"] += 1
        elif result in {"SKIP", "SKIPPED"}:
            counts["skipped"] += 1
        else:
            counts["other"] += 1
    return counts


def first_present(mapping, *keys, default=None):
    for key in keys:
        if key in mapping and mapping[key] is not None:
            return mapping[key]
    return default


def put_json_lines(bucket, key, records):
    body = "\n".join(json.dumps(record, default=json_default, separators=(",", ":")) for record in records) + "\n"
    S3.put_object(
        Bucket=bucket,
        Key=key,
        Body=body.encode("utf-8"),
        ContentType="application/x-ndjson",
    )


def parse_event_time(value):
    if isinstance(value, str) and value:
        try:
            return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(dt.timezone.utc)
        except ValueError:
            LOG.warning("Could not parse event time %r; using current UTC time.", value)
    return dt.datetime.now(dt.timezone.utc)


def format_timestamp(value):
    return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def stringify(value):
    if value is None:
        return None
    if isinstance(value, dt.datetime):
        return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    if isinstance(value, dt.date):
        return value.isoformat()
    return str(value)


def json_default(value):
    if isinstance(value, dt.datetime):
        return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    if isinstance(value, dt.date):
        return value.isoformat()
    if isinstance(value, decimal.Decimal):
        return float(value)
    raise TypeError(f"Object of type {type(value).__name__} is not JSON serializable")


def safe_key(value):
    return SAFE_KEY_RE.sub("_", str(value or "unknown"))


def require_env(name):
    value = os.environ.get(name)
    if not value:
        raise ValueError(f"Missing required environment variable: {name}")
    return value
