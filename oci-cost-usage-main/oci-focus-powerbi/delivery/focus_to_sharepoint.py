#!/usr/bin/env python3
"""Publish selected FOCUS CSV partitions from OCI Object Storage to SharePoint.

Run this as a separate scheduled workload after the copier has written its
manifests. It uploads a stable current-month file and a manifest that Power BI's
SharePoint Folder connector can refresh. It never rewrites a stable CSV with an
empty source set.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
from datetime import date, datetime, timezone
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
        "scope": os.environ.get("GRAPH_SCOPE", "https://graph.microsoft.com/.default"),
        "grant_type": "client_credentials",
    }
    response = requests.post(f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token", data=body, timeout=30)
    response.raise_for_status()
    return response.json()["access_token"]


def graph_request(method: str, url: str, token: str, **kwargs):
    headers = {"Authorization": f"Bearer {token}"}
    headers.update(kwargs.pop("headers", {}))
    response = requests.request(method, url, headers=headers, timeout=120, **kwargs)
    response.raise_for_status()
    return response


def storage_client() -> tuple[object, str]:
    signer = oci.auth.signers.get_resource_principals_signer()
    client = oci.object_storage.ObjectStorageClient(config={}, signer=signer)
    return client, os.environ.get("TARGET_NAMESPACE", "").strip() or client.get_namespace().data


def list_month_csvs(client, namespace: str, bucket: str, month: date):
    prefix = f"focus/csv/{month:%Y/%m}/"
    pages = oci.pagination.list_call_get_all_results(client.list_objects, namespace, bucket, prefix=prefix)
    return [obj for obj in pages.data.objects if obj.name.endswith(".csv")]


def combine_csvs(client, namespace: str, bucket: str, objects) -> bytes:
    output = io.StringIO(newline="")
    writer = None
    columns = None
    rows = 0
    for obj in sorted(objects, key=lambda item: item.name):
        body = client.get_object(namespace, bucket, obj.name).data.content.decode("utf-8-sig")
        reader = csv.DictReader(io.StringIO(body))
        if not reader.fieldnames:
            continue
        if columns is None:
            columns = [*reader.fieldnames, "_source_object"]
            writer = csv.DictWriter(output, fieldnames=columns, lineterminator="\n")
            writer.writeheader()
        elif reader.fieldnames != columns:
            raise RuntimeError(f"Schema mismatch in {obj.name}")
        for row in reader:
            # Preserve correction rows and provenance for Power BI deduplication.
            row["_source_object"] = obj.name
            writer.writerow(row)
            rows += 1
    if not rows:
        raise RuntimeError("Refusing to replace the stable SharePoint file with an empty report")
    return output.getvalue().encode("utf-8")


def upload_small_file(token: str, drive_id: str, path: str, content: bytes) -> None:
    if len(content) > 250 * 1024 * 1024:
        raise RuntimeError("File exceeds simple SharePoint upload limit; use Graph upload sessions")
    encoded_path = quote(path, safe="/")
    graph_request("PUT", f"https://graph.microsoft.com/v1.0/drives/{drive_id}/root:/{encoded_path}:/content", token, data=content, headers={"Content-Type": "text/csv"})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--month", default=date.today().strftime("%Y-%m"), help="Usage month YYYY-MM")
    args = parser.parse_args()
    month = datetime.strptime(args.month, "%Y-%m").date()
    client, namespace = storage_client()
    bucket = require("TARGET_BUCKET")
    objects = list_month_csvs(client, namespace, bucket, month)
    content = combine_csvs(client, namespace, bucket, objects)
    token = graph_token()
    site = graph_request("GET", f"https://graph.microsoft.com/v1.0/sites/{require('SP_HOSTNAME')}:{require('SP_SITE_PATH')}", token).json()
    drive_name = require("SP_LIBRARY_NAME")
    drives = graph_request("GET", f"https://graph.microsoft.com/v1.0/sites/{site['id']}/drives", token).json()["value"]
    drive = next((item for item in drives if item["name"] == drive_name), None)
    if not drive:
        raise RuntimeError(f"SharePoint library not found: {drive_name}")
    folder = os.environ.get("SP_FOLDER_PATH", "PowerBI/OCI").strip("/")
    upload_small_file(token, drive["id"], f"{folder}/oci_focus_current_month.csv", content)
    manifest = json.dumps({"usage_month": args.month, "source_files": len(objects), "published_utc": datetime.now(timezone.utc).isoformat()}, indent=2).encode()
    upload_small_file(token, drive["id"], f"{folder}/oci_focus_manifest.json", manifest)


if __name__ == "__main__":
    main()
