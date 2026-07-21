#!/usr/bin/env bash
#
# oci_cost_usage_to_sharepoint.sh
#
# Read-only OCI cost/usage extraction plus CSV upload to SharePoint Online.
# Designed for OCI Cloud Shell.
#
# OCI operations:
#   - Usage API request-summarized-usages (read only)
#
# Microsoft operations:
#   - Microsoft Graph site/drive discovery (read only)
#   - Upload/overwrite CSV files in one SharePoint folder
#
# Required commands: oci, python3, curl
#
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_NAME="$(basename "$0")"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/oci-cost-usage-report}"
DAYS_BACK="${DAYS_BACK:-90}"
GRANULARITY="${GRANULARITY:-DAILY}"
OCI_QUERY_TYPE="${OCI_QUERY_TYPE:-COST}"
KEEP_ARCHIVE="${KEEP_ARCHIVE:-true}"
UPLOAD_TO_SHAREPOINT="${UPLOAD_TO_SHAREPOINT:-true}"
OCI_PROFILE="${OCI_PROFILE:-DEFAULT}"
OCI_AUTH="${OCI_AUTH:-security_token}"

# Stable filenames are intentionally overwritten so Power BI always sees the
# same source file. Timestamped copies can also be retained for audit history.
STABLE_CSV_NAME="${STABLE_CSV_NAME:-oci_cost_usage_latest.csv}"
STABLE_SUMMARY_NAME="${STABLE_SUMMARY_NAME:-oci_cost_summary_latest.csv}"

log()  { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [options]

Options:
  --days N                 Number of completed/partial UTC days to retrieve.
                           Default: $DAYS_BACK
  --start YYYY-MM-DD       Explicit UTC start date, inclusive.
  --end YYYY-MM-DD         Explicit UTC end date, exclusive.
  --output-dir PATH        Local output directory.
  --no-upload              Create CSV files but do not upload to SharePoint.
  --no-archive             Do not create timestamped archive CSV files.
  --oci-auth METHOD        OCI CLI auth method. Default: $OCI_AUTH
  --profile NAME           OCI CLI profile. Default: $OCI_PROFILE
  -h, --help               Show help.

Required SharePoint environment variables when upload is enabled:
  MS_TENANT_ID             Microsoft Entra tenant ID
  MS_CLIENT_ID             App registration client ID
  MS_CLIENT_SECRET         App registration client secret
  SP_HOSTNAME              Example: contoso.sharepoint.com
  SP_SITE_PATH             Example: /sites/FinOps
  SP_LIBRARY_NAME          Example: Documents
  SP_FOLDER_PATH           Example: PowerBI/OCI

Optional:
  OCI_TENANCY_OCID         If omitted, discovered from OCI config.
  OCI_CONFIG_FILE          Explicit OCI config file.
  DAYS_BACK                Default lookback if --start/--end are omitted.
  GRANULARITY              DAILY, MONTHLY, HOURLY, etc. Default: DAILY.
  OCI_QUERY_TYPE           COST, USAGE, USAGE_ONLY, etc. Default: COST.
EOF
}

START_DATE=""
END_DATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)       DAYS_BACK="${2:?Missing value for --days}"; shift 2 ;;
    --start)      START_DATE="${2:?Missing value for --start}"; shift 2 ;;
    --end)        END_DATE="${2:?Missing value for --end}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:?Missing value for --output-dir}"; shift 2 ;;
    --no-upload)  UPLOAD_TO_SHAREPOINT=false; shift ;;
    --no-archive) KEEP_ARCHIVE=false; shift ;;
    --oci-auth)   OCI_AUTH="${2:?Missing value for --oci-auth}"; shift 2 ;;
    --profile)    OCI_PROFILE="${2:?Missing value for --profile}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "Unknown argument: $1" ;;
  esac
done

need oci
need python3
need curl

[[ "$DAYS_BACK" =~ ^[0-9]+$ ]] || die "--days must be a positive integer."
(( DAYS_BACK > 0 )) || die "--days must be greater than zero."

