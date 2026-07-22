#!/usr/bin/env python3
"""Publish a weekly FOCUS CSV to Object Storage and create a Power BI PAR URL.

Oracle's reference architecture copies native OCI FOCUS reports from the
Oracle-owned ``bling`` bucket into a customer Object Storage bucket.  This job
runs after that daily copier: it waits for seven complete daily manifests,
combines the CSV partitions into a stable weekly object, and creates or reuses
a pre-authenticated request (PAR) URL that Power BI can read with Web.Contents.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import logging
import os
import tempfile
from datetime import date, datetime, timedelta, timezone
from typing import Any

import oci
from fdk import response

LOG = logging.getLogger(__name__)

CSV_OBJECT_NAME = "powerbi/oci_focus_previous_week.csv"
MANIFEST_OBJECT_NAME = "powerbi/oci_focus_manifest.json"
PAR_OBJECT_NAME = "powerbi/oci_focus_previous_week.par.json"
PAR_NAME = "powerbi-oci-focus-previous-week"
CHUNK_BYTES = 1024 * 1024
DEFAULT_PAR_TTL_DAYS = 90
MIN_PAR_VALID_DAYS = 14


def require(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"Missing environment variable: {name}")
    return value


def storage_client() -> tuple[Any, str]:
    signer = oci.auth.signers.get_resource_principals_signer()
    client = oci.object_storage.ObjectStorageClient(config={}, signer=signer)
    return client, os.environ.get("TARGET_NAMESPACE", "").strip() or client.get_namespace().data


def completed_week_start(today: date | None = None) -> date:
    """Return Monday for the previous completed UTC calendar week."""
    today = today or datetime.now(timezone.utc).date()
    return today - timedelta(days=today.weekday() + 7)


def manifest_object_name(usage_date: date) -> str:
    return f"manifests/{usage_date:%Y/%m/%d}.json"


def completed_day_objects(client: Any, namespace: str, bucket: str, usage_date: date) -> list[Any]:
    """Fail closed unless the copier completed this day's partition."""
    manifest_name = manifest_object_name(usage_date)
    try:
        manifest = json.loads(client.get_object(namespace, bucket, manifest_name).data.content.decode("utf-8"))
    except oci.exceptions.ServiceError as exc:
        if exc.status == 404:
            raise RuntimeError(f"FOCUS partition is not ready: missing {manifest_name}") from exc
        raise
    if manifest.get("status") != "complete" or manifest.get("usage_date") != usage_date.isoformat():
        raise RuntimeError(f"FOCUS partition is not complete: {manifest_name}")
    prefix = f"focus/csv/{usage_date:%Y/%m/%d}/"
    pages = oci.pagination.list_call_get_all_results(client.list_objects, namespace, bucket, prefix=prefix)
    objects = [obj for obj in pages.data.objects if obj.name.endswith(".csv")]
    if not objects:
        raise RuntimeError(f"FOCUS manifest is complete but has no CSV files: {manifest_name}")
    return sorted(objects, key=lambda obj: obj.name)


def stream_to_text(data: Any) -> io.TextIOBase:
    """Use OCI's raw response stream in production, with a small test fallback."""
    raw = getattr(data, "raw", None)
    if raw is not None:
        return io.TextIOWrapper(raw, encoding="utf-8-sig", newline="")
    return io.StringIO(data.content.decode("utf-8-sig"), newline="")


