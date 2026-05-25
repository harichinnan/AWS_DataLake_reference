import datetime as dt
import json
import logging
import os
import re
import tempfile
import urllib.error
import urllib.request
import zipfile

import boto3

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

S3 = boto3.client("s3")

MONTH_RE = re.compile(r"^[0-9]{6}$")
MONTH_IN_NAME_RE = re.compile(r"(20[0-9]{4})")


def handler(event, _context):
    event = event or {}
    bucket = require_env("RAW_BUCKET")
    raw_prefix = os.environ.get("RAW_PREFIX", "raw/citibike").strip("/")
    base_url = os.environ.get("CITIBIKE_BASE_URL", "https://s3.amazonaws.com/tripdata").rstrip("/")
    include_jc = bool_from_value(event.get("include_jc", os.environ.get("DEFAULT_INCLUDE_JC", "false")))

    sources = build_sources(event, base_url, include_jc)
    if not sources:
        raise ValueError("No Citi Bike sources resolved. Provide event.months, event.urls, or DEFAULT_MONTHS.")

    results = []
    for source in sources:
        LOG.info("Processing %s", ", ".join(source["urls"]))
        with tempfile.TemporaryDirectory() as tmpdir:
            zip_path = os.path.join(tmpdir, source["zip_name"])
            resolved_url = download_first(source["urls"], zip_path)
            source["url"] = resolved_url
            source["zip_name"] = safe_name(resolved_url.rstrip("/").split("/")[-1])
            uploaded = extract_and_upload(zip_path, bucket, raw_prefix, source)
            results.append({**source, "uploaded": uploaded})

    return {
        "bucket": bucket,
        "raw_prefix": raw_prefix,
        "sources": results,
    }


def build_sources(event, base_url, include_jc):
    urls = event.get("urls")
    if urls:
        if isinstance(urls, str):
            urls = [urls]
        return [source_from_url(url) for url in urls]

    months = event.get("months")
    if months is None:
        months = json.loads(os.environ.get("DEFAULT_MONTHS", "[]"))

    if months == "previous":
        months = [previous_month()]
    elif isinstance(months, str):
        months = [part.strip() for part in months.split(",") if part.strip()]

    sources = []
    for month in months:
        validate_month(month)
        sources.append({
            "urls": [
                f"{base_url}/{month}-citibike-tripdata.zip",
                f"{base_url}/{month}-citibike-tripdata.csv.zip",
            ],
            "month": month,
            "source": "nyc",
            "zip_name": f"{month}-citibike-tripdata.zip",
        })
        if include_jc:
            sources.append({
                "urls": [
                    f"{base_url}/JC-{month}-citibike-tripdata.zip",
                    f"{base_url}/JC-{month}-citibike-tripdata.csv.zip",
                ],
                "month": month,
                "source": "jc",
                "zip_name": f"JC-{month}-citibike-tripdata.zip",
            })
    return sources


def source_from_url(url):
    zip_name = url.rstrip("/").split("/")[-1]
    match = MONTH_IN_NAME_RE.search(zip_name)
    if not match:
        raise ValueError(f"Could not infer YYYYMM month from URL: {url}")
    month = match.group(1)
    source = "jc" if zip_name.startswith("JC-") else "nyc"
    return {
        "url": url,
        "urls": [url],
        "month": month,
        "source": source,
        "zip_name": safe_name(zip_name),
    }


def previous_month():
    first_of_month = dt.date.today().replace(day=1)
    last_month = first_of_month - dt.timedelta(days=1)
    return last_month.strftime("%Y%m")


def validate_month(month):
    if not isinstance(month, str) or not MONTH_RE.match(month):
        raise ValueError(f"Invalid month {month!r}; expected YYYYMM.")
    month_number = int(month[4:6])
    if month_number < 1 or month_number > 12:
        raise ValueError(f"Invalid month {month!r}; MM must be 01-12.")


def download(url, target_path):
    request = urllib.request.Request(url, headers={"User-Agent": "citibike-athena-ingest/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            with open(target_path, "wb") as file_out:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    file_out.write(chunk)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Failed to download {url}: HTTP {exc.code}") from exc


def download_first(urls, target_path):
    errors = []
    for url in urls:
        try:
            download(url, target_path)
            return url
        except RuntimeError as exc:
            errors.append(str(exc))
    raise RuntimeError("Failed to download any candidate URL: " + "; ".join(errors))


def extract_and_upload(zip_path, bucket, raw_prefix, source):
    month = source["month"]
    year = month[:4]
    month_number = month[4:6]
    uploaded = []

    with zipfile.ZipFile(zip_path) as archive:
        members = [
            member for member in archive.infolist()
            if not member.is_dir() and member.filename.lower().endswith(".csv")
        ]
        if not members:
            raise RuntimeError(f"No CSV files found inside {source['zip_name']}")

        for member in members:
            csv_name = safe_name(os.path.basename(member.filename))
            key = f"{raw_prefix}/trips/year={year}/month={month_number}/{source['source']}_{csv_name}"
            LOG.info("Uploading s3://%s/%s", bucket, key)
            with archive.open(member) as csv_file:
                S3.upload_fileobj(
                    csv_file,
                    bucket,
                    key,
                    ExtraArgs={
                        "ContentType": "text/csv",
                        "Metadata": {
                            "citibike_month": month,
                            "citibike_source": source["source"],
                            "source_zip": source["zip_name"],
                        },
                    },
                )
            uploaded.append({"key": key, "uncompressed_bytes": member.file_size})

    return uploaded


def safe_name(name):
    return re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._") or "citibike.csv"


def bool_from_value(value):
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "y"}


def require_env(name):
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable {name}")
    return value