mkdir -p "$OUTPUT_DIR"
RUN_TS="$(date -u +'%Y%m%dT%H%M%SZ')"

# Resolve the date window. OCI Usage API end time is exclusive.
if [[ -z "$START_DATE" ]]; then
  START_DATE="$(date -u -d "${DAYS_BACK} days ago" +'%Y-%m-%d')"
fi
if [[ -z "$END_DATE" ]]; then
  END_DATE="$(date -u -d 'tomorrow' +'%Y-%m-%d')"
fi

python3 - "$START_DATE" "$END_DATE" <<'PY'
import datetime as dt
import sys
try:
    start = dt.date.fromisoformat(sys.argv[1])
    end = dt.date.fromisoformat(sys.argv[2])
except ValueError as exc:
    raise SystemExit(f"Invalid ISO date: {exc}")
if start >= end:
    raise SystemExit("Start date must be earlier than end date.")
PY

START_TIME="${START_DATE}T00:00:00Z"
END_TIME="${END_DATE}T00:00:00Z"

# Cloud Shell normally uses ~/.oci/config, but this also supports environments
# where the OCI config was placed at /.oci/config.
detect_oci_config() {
  local candidate
  if [[ -n "${OCI_CONFIG_FILE:-}" ]]; then
    [[ -r "$OCI_CONFIG_FILE" ]] || die "OCI_CONFIG_FILE is not readable: $OCI_CONFIG_FILE"
    printf '%s\n' "$OCI_CONFIG_FILE"
    return
  fi

  for candidate in \
    "$HOME/.oci/config" \
    "/.oci/config" \
    "/home/$(id -un)/.oci/config"
  do
    if [[ -r "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  die "No readable OCI config found. Set OCI_CONFIG_FILE or OCI_TENANCY_OCID."
}

OCI_CONFIG_FILE_RESOLVED=""
if [[ -z "${OCI_TENANCY_OCID:-}" ]]; then
  OCI_CONFIG_FILE_RESOLVED="$(detect_oci_config)"
  OCI_TENANCY_OCID="$(
    python3 - "$OCI_CONFIG_FILE_RESOLVED" "$OCI_PROFILE" <<'PY'
import configparser
import sys
path, profile = sys.argv[1:3]
cfg = configparser.ConfigParser(interpolation=None)
with open(path, encoding="utf-8") as fh:
    cfg.read_file(fh)
if profile not in cfg:
    raise SystemExit(f"OCI profile [{profile}] was not found in {path}")
tenancy = cfg[profile].get("tenancy", "").strip()
if not tenancy:
    raise SystemExit(f"No tenancy value found in [{profile}] of {path}")
print(tenancy)
PY
  )"
fi

[[ "$OCI_TENANCY_OCID" == ocid1.tenancy.* ]] || die "Invalid or missing OCI tenancy OCID."

RAW_JSON="$OUTPUT_DIR/oci_cost_usage_raw_${RUN_TS}.json"
QUERY_JSON="$OUTPUT_DIR/oci_usage_query_${RUN_TS}.json"
LATEST_CSV="$OUTPUT_DIR/$STABLE_CSV_NAME"
SUMMARY_CSV="$OUTPUT_DIR/$STABLE_SUMMARY_NAME"
ARCHIVE_CSV="$OUTPUT_DIR/oci_cost_usage_${START_DATE}_to_${END_DATE}_${RUN_TS}.csv"
ARCHIVE_SUMMARY="$OUTPUT_DIR/oci_cost_summary_${START_DATE}_to_${END_DATE}_${RUN_TS}.csv"

cat > "$QUERY_JSON" <<EOF
{
  "tenantId": "$OCI_TENANCY_OCID",
  "timeUsageStarted": "$START_TIME",
  "timeUsageEnded": "$END_TIME",
  "granularity": "$GRANULARITY",
  "queryType": "$OCI_QUERY_TYPE",
  "isAggregateByTime": false,
  "groupBy": [
    "service",
    "compartmentName",
    "resourceName",
    "skuName",
    "unit",
    "currency"
  ]
}
EOF

OCI_ARGS=(usage-api usage-summary request-summarized-usages
  --tenant-id "$OCI_TENANCY_OCID"
  --time-usage-started "$START_TIME"
  --time-usage-ended "$END_TIME"
  --granularity "$GRANULARITY"
  --query-type "$OCI_QUERY_TYPE"
  --query file://"$QUERY_JSON"
  --all
  --output json
  --profile "$OCI_PROFILE"
)

if [[ -n "$OCI_CONFIG_FILE_RESOLVED" ]]; then
  OCI_ARGS+=(--config-file "$OCI_CONFIG_FILE_RESOLVED")
fi
if [[ -n "$OCI_AUTH" ]]; then
  OCI_ARGS+=(--auth "$OCI_AUTH")
fi

log "Extracting OCI $OCI_QUERY_TYPE data from $START_TIME through $END_TIME..."
if ! oci "${OCI_ARGS[@]}" > "$RAW_JSON"; then
  die "OCI Usage API extraction failed. Verify IAM permissions, OCI auth, profile, and date range."
fi

[[ -s "$RAW_JSON" ]] || die "OCI returned an empty response file."

# Convert OCI's JSON response to a stable Power BI-friendly schema.
python3 - "$RAW_JSON" "$LATEST_CSV" "$SUMMARY_CSV" "$RUN_TS" <<'PY'
import csv
import datetime as dt
import json
import sys
from collections import defaultdict
from decimal import Decimal, InvalidOperation

raw_path, detail_path, summary_path, run_ts = sys.argv[1:5]

with open(raw_path, encoding="utf-8") as fh:
    payload = json.load(fh)

data = payload.get("data", payload)
if isinstance(data, dict):
    items = data.get("items", [])
elif isinstance(data, list):
    items = data
else:
    items = []

def first(row, *names, default=""):
    for name in names:
        if name in row and row[name] is not None:
            value = row[name]
            if isinstance(value, (dict, list)):
                return json.dumps(value, separators=(",", ":"), ensure_ascii=False)
            return value
    return default

def dec(value):
    try:
        if value in ("", None):
            return Decimal("0")
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return Decimal("0")

fields = [
    "extract_utc",
    "usage_start_utc",
    "usage_end_utc",
    "service",
    "compartment_name",
    "compartment_id",
    "resource_name",
    "resource_id",
    "sku_name",
    "sku_part_number",
    "unit",
    "currency",
    "computed_quantity",
    "computed_amount",
    "attributed_cost",
    "subscription_id",
    "overage_flag",
    "is_correction",
    "tags_json",
]

extract_utc = dt.datetime.strptime(run_ts, "%Y%m%dT%H%M%SZ").replace(
    tzinfo=dt.timezone.utc
).isoformat().replace("+00:00", "Z")

normalized = []
for row in items:
    normalized.append({
        "extract_utc": extract_utc,
        "usage_start_utc": first(row, "time-usage-started", "timeUsageStarted"),
        "usage_end_utc": first(row, "time-usage-ended", "timeUsageEnded"),
        "service": first(row, "service"),
        "compartment_name": first(row, "compartment-name", "compartmentName"),
        "compartment_id": first(row, "compartment-id", "compartmentId"),
        "resource_name": first(row, "resource-name", "resourceName"),
        "resource_id": first(row, "resource-id", "resourceId"),
        "sku_name": first(row, "sku-name", "skuName"),
        "sku_part_number": first(row, "sku-part-number", "skuPartNumber"),
        "unit": first(row, "unit"),
        "currency": first(row, "currency"),
        "computed_quantity": first(row, "computed-quantity", "computedQuantity", default=0),
        "computed_amount": first(row, "computed-amount", "computedAmount", default=0),
        "attributed_cost": first(row, "attributed-cost", "attributedCost", default=0),
        "subscription_id": first(row, "subscription-id", "subscriptionId"),
        "overage_flag": first(row, "overage-flag", "overageFlag"),
        "is_correction": first(row, "is-correction", "isCorrection"),
        "tags_json": first(row, "tags"),
    })

normalized.sort(key=lambda r: (
    str(r["usage_start_utc"]),
    str(r["service"]),
    str(r["compartment_name"]),
    str(r["resource_name"]),
    str(r["sku_name"]),
))

with open(detail_path, "w", newline="", encoding="utf-8-sig") as fh:
    writer = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(normalized)

summary = defaultdict(lambda: {
    "computed_quantity": Decimal("0"),
    "computed_amount": Decimal("0"),
    "attributed_cost": Decimal("0"),
    "row_count": 0,
})

for row in normalized:
    key = (
        row["usage_start_utc"],
        row["service"],
        row["compartment_name"],
        row["currency"],
        row["unit"],
    )
    bucket = summary[key]
    bucket["computed_quantity"] += dec(row["computed_quantity"])
    bucket["computed_amount"] += dec(row["computed_amount"])
    bucket["attributed_cost"] += dec(row["attributed_cost"])
    bucket["row_count"] += 1

summary_fields = [
    "extract_utc",
    "usage_start_utc",
    "service",
    "compartment_name",
    "currency",
    "unit",
    "computed_quantity",
    "computed_amount",
    "attributed_cost",
    "row_count",
]

with open(summary_path, "w", newline="", encoding="utf-8-sig") as fh:
    writer = csv.DictWriter(fh, fieldnames=summary_fields)
    writer.writeheader()
    for key in sorted(summary):
        usage_start, service, compartment, currency, unit = key
        values = summary[key]
        writer.writerow({
            "extract_utc": extract_utc,
            "usage_start_utc": usage_start,
            "service": service,
            "compartment_name": compartment,
            "currency": currency,
            "unit": unit,
            "computed_quantity": str(values["computed_quantity"]),
            "computed_amount": str(values["computed_amount"]),
            "attributed_cost": str(values["attributed_cost"]),
            "row_count": values["row_count"],
        })

print(f"detail_rows={len(normalized)}")
print(f"summary_rows={len(summary)}")
PY

if [[ "$KEEP_ARCHIVE" == "true" ]]; then
  cp -f "$LATEST_CSV" "$ARCHIVE_CSV"
  cp -f "$SUMMARY_CSV" "$ARCHIVE_SUMMARY"
fi

upload_file_graph() {
  local local_file="$1"
  local remote_name="$2"
  local encoded_folder encoded_name upload_url http_code response_file

  encoded_folder="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1].strip("/"), safe="/"))' "$SP_FOLDER_PATH")"
  encoded_name="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$remote_name")"

  if [[ -n "$encoded_folder" ]]; then
    upload_url="https://graph.microsoft.com/v1.0/drives/${DRIVE_ID}/root:/${encoded_folder}/${encoded_name}:/content"
  else
    upload_url="https://graph.microsoft.com/v1.0/drives/${DRIVE_ID}/root:/${encoded_name}:/content"
  fi

  response_file="$(mktemp)"
  http_code="$(
    curl --silent --show-error \
      --output "$response_file" \
      --write-out '%{http_code}' \
      --request PUT \
      --header "Authorization: Bearer $GRAPH_TOKEN" \
      --header "Content-Type: text/csv" \
      --data-binary "@$local_file" \
      "$upload_url"
  )"

  if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
    cat "$response_file" >&2 || true
    rm -f "$response_file"
    die "SharePoint upload failed for $remote_name (HTTP $http_code)."
  fi

  python3 - "$response_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    item = json.load(fh)
