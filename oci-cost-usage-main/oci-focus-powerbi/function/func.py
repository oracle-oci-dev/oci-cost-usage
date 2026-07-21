"""OCI Function that copies native OCI FOCUS reports into a customer bucket.

The function reads the Oracle-owned ``bling`` bucket with a resource principal,
keeps both the original gzip and a CSV copy, and writes a manifest per usage day.
It intentionally does not aggregate or discard correction rows: FOCUS is the
authoritative source consumed by the downstream Power BI model.
"""

from __future__ import annotations

import gzip
import io
import json
import logging
import os
import tempfile
from datetime import date, datetime, timedelta, timezone
from typing import Any, BinaryIO, Iterable

import oci
from fdk import response

LOG = logging.getLogger(__name__)
SOURCE_NAMESPACE = "bling"
SOURCE_PREFIX = "FOCUS Reports"
CHUNK_BYTES = 1024 * 1024
EXPECTED_COLUMNS = {"BilledCost", "BillingAccountId", "ChargePeriodStart"}


class FocusExportError(RuntimeError):
    """A failure that must fail the complete function invocation."""


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def config(name: str, default: str = "") -> str:
    value = os.environ.get(name, default).strip()
    if not value:
        raise FocusExportError(f"Missing required function configuration: {name}")
    return value


def parse_request(data: io.BytesIO | None) -> dict[str, Any]:
    if not data:
        return {}
    raw = data.getvalue().decode("utf-8").strip()
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise FocusExportError(f"Invalid JSON request body: {exc.msg}") from exc
    if not isinstance(parsed, dict):
        raise FocusExportError("Request body must be a JSON object")
    return parsed


def as_date(value: Any, field: str) -> date:
    if not isinstance(value, str):
        raise FocusExportError(f"{field} must be YYYY-MM-DD")
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise FocusExportError(f"{field} must be YYYY-MM-DD") from exc


def requested_dates(payload: dict[str, Any]) -> list[date]:
    """Return a bounded inclusive window; default is yesterday plus prior day."""
    today = utc_now().date()
    start = as_date(payload["start_date"], "start_date") if payload.get("start_date") else today - timedelta(days=2)
    end = as_date(payload["end_date"], "end_date") if payload.get("end_date") else today - timedelta(days=1)
    if end < start:
        raise FocusExportError("end_date must not be before start_date")
    if (end - start).days > 31:
        raise FocusExportError("The maximum processing window is 32 days")
    return [start + timedelta(days=offset) for offset in range((end - start).days + 1)]


def source_prefix(usage_date: date) -> str:
    return f"{SOURCE_PREFIX}/{usage_date:%Y/%m/%d}/"


def target_prefix(kind: str, usage_date: date) -> str:
    return f"focus/{kind}/{usage_date:%Y/%m/%d}"


def list_source_objects(client: Any, bucket: str, usage_date: date) -> list[Any]:
    result = oci.pagination.list_call_get_all_results(
        client.list_objects, SOURCE_NAMESPACE, bucket, prefix=source_prefix(usage_date)
    )
    objects = [obj for obj in result.data.objects if obj.name.endswith(".csv.gz")]
    return sorted(objects, key=lambda obj: obj.name)


def metadata_matches(client: Any, namespace: str, bucket: str, object_name: str, source: Any) -> bool:
    try:
        head = client.head_object(namespace, bucket, object_name)
    except oci.exceptions.ServiceError as exc:
        if exc.status == 404:
            return False
        raise
    metadata = {key.lower(): value for key, value in (head.headers or {}).items()}
    return (
        metadata.get("opc-meta-source-etag") == str(source.etag)
        and metadata.get("opc-meta-source-size") == str(source.size)
    )


def upload_file(client: Any, namespace: str, bucket: str, object_name: str, path: str, metadata: dict[str, str]) -> None:
    """Use the SDK upload manager so large reports use multipart uploads."""
    manager = oci.object_storage.UploadManager(client)
    manager.upload_file(
        namespace_name=namespace,
        bucket_name=bucket,
        object_name=object_name,
        file_path=path,
        opc_meta=metadata,
    )


def download_to_path(client: Any, source_bucket: str, source_name: str, destination: BinaryIO) -> None:
    source = client.get_object(SOURCE_NAMESPACE, source_bucket, source_name)
    for chunk in source.data.raw.stream(CHUNK_BYTES, decode_content=False):
        destination.write(chunk)