def combine_csvs(client: Any, namespace: str, bucket: str, objects: list[Any], output_path: str) -> int:
    """Write a combined CSV without holding source reports or output in memory."""
    source_columns = None
    rows = 0
    with open(output_path, "w", encoding="utf-8", newline="") as output:
        writer = None
        for obj in sorted(objects, key=lambda item: item.name):
            data = client.get_object(namespace, bucket, obj.name).data
            with stream_to_text(data) as source:
                reader = csv.DictReader(source)
                if not reader.fieldnames:
                    continue
                if source_columns is None:
                    source_columns = reader.fieldnames
                    writer = csv.DictWriter(output, fieldnames=[*source_columns, "_source_object"], lineterminator="\n")
                    writer.writeheader()
                elif reader.fieldnames != source_columns:
                    raise RuntimeError(f"Schema mismatch in {obj.name}")
                for row in reader:
                    row["_source_object"] = obj.name
                    writer.writerow(row)
                    rows += 1
    if not rows:
        raise RuntimeError("Refusing to publish an empty Power BI report")
    return rows


def upload_file(client: Any, namespace: str, bucket: str, object_name: str, path: str, content_type: str) -> None:
    """Use the SDK upload manager so large reports use multipart uploads."""
    manager = oci.object_storage.UploadManager(client)
    manager.upload_file(
        namespace_name=namespace,
        bucket_name=bucket,
        object_name=object_name,
        file_path=path,
        content_type=content_type,
    )


def put_json(client: Any, namespace: str, bucket: str, object_name: str, payload: dict[str, Any]) -> None:
    body = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
    client.put_object(namespace, bucket, object_name, body, content_type="application/json")


