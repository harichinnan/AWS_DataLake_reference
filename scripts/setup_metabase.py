#!/usr/bin/env python3
"""Initialize Metabase and seed a Citi Bike Athena Gold dashboard."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


def run_json(command: list[str]) -> dict[str, Any]:
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    return json.loads(completed.stdout)


def terraform_outputs() -> dict[str, Any]:
    terraform_dir = os.environ.get(
        "TERRAFORM_DIR",
        os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "terraform")),
    )
    raw = run_json(["terraform", f"-chdir={terraform_dir}", "output", "-json"])
    return {key: value.get("value") for key, value in raw.items()}


def get_secret(secret_id: str, region: str, profile: str | None) -> dict[str, str]:
    command = [
        "aws",
        "secretsmanager",
        "get-secret-value",
        "--secret-id",
        secret_id,
        "--region",
        region,
    ]
    if profile:
        command.extend(["--profile", profile])
    response = run_json(command)
    secret_string = response.get("SecretString")
    if not secret_string:
        raise RuntimeError(f"Secret {secret_id} did not contain SecretString")
    return json.loads(secret_string)


class MetabaseClient:
    def __init__(self, base_url: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.session_id: str | None = None

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        expected: tuple[int, ...] = (200,),
    ) -> Any:
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=data,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        if self.session_id:
            request.add_header("X-Metabase-Session", self.session_id)

        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read().decode("utf-8")
                if response.status not in expected:
                    raise RuntimeError(f"{method} {path} returned HTTP {response.status}: {body}")
                if not body:
                    return None
                return json.loads(body)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {path} returned HTTP {error.code}: {body}") from error

    def wait_until_ready(self, timeout_seconds: int) -> None:
        deadline = time.time() + timeout_seconds
        last_error = "not checked yet"
        while time.time() < deadline:
            try:
                response = self.request("GET", "/api/health")
                if response and response.get("status") in {"ok", "healthy"}:
                    return
            except Exception as exc:  # noqa: BLE001 - keep polling while the ALB target warms up.
                last_error = str(exc)
            time.sleep(10)
        raise TimeoutError(f"Metabase did not become healthy within {timeout_seconds}s: {last_error}")

    def setup_or_login(self, email: str, password: str, site_name: str) -> None:
        properties = self.request("GET", "/api/session/properties")
        setup_token = properties.get("setup-token")
        if setup_token:
            try:
                response = self.request(
                    "POST",
                    "/api/setup",
                    {
                        "token": setup_token,
                        "user": {
                            "first_name": "Citi Bike",
                            "last_name": "Admin",
                            "email": email,
                            "password": password,
                        },
                        "prefs": {
                            "site_name": site_name,
                            "site_locale": "en",
                        },
                    },
                )
                self.session_id = response["id"]
                return
            except RuntimeError as exc:
                if "a user currently exists" not in str(exc):
                    raise

        response = self.request(
            "POST",
            "/api/session",
            {"username": email, "password": password},
        )
        self.session_id = response["id"]

    def find_search_item(self, model: str, name: str) -> dict[str, Any] | None:
        query = urllib.parse.urlencode({"q": name})
        response = self.request("GET", f"/api/search?{query}")
        items = response.get("data", response) if isinstance(response, dict) else response
        for item in items or []:
            if item.get("name") == name and item.get("model") == model:
                return item
        return None

    def ensure_collection(self, name: str, description: str) -> int:
        existing = self.find_search_item("collection", name)
        if existing:
            return int(existing["id"])
        response = self.request(
            "POST",
            "/api/collection",
            {"name": name, "description": description},
        )
        return int(response["id"])

    def ensure_database(self, payload: dict[str, Any]) -> int:
        response = self.request("GET", "/api/database")
        for database in response.get("data", []):
            if database.get("name") == payload["name"] and database.get("engine") == payload["engine"]:
                return int(database["id"])

        created = self.request("POST", "/api/database", payload)
        database_id = int(created["id"])
        try:
            self.request("POST", f"/api/database/{database_id}/sync_schema", {}, expected=(200, 202))
        except Exception as exc:  # noqa: BLE001 - dashboard SQL works even if async schema sync was already queued.
            print(f"Schema sync request was not accepted, continuing: {exc}", file=sys.stderr)
        return database_id

    def ensure_card(self, payload: dict[str, Any]) -> int:
        existing = self.find_search_item("card", payload["name"])
        if existing:
            card_id = int(existing["id"])
            self.request("PUT", f"/api/card/{card_id}", payload)
            return card_id
        created = self.request("POST", "/api/card", payload)
        return int(created["id"])

    def ensure_dashboard(self, name: str, description: str, collection_id: int) -> int:
        existing = self.find_search_item("dashboard", name)
        if existing:
            dashboard_id = int(existing["id"])
            self.request(
                "PUT",
                f"/api/dashboard/{dashboard_id}",
                {
                    "name": name,
                    "description": description,
                    "collection_id": collection_id,
                    "parameters": [],
                },
            )
            return dashboard_id
        created = self.request(
            "POST",
            "/api/dashboard",
            {
                "name": name,
                "description": description,
                "collection_id": collection_id,
                "parameters": [],
            },
        )
        return int(created["id"])

    def set_dashboard_cards(self, dashboard_id: int, cards: list[dict[str, Any]]) -> None:
        dashboard = self.request("GET", f"/api/dashboard/{dashboard_id}")
        existing_by_card_id = {}
        for dashcard in dashboard.get("dashcards", []):
            card_id = dashcard.get("card_id") or (dashcard.get("card") or {}).get("id")
            if card_id:
                existing_by_card_id[int(card_id)] = dashcard

        dashcards = []
        next_new_id = -1
        for card in cards:
            card_id = int(card["card_id"])
            existing = existing_by_card_id.get(card_id)
            dashcards.append(
                {
                    "id": int(existing["id"]) if existing else next_new_id,
                    "card_id": card_id,
                    "size_x": card["size_x"],
                    "size_y": card["size_y"],
                    "row": card["row"],
                    "col": card["col"],
                    "parameter_mappings": [],
                    "series": [],
                }
            )
            if not existing:
                next_new_id -= 1

        self.request("PUT", f"/api/dashboard/{dashboard_id}/cards", {"cards": dashcards, "tabs": []})


def card_payload(
    name: str,
    description: str,
    display: str,
    sql: str,
    database_id: int,
    collection_id: int,
    visualization_settings: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "name": name,
        "description": description,
        "display": display,
        "visualization_settings": visualization_settings or {},
        "collection_id": collection_id,
        "dataset_query": {
            "type": "native",
            "database": database_id,
            "native": {
                "query": sql.strip(),
                "template-tags": {},
            },
        },
    }


def build_gold_cards(database_id: int, collection_id: int, table: str) -> list[dict[str, Any]]:
    return [
        card_payload(
            "Total Citi Bike Rides",
            "Total rides in the Athena Gold daily ridership table.",
            "scalar",
            f"select sum(total_rides) as total_rides from {table}",
            database_id,
            collection_id,
        ),
        card_payload(
            "Daily Citi Bike Ridership",
            "Daily rides split by member, casual, electric, and classic rides.",
            "line",
            f"""
            select
              trip_date,
              total_rides,
              member_rides,
              casual_rides,
              electric_bike_rides,
              classic_bike_rides
            from {table}
            order by trip_date
            """,
            database_id,
            collection_id,
        ),
        card_payload(
            "Member vs Casual Rides",
            "Rides by rider membership type.",
            "bar",
            f"""
            select 'member' as rider_type, sum(member_rides) as rides from {table}
            union all
            select 'casual' as rider_type, sum(casual_rides) as rides from {table}
            order by rides desc
            """,
            database_id,
            collection_id,
        ),
        card_payload(
            "Ride Duration Trend",
            "Average and p90 ride duration by day.",
            "line",
            f"""
            select
              trip_date,
              average_duration_seconds / 60.0 as average_duration_minutes,
              p90_duration_seconds / 60.0 as p90_duration_minutes
            from {table}
            order by trip_date
            """,
            database_id,
            collection_id,
        ),
        card_payload(
            "Top Ridership Days",
            "Highest daily ride counts.",
            "table",
            f"""
            select
              trip_date,
              total_rides,
              member_rides,
              casual_rides,
              electric_bike_rides,
              average_duration_seconds / 60.0 as average_duration_minutes
            from {table}
            order by total_rides desc
            limit 10
            """,
            database_id,
            collection_id,
        ),
    ]


def build_silver_observability_cards(database_id: int, collection_id: int, table: str) -> list[dict[str, Any]]:
    return [
        card_payload(
            "Silver Quality Status",
            "Daily pass/warn/fail counts from the Silver observability table.",
            "bar",
            f"""
            select
              quality_status,
              count(*) as days,
              sum(total_rides) as total_rides
            from {table}
            group by quality_status
            order by quality_status
            """,
            database_id,
            collection_id,
        ),
        card_payload(
            "Silver Daily Ride Volume",
            "Daily Silver row counts.",
            "line",
            f"""
            select
              trip_date,
              total_rides
            from {table}
            order by trip_date
            """,
            database_id,
            collection_id,
        ),
        card_payload(
            "Silver Invalid Duration Rate",
            "Daily invalid ride duration rate.",
            "line",
            f"""
            select
              trip_date,
              invalid_duration_rate
            from {table}
            order by trip_date
            """,
            database_id,
            collection_id,
        ),
        card_payload(
            "Silver Missing Station And Geo Rates",
            "Daily missing station and missing coordinate rates.",
            "line",
            f"""
            select
              trip_date,
              missing_station_rate,
              missing_geo_rate
            from {table}
            order by trip_date
            """,
            database_id,
            collection_id,
        ),
        card_payload(
            "Silver Warning And Failure Days",
            "Silver days that need inspection.",
            "table",
            f"""
            select
              trip_date,
              quality_status,
              total_rides,
              duplicate_ride_ids,
              invalid_duration_rate,
              missing_station_rate,
              missing_geo_rate,
              out_of_bounds_geo_rides,
              invalid_rideable_type_rides,
              invalid_member_type_rides
            from {table}
            where quality_status <> 'pass'
            order by trip_date
            """,
            database_id,
            collection_id,
        ),
    ]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", help="Metabase base URL. Defaults to terraform output metabase_url.")
    parser.add_argument("--admin-secret-id", help="Secrets Manager secret ID/ARN for admin credentials.")
    parser.add_argument("--aws-profile", default=os.environ.get("AWS_PROFILE"), help="AWS profile for reading secrets.")
    parser.add_argument("--region", help="AWS region. Defaults to terraform output aws_region.")
    parser.add_argument("--site-name", help="Metabase site name. Defaults to terraform variable output value.")
    parser.add_argument("--wait-seconds", type=int, default=900, help="Seconds to wait for Metabase health.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    outputs = terraform_outputs()

    region = args.region or outputs["aws_region"]
    base_url = args.url or outputs["metabase_url"]
    admin_secret_id = args.admin_secret_id or outputs["metabase_admin_secret_arn"]
    site_name = args.site_name or "Citi Bike Lake"
    glue_database = outputs["glue_database_name"]
    workgroup = outputs["athena_workgroup_name"]
    staging_dir = outputs["metabase_athena_staging_dir"]
    gold_table = outputs["metabase_gold_table_name"]

    if not base_url or not admin_secret_id:
        raise RuntimeError("Metabase Terraform outputs are missing. Did terraform apply run with enable_metabase=true?")

    admin = get_secret(admin_secret_id, region, args.aws_profile)
    client = MetabaseClient(base_url)
    client.wait_until_ready(args.wait_seconds)
    client.setup_or_login(admin["email"], admin["password"], site_name)

    collection_id = client.ensure_collection(
        "Citi Bike Lake",
        "Dashboards and questions for the Citi Bike Athena Iceberg lake.",
    )
    database_id = client.ensure_database(
        {
            "name": "Citi Bike Athena",
            "engine": "athena",
            "details": {
                "region": region,
                "s3_staging_dir": staging_dir,
                "workgroup": workgroup,
                "catalog": "AwsDataCatalog",
                "dbname": glue_database,
                "access_key": "",
                "secret_key": "",
            },
            "is_full_sync": True,
            "is_on_demand": False,
            "auto_run_queries": False,
        }
    )

    gold_table_name = f"{glue_database}.{gold_table}"
    gold_card_ids = [client.ensure_card(card) for card in build_gold_cards(database_id, collection_id, gold_table_name)]
    gold_dashboard_id = client.ensure_dashboard(
        "Citi Bike Gold Ridership",
        "Athena dashboard over the dbt Gold daily ridership table.",
        collection_id,
    )
    client.set_dashboard_cards(
        gold_dashboard_id,
        [
            {"card_id": gold_card_ids[0], "row": 0, "col": 0, "size_x": 6, "size_y": 3},
            {"card_id": gold_card_ids[1], "row": 0, "col": 6, "size_x": 18, "size_y": 8},
            {"card_id": gold_card_ids[2], "row": 8, "col": 0, "size_x": 8, "size_y": 6},
            {"card_id": gold_card_ids[3], "row": 8, "col": 8, "size_x": 8, "size_y": 6},
            {"card_id": gold_card_ids[4], "row": 8, "col": 16, "size_x": 8, "size_y": 6},
        ],
    )

    silver_observability_table_name = f"{glue_database}.citibike_trips_silver_observability"
    silver_observability_card_ids = [
        client.ensure_card(card)
        for card in build_silver_observability_cards(database_id, collection_id, silver_observability_table_name)
    ]
    silver_observability_dashboard_id = client.ensure_dashboard(
        "Citi Bike Silver Observability",
        "Athena dashboard over the dbt Silver observability table.",
        collection_id,
    )
    client.set_dashboard_cards(
        silver_observability_dashboard_id,
        [
            {"card_id": silver_observability_card_ids[0], "row": 0, "col": 0, "size_x": 8, "size_y": 5},
            {"card_id": silver_observability_card_ids[1], "row": 0, "col": 8, "size_x": 16, "size_y": 7},
            {"card_id": silver_observability_card_ids[2], "row": 7, "col": 0, "size_x": 8, "size_y": 6},
            {"card_id": silver_observability_card_ids[3], "row": 7, "col": 8, "size_x": 8, "size_y": 6},
            {"card_id": silver_observability_card_ids[4], "row": 7, "col": 16, "size_x": 8, "size_y": 6},
        ],
    )

    print(f"Metabase URL: {base_url}")
    print(f"Gold dashboard: {base_url}/dashboard/{gold_dashboard_id}")
    print(f"Silver observability dashboard: {base_url}/dashboard/{silver_observability_dashboard_id}")
    print(f"Admin email: {admin['email']}")


if __name__ == "__main__":
    main()