def decompress_and_validate(gzip_path: str, csv_path: str) -> tuple[int, list[str]]:
    """Decompress incrementally and validate the FOCUS header before upload."""
    total = 0
    with gzip.open(gzip_path, "rb") as compressed, open(csv_path, "wb") as output:
        header = compressed.readline()
        if not header:
            raise FocusExportError("FOCUS file is empty")
        try:
            columns = header.decode("utf-8-sig").rstrip("\r\n").split(",")
        except UnicodeDecodeError as exc:
            raise FocusExportError("FOCUS header is not UTF-8 CSV") from exc
        if not EXPECTED_COLUMNS.issubset(set(columns)):
            raise FocusExportError(
                "FOCUS file does not contain expected columns; found: " + ", ".join(columns[:20])
            )
        output.write(header)
        total += len(header)
        while True:
            chunk = compressed.read(CHUNK_BYTES)
            if not chunk:
                break
            output.write(chunk)
            total += len(chunk)
    return total, columns


def process_object(
    client: Any,
    namespace: str,
    source_bucket: str,
    target_bucket: str,
    usage_date: date,
    source: Any,
    force: bool,
) -> dict[str, Any]:
    filename = source.name.rsplit("/", 1)[-1]
    raw_name = f"{target_prefix('raw', usage_date)}/{filename}"
    csv_name = f"{target_prefix('csv', usage_date)}/{filename[:-3]}"
    if not force and metadata_matches(client, namespace, target_bucket, raw_name, source) and metadata_matches(client, namespace, target_bucket, csv_name, source):
        return {"source": source.name, "raw": raw_name, "csv": csv_name, "status": "skipped", "bytes": 0}

    metadata = {"source-etag": str(source.etag), "source-size": str(source.size), "source-name": source.name}
    with tempfile.TemporaryDirectory(prefix="focus-") as directory:
        gzip_path = os.path.join(directory, filename)
        csv_path = os.path.join(directory, filename[:-3])
        with open(gzip_path, "wb") as raw_file:
            download_to_path(client, source_bucket, source.name, raw_file)
        total_bytes, _ = decompress_and_validate(gzip_path, csv_path)
        upload_file(client, namespace, target_bucket, raw_name, gzip_path, metadata)
        upload_file(client, namespace, target_bucket, csv_name, csv_path, metadata)
    return {"source": source.name, "raw": raw_name, "csv": csv_name, "status": "processed", "bytes": total_bytes}


def write_manifest(client: Any, namespace: str, target_bucket: str, usage_date: date, files: list[dict[str, Any]]) -> str:
    statuses = [item["status"] for item in files]
    manifest = {
        "usage_date": usage_date.isoformat(),
        "source_files": len(files),
        "processed_files": statuses.count("processed"),
        "skipped_files": statuses.count("skipped"),
        "total_csv_bytes": sum(item["bytes"] for item in files),
        "status": "complete",
        "completed_utc": utc_now().isoformat().replace("+00:00", "Z"),
        "files": files,
    }
    object_name = f"manifests/{usage_date:%Y/%m/%d}.json"
    client.put_object(namespace, target_bucket, object_name, json.dumps(manifest, sort_keys=True).encode("utf-8"), content_type="application/json")
    return object_name


def handler(ctx: Any, data: io.BytesIO | None = None) -> Any:
    try:
        payload = parse_request(data)
        target_bucket = config("TARGET_BUCKET")
        target_namespace = os.environ.get("TARGET_NAMESPACE", "").strip()
        force = bool(payload.get("force", False))
        signer = oci.auth.signers.get_resource_principals_signer()
        client = oci.object_storage.ObjectStorageClient(config={}, signer=signer)
        namespace = target_namespace or client.get_namespace().data
        source_bucket = signer.tenancy_id
        dates = requested_dates(payload)
        manifests = []
        for usage_date in dates:
            sources = list_source_objects(client, source_bucket, usage_date)
            if not sources:
                raise FocusExportError(f"No FOCUS .csv.gz files found for {usage_date}")
            files = [process_object(client, namespace, source_bucket, target_bucket, usage_date, obj, force) for obj in sources]
            manifests.append(write_manifest(client, namespace, target_bucket, usage_date, files))
        result = {"status": "complete", "dates": [item.isoformat() for item in dates], "manifests": manifests}
        return response.Response(ctx, response_data=json.dumps(result), headers={"Content-Type": "application/json"}, status_code=200)
    except Exception as exc:  # FDK must receive a non-2xx response on any partial failure.
        LOG.exception("FOCUS export failed")
        return response.Response(ctx, response_data=json.dumps({"status": "failed", "error": str(exc)}), headers={"Content-Type": "application/json"}, status_code=500)