def parse_rfc3339(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def existing_par_metadata(client: Any, namespace: str, bucket: str) -> dict[str, Any] | None:
    try:
        data = client.get_object(namespace, bucket, PAR_OBJECT_NAME).data.content
    except oci.exceptions.ServiceError as exc:
        if exc.status == 404:
            return None
        raise
    metadata = json.loads(data.decode("utf-8"))
    if not metadata.get("url") or metadata.get("object_name") != CSV_OBJECT_NAME:
        return None
    expires_at = parse_rfc3339(metadata["expires_at"])
    if expires_at <= datetime.now(timezone.utc) + timedelta(days=MIN_PAR_VALID_DAYS):
        return None
    return metadata


def objectstorage_endpoint(client: Any) -> str:
    endpoint = os.environ.get("OBJECT_STORAGE_ENDPOINT", "").strip()
    if endpoint:
        return endpoint.rstrip("/")
    base_client = getattr(client, "base_client", None)
    endpoint = getattr(base_client, "endpoint", "") if base_client else ""
    if endpoint:
        return endpoint.rstrip("/")
    region = os.environ.get("OCI_REGION", "").strip()
    if not region:
        raise RuntimeError("Cannot determine Object Storage endpoint; set OCI_REGION or OBJECT_STORAGE_ENDPOINT")
    return f"https://objectstorage.{region}.oraclecloud.com"


def create_object_read_par(client: Any, namespace: str, bucket: str, ttl_days: int) -> dict[str, Any]:
    expires_at = datetime.now(timezone.utc) + timedelta(days=ttl_days)
    details = oci.object_storage.models.CreatePreauthenticatedRequestDetails(
        name=f"{PAR_NAME}-{expires_at:%Y%m%d}",
        access_type="ObjectRead",
        time_expires=expires_at,
        object_name=CSV_OBJECT_NAME,
    )
    par = client.create_preauthenticated_request(namespace, bucket, details).data
    access_uri = getattr(par, "access_uri", None)
    if not access_uri:
        raise RuntimeError("OCI did not return a PAR access_uri")
    return {
        "url": f"{objectstorage_endpoint(client)}{access_uri}",
        "access_uri": access_uri,
        "name": getattr(par, "name", details.name),
        "id": getattr(par, "id", ""),
        "object_name": CSV_OBJECT_NAME,
        "expires_at": expires_at.isoformat().replace("+00:00", "Z"),
        "created_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def get_or_create_par(client: Any, namespace: str, bucket: str, ttl_days: int, force: bool) -> dict[str, Any]:
    if not force:
        metadata = existing_par_metadata(client, namespace, bucket)
        if metadata:
            return metadata
    metadata = create_object_read_par(client, namespace, bucket, ttl_days)
    put_json(client, namespace, bucket, PAR_OBJECT_NAME, metadata)
    return metadata


def par_ttl_days() -> int:
    raw = os.environ.get("PAR_TTL_DAYS", str(DEFAULT_PAR_TTL_DAYS)).strip()
    try:
        ttl = int(raw)
    except ValueError as exc:
        raise SystemExit("PAR_TTL_DAYS must be an integer") from exc
    if ttl < MIN_PAR_VALID_DAYS:
        raise SystemExit(f"PAR_TTL_DAYS must be at least {MIN_PAR_VALID_DAYS}")
    return ttl


def run(week_start: date | None, rotate_par: bool) -> dict[str, Any]:
    """Combine one UTC week of daily FOCUS CSVs, publish it, and (re)issue its PAR."""
    week_start = week_start or completed_week_start()
    if week_start.weekday() != 0:
        raise SystemExit("week_start must be a Monday")

    usage_dates = [week_start + timedelta(days=offset) for offset in range(7)]
    client, namespace = storage_client()
    bucket = require("TARGET_BUCKET")
    objects = [obj for usage_date in usage_dates for obj in completed_day_objects(client, namespace, bucket, usage_date)]

    with tempfile.TemporaryDirectory(prefix="oci-focus-weekly-") as directory:
        csv_path = os.path.join(directory, "oci_focus_previous_week.csv")
        rows = combine_csvs(client, namespace, bucket, objects, csv_path)
        upload_file(client, namespace, bucket, CSV_OBJECT_NAME, csv_path, "text/csv")

    par = get_or_create_par(client, namespace, bucket, par_ttl_days(), rotate_par)
    manifest = {
        "week_start": week_start.isoformat(),
        "week_end": usage_dates[-1].isoformat(),
        "source_files": len(objects),
        "rows": rows,
        "csv_object": CSV_OBJECT_NAME,
        "par_metadata_object": PAR_OBJECT_NAME,
        "powerbi_url": par["url"],
        "par_expires_at": par["expires_at"],
        "published_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    put_json(client, namespace, bucket, MANIFEST_OBJECT_NAME, manifest)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--week-start", help="UTC Monday to publish, YYYY-MM-DD; default is the previous completed week")
    parser.add_argument("--rotate-par", action="store_true", help="Create a fresh PAR URL even if the stored one is still valid")
    args = parser.parse_args()
    week_start = datetime.strptime(args.week_start, "%Y-%m-%d").date() if args.week_start else None
    manifest = run(week_start, args.rotate_par)
    print(json.dumps(manifest, indent=2, sort_keys=True))


def parse_request(data: io.BytesIO | None) -> dict[str, Any]:
    """Mirrors function/func.py's request parsing so both Functions behave the same way."""
    if not data:
        return {}
    raw = data.getvalue().decode("utf-8").strip()
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON request body: {exc.msg}") from exc
    if not isinstance(parsed, dict):
        raise SystemExit("Request body must be a JSON object")
    return parsed


def handler(ctx: Any, data: io.BytesIO | None = None) -> Any:
    """OCI Function entry point: deploy this alongside func.py as a second function
    in the same app so it gets its own dynamic group and least-privilege PAR policy."""
    try:
        payload = parse_request(data)
        week_start = datetime.strptime(payload["week_start"], "%Y-%m-%d").date() if payload.get("week_start") else None
        rotate_par = bool(payload.get("rotate_par", False))
        manifest = run(week_start, rotate_par)
        return response.Response(ctx, response_data=json.dumps(manifest), headers={"Content-Type": "application/json"}, status_code=200)
    except Exception as exc:  # FDK must receive a non-2xx response on any failure.
        LOG.exception("FOCUS weekly delivery failed")
        return response.Response(ctx, response_data=json.dumps({"status": "failed", "error": str(exc)}), headers={"Content-Type": "application/json"}, status_code=500)


if __name__ == "__main__":
    main()
