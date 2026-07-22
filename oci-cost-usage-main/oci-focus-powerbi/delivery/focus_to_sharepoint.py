#!/usr/bin/env python3
"""Publish a complete weekly FOCUS report from OCI Object Storage to SharePoint.

The job publishes the previous completed UTC calendar week only after all seven
daily copier manifests are present and marked complete.  It streams the combined
CSV to a temporary file and uses a Microsoft Graph upload session, avoiding a
large in-memory payload or the 250 MB simple-upload limit.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
import tempfile
import time
from datetime import date, datetime, timedelta, timezone
from urllib.parse import quote

import oci
import requests


def require(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"Missing environment variable: {name}")
    return value


def graph_token() -> str:
    tenant = require("MS_TENANT_ID")
    body = {
        "client_id": require("MS_CLIENT_ID"),
        "client_secret": require("MS_CLIENT_SECRET"),
        "scope": graph_scope(),
        "grant_type": "client_credentials",
    }
    response = requests.post(f"{login_base_url()}/{tenant}/oauth2/v2.0/token", data=body, timeout=30)
    response.raise_for_status()
    return response.json()["access_token"]


def graph_request(method: str, url: str, token: str, **kwargs):
    headers = {"Authorization": f"Bearer {token}"}
    headers.update(kwargs.pop("headers", {}))
    return request_with_retry(lambda: requests.request(method, url, headers=headers, timeout=120, **kwargs))


def request_with_retry(send, attempts: int = 5):
    """Retry Microsoft Graph throttling and transient service failures."""
    for attempt in range(attempts):
        try:
            response = send()
        except requests.RequestException:
            if attempt == attempts - 1:
                raise
            time.sleep(2**attempt)
            continue
        if response.status_code not in {429, 500, 502, 503, 504}:
            response.raise_for_status()
            return response
        if attempt == attempts - 1:
            response.raise_for_status()
        retry_after = response.headers.get("Retry-After")
        time.sleep(int(retry_after) if retry_after and retry_after.isdigit() else 2**attempt)
    raise RuntimeError("unreachable")


def storage_client() -> tuple[object, str]:
    signer = oci.auth.signers.get_resource_principals_signer()
    client = oci.object_storage.ObjectStorageClient(config={}, signer=signer)
    return client, os.environ.get("TARGET_NAMESPACE", "").strip() or client.get_namespace().data


def completed_week_start(today: date | None = None) -> date:
    """Return Monday for the previous completed UTC calendar week."""
    today = today or datetime.now(timezone.utc).date()
    return today - timedelta(days=today.weekday() + 7)


def manifest_object_name(usage_date: date) -> str:
    return f"manifests/{usage_date:%Y/%m/%d}.json"


def completed_day_objects(client, namespace: str, bucket: str, usage_date: date):
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
    return objects


def stream_to_text(data):
    """Use OCI's raw response stream in production, with a small test fallback."""
    raw = getattr(data, "raw", None)
    if raw is not None:
        return io.TextIOWrapper(raw, encoding="utf-8-sig", newline="")
    return io.StringIO(data.content.decode("utf-8-sig"), newline="")


def combine_csvs(client, namespace: str, bucket: str, objects, output_path: str) -> int:
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
        raise RuntimeError("Refusing to replace the stable SharePoint file with an empty report")
    return rows


def upload_file(token: str, drive_id: str, path: str, local_path: str, content_type: str) -> None:
    """Upload in Graph session chunks, supporting reports above 250 MB."""
    encoded_path = quote(path, safe="/")
    session = graph_request(
        "POST",
        f"{graph_base_url()}/v1.0/drives/{drive_id}/root:/{encoded_path}:/createUploadSession",
        token,
        json={"item": {"@microsoft.graph.conflictBehavior": "replace", "name": path.rsplit("/", 1)[-1]}},
    ).json()
    upload_url = session["uploadUrl"]
    total = os.path.getsize(local_path)
    chunk_size = 10 * 1024 * 1024  # 32 × 320 KiB, as required by Graph.
    with open(local_path, "rb") as source:
        offset = 0
        while chunk := source.read(chunk_size):
            end = offset + len(chunk) - 1
            request_with_retry(
                lambda: requests.put(
                    upload_url,
                    data=chunk,
                    headers={"Content-Length": str(len(chunk)), "Content-Range": f"bytes {offset}-{end}/{total}", "Content-Type": content_type},
                    timeout=120,
                )
            )
            offset = end + 1


def graph_base_url() -> str:
    return f"https://{os.environ.get('GRAPH_HOST', 'graph.microsoft.com').strip()}"


def login_base_url() -> str:
    return f"https://{os.environ.get('LOGIN_HOST', 'login.microsoftonline.com').strip()}"


def graph_scope() -> str:
    return os.environ.get("GRAPH_SCOPE", f"https://{os.environ.get('GRAPH_HOST', 'graph.microsoft.com').strip()}/.default")


def find_drive(token: str, site_id: str, drive_name: str) -> dict:
    """Find a document library even when Graph returns multiple pages."""
    url = f"{graph_base_url()}/v1.0/sites/{site_id}/drives"
    for _ in range(20):
        payload = graph_request("GET", url, token).json()
        drive = next((item for item in payload.get("value", []) if item.get("name", "").casefold() == drive_name.casefold()), None)
        if drive:
            return drive
        url = payload.get("@odata.nextLink")
        if not url:
            break
    raise RuntimeError(f"SharePoint library not found: {drive_name}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--week-start", help="UTC Monday to publish, YYYY-MM-DD; default is the previous completed week")
    args = parser.parse_args()
    week_start = datetime.strptime(args.week_start, "%Y-%m-%d").date() if args.week_start else completed_week_start()
    if week_start.weekday() != 0:
        raise SystemExit("--week-start must be a Monday")
    usage_dates = [week_start + timedelta(days=offset) for offset in range(7)]
    client, namespace = storage_client()
    bucket = require("TARGET_BUCKET")
    objects = [obj for usage_date in usage_dates for obj in completed_day_objects(client, namespace, bucket, usage_date)]
    token = graph_token()
    site = graph_request("GET", f"{graph_base_url()}/v1.0/sites/{require('SP_HOSTNAME')}:{require('SP_SITE_PATH')}", token).json()
    drive_name = require("SP_LIBRARY_NAME")
    drive = find_drive(token, site["id"], drive_name)
    folder = os.environ.get("SP_FOLDER_PATH", "PowerBI/OCI").strip("/")
    prefix = f"{folder}/" if folder else ""
    with tempfile.TemporaryDirectory(prefix="oci-focus-weekly-") as directory:
        csv_path = os.path.join(directory, "oci_focus_previous_week.csv")
        rows = combine_csvs(client, namespace, bucket, objects, csv_path)
        manifest_path = os.path.join(directory, "oci_focus_manifest.json")
        with open(manifest_path, "w", encoding="utf-8") as manifest_file:
            json.dump({"week_start": week_start.isoformat(), "week_end": usage_dates[-1].isoformat(), "source_files": len(objects), "rows": rows, "published_utc": datetime.now(timezone.utc).isoformat()}, manifest_file, indent=2)
        upload_file(token, drive["id"], f"{prefix}oci_focus_previous_week.csv", csv_path, "text/csv")
        upload_file(token, drive["id"], f"{prefix}oci_focus_manifest.json", manifest_path, "application/json")


if __name__ == "__main__":
    main()