print("Uploaded:", item.get("name", "unknown"))
print("SharePoint URL:", item.get("webUrl", "not returned"))
PY
  rm -f "$response_file"
}

if [[ "$UPLOAD_TO_SHAREPOINT" == "true" ]]; then
  : "${MS_TENANT_ID:?Set MS_TENANT_ID}"
  : "${MS_CLIENT_ID:?Set MS_CLIENT_ID}"
  : "${MS_CLIENT_SECRET:?Set MS_CLIENT_SECRET}"
  : "${SP_HOSTNAME:?Set SP_HOSTNAME, for example contoso.sharepoint.com}"
  : "${SP_SITE_PATH:?Set SP_SITE_PATH, for example /sites/FinOps}"
  : "${SP_LIBRARY_NAME:?Set SP_LIBRARY_NAME, for example Documents}"
  : "${SP_FOLDER_PATH:?Set SP_FOLDER_PATH, for example PowerBI/OCI}"

  log "Requesting Microsoft Graph app-only access token..."
  TOKEN_RESPONSE="$(
    curl --silent --show-error --fail \
      --request POST \
      --header 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "client_id=$MS_CLIENT_ID" \
      --data-urlencode "client_secret=$MS_CLIENT_SECRET" \
      --data-urlencode 'scope=https://graph.microsoft.com/.default' \
      --data-urlencode 'grant_type=client_credentials' \
      "https://login.microsoftonline.com/${MS_TENANT_ID}/oauth2/v2.0/token"
  )"

  GRAPH_TOKEN="$(
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))' <<<"$TOKEN_RESPONSE"
  )"
  [[ -n "$GRAPH_TOKEN" ]] || die "Microsoft Graph did not return an access token."
  unset TOKEN_RESPONSE MS_CLIENT_SECRET

  ENCODED_SITE_PATH="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1].strip("/"), safe="/"))' "$SP_SITE_PATH")"
  SITE_RESPONSE="$(
    curl --silent --show-error --fail \
      --header "Authorization: Bearer $GRAPH_TOKEN" \
      "https://graph.microsoft.com/v1.0/sites/${SP_HOSTNAME}:/${ENCODED_SITE_PATH}"
  )"
  SITE_ID="$(
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$SITE_RESPONSE"
  )"
  [[ -n "$SITE_ID" ]] || die "Could not resolve SharePoint site."

  DRIVES_RESPONSE="$(
    curl --silent --show-error --fail \
      --header "Authorization: Bearer $GRAPH_TOKEN" \
      "https://graph.microsoft.com/v1.0/sites/${SITE_ID}/drives"
  )"
  DRIVE_ID="$(
    python3 - "$SP_LIBRARY_NAME" <<'PY' <<<"$DRIVES_RESPONSE"
