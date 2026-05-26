"""Starts executions of the citibike data pipeline state machine.

Triggered by:
- EventBridge S3 "Object Created" events for raw/citibike/trips/year=YYYY/month=MM/...
- EventBridge scheduled rules (daily safety net) with detail.trigger_source = "schedule"
- Direct invocations with an explicit {"year": "YYYY", "month": "MM"} payload.

Computes (year, month) and starts the state machine. Uses a minute-floored
execution name so a burst of S3 events on the same partition coalesces into
one state machine execution.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import re
from typing import Any

import boto3

LOG = logging.getLogger(__name__)
LOG.setLevel(logging.INFO)

STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
DEFAULT_INCLUDE_JC = os.environ.get("DEFAULT_INCLUDE_JC", "false").lower() == "true"

sfn = boto3.client("stepfunctions")

S3_KEY_RE = re.compile(r"raw/citibike/trips/year=(?P<year>\d{4})/month=(?P<month>\d{2})/")


def _previous_month(today: dt.date) -> tuple[str, str]:
    first_of_this_month = today.replace(day=1)
    last_of_previous = first_of_this_month - dt.timedelta(days=1)
    return f"{last_of_previous.year:04d}", f"{last_of_previous.month:02d}"


def _execution_name(year: str, month: str, source: str) -> str:
    minute = dt.datetime.utcnow().strftime("%Y%m%dT%H%M")
    name = f"{source}-{year}-{month}-{minute}"
    return re.sub(r"[^A-Za-z0-9_-]", "-", name)[:80]


def _start(year: str, month: str, *, source: str, include_jc: bool) -> dict[str, Any]:
    payload = {
        "year": year,
        "month": month,
        "include_jc": include_jc,
        "trigger_source": source,
    }
    name = _execution_name(year, month, source)
    LOG.info("Starting state machine execution name=%s payload=%s", name, payload)
    try:
        response = sfn.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            name=name,
            input=json.dumps(payload),
        )
        return {"started": True, "executionArn": response["executionArn"], "name": name}
    except sfn.exceptions.ExecutionAlreadyExists:
        LOG.info("Execution %s already running; skipping (dedup)", name)
        return {"started": False, "reason": "ExecutionAlreadyExists", "name": name}


def _partitions_from_s3_events(event: dict[str, Any]) -> set[tuple[str, str]]:
    partitions: set[tuple[str, str]] = set()
    detail = event.get("detail") or {}
    key = (detail.get("object") or {}).get("key")
    if key:
        match = S3_KEY_RE.search(key)
        if match:
            partitions.add((match.group("year"), match.group("month")))
    records = event.get("Records") or []
    for record in records:
        body = record.get("body")
        if not body:
            continue
        try:
            inner = json.loads(body)
        except json.JSONDecodeError:
            continue
        inner_detail = inner.get("detail") or {}
        inner_key = (inner_detail.get("object") or {}).get("key")
        if inner_key:
            match = S3_KEY_RE.search(inner_key)
            if match:
                partitions.add((match.group("year"), match.group("month")))
    return partitions


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    LOG.info("Received event: %s", json.dumps(event)[:2000])

    trigger_source = (event.get("trigger_source") or "manual").lower()
    started: list[dict[str, Any]] = []

    if event.get("year") and event.get("month"):
        started.append(
            _start(
                event["year"],
                event["month"],
                source=trigger_source,
                include_jc=bool(event.get("include_jc", DEFAULT_INCLUDE_JC)),
            )
        )
        return {"started": started}

    detail_type = event.get("detail-type") or ""
    if detail_type == "Scheduled Event" or trigger_source == "schedule":
        year, month = _previous_month(dt.date.today())
        started.append(
            _start(year, month, source="schedule", include_jc=DEFAULT_INCLUDE_JC)
        )
        return {"started": started}

    partitions = _partitions_from_s3_events(event)
    if not partitions:
        LOG.warning("No actionable partitions found in event; nothing to do.")
        return {"started": started, "reason": "no_partition_match"}

    for year, month in sorted(partitions):
        started.append(
            _start(year, month, source="s3", include_jc=DEFAULT_INCLUDE_JC)
        )
    return {"started": started}