import json, sys
library = sys.argv[1].casefold()
payload = json.load(sys.stdin)
for drive in payload.get("value", []):
    if str(drive.get("name", "")).casefold() == library:
        print(drive.get("id", ""))
        break
PY
  )"
  [[ -n "$DRIVE_ID" ]] || die "SharePoint document library not found: $SP_LIBRARY_NAME"

  log "Uploading stable CSV files to SharePoint..."
  upload_file_graph "$LATEST_CSV" "$STABLE_CSV_NAME"
  upload_file_graph "$SUMMARY_CSV" "$STABLE_SUMMARY_NAME"

  if [[ "$KEEP_ARCHIVE" == "true" ]]; then
    upload_file_graph "$ARCHIVE_CSV" "$(basename "$ARCHIVE_CSV")"
    upload_file_graph "$ARCHIVE_SUMMARY" "$(basename "$ARCHIVE_SUMMARY")"
  fi
fi

DETAIL_ROWS="$(python3 -c 'import csv,sys; print(max(sum(1 for _ in csv.reader(open(sys.argv[1], encoding="utf-8-sig")))-1,0))' "$LATEST_CSV")"
SUMMARY_ROWS="$(python3 -c 'import csv,sys; print(max(sum(1 for _ in csv.reader(open(sys.argv[1], encoding="utf-8-sig")))-1,0))' "$SUMMARY_CSV")"

log "Completed successfully."
printf '\nOutput:\n'
printf '  Detail CSV:  %s (%s rows)\n' "$LATEST_CSV" "$DETAIL_ROWS"
printf '  Summary CSV: %s (%s rows)\n' "$SUMMARY_CSV" "$SUMMARY_ROWS"
printf '  Date window: %s through %s (end exclusive)\n' "$START_TIME" "$END_TIME"
