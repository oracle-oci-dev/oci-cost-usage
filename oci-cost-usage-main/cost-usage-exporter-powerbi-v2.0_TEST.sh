#!/usr/bin/env bash
#
# oci_cost_usage_to_sharepoint_v2.sh
#
# Read-only OCI cost/usage extraction + upload of Power BI CSVs to SharePoint.
# Designed for OCI Cloud Shell.
#
# v2 architecture:
#   - OCI extraction is delegated to oci_usage_extract.py, which is modeled on
#     Oracle's official example:
#       https://github.com/oracle/oci-python-sdk/tree/master/examples/showusage
#     It uses the OCI Python SDK (create_signer / RequestSummarizedUsagesDetails /
#     DEFAULT_RETRY_STRATEGY) and reads results as SDK model objects.
#   - This wrapper resolves auth mode, runs the extractor, then uploads the two
#     stable CSVs to a SharePoint folder via Microsoft Graph.
#
# Required commands: python3, curl
# Required Python package: OCI Python SDK (import oci) -- ships with the CLI in
# Cloud Shell.
#
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCRIPT_NAME="$(basename "$0")"
# The Python extractor is embedded at the end of this file and written to a
# temp file at runtime, so this is a single self-contained script.
EXTRACTOR=""

OUTPUT_DIR="${OUTPUT_DIR:-$HOME/oci-cost-usage-report}"
DAYS_BACK="${DAYS_BACK:-90}"
GRANULARITY="${GRANULARITY:-DAILY}"
OCI_QUERY_TYPE="${OCI_QUERY_TYPE:-COST}"
GROUP_BY="${GROUP_BY:-}"                    # empty -> extractor default (4 dims)
UPLOAD_TO_SHAREPOINT="${UPLOAD_TO_SHAREPOINT:-true}"
UPLOAD_EMPTY_REPORT="${UPLOAD_EMPTY_REPORT:-false}"
KEEP_LOCAL_ARCHIVE="${KEEP_LOCAL_ARCHIVE:-true}"
UPLOAD_ARCHIVE_TO_SHAREPOINT="${UPLOAD_ARCHIVE_TO_SHAREPOINT:-false}"

STABLE_CSV_NAME="${STABLE_CSV_NAME:-oci_cost_usage_latest.csv}"
STABLE_SUMMARY_NAME="${STABLE_SUMMARY_NAME:-oci_cost_summary_latest.csv}"

# OCI auth mode. In Cloud Shell OCI_CLI_AUTH=instance_obo_user (delegation
# token). Accepted: delegation_token (Cloud Shell), instance_principal, config.
OCI_AUTH="${OCI_AUTH:-${OCI_CLI_AUTH:-}}"
OCI_PROFILE="${OCI_PROFILE:-${OCI_CLI_PROFILE:-}}"
OCI_CONFIG_FILE="${OCI_CONFIG_FILE:-${OCI_CLI_CONFIG_FILE:-}}"
OCI_TENANCY_OCID="${OCI_TENANCY_OCID:-${OCI_CLI_TENANCY:-}}"

# Microsoft Graph endpoints (override for GCC High / DoD).
GRAPH_HOST="${GRAPH_HOST:-graph.microsoft.com}"
LOGIN_HOST="${LOGIN_HOST:-login.microsoftonline.com}"
GRAPH_SCOPE="${GRAPH_SCOPE:-https://${GRAPH_HOST}/.default}"

START_DATE=""
END_DATE=""

TEMP_FILES=()
cleanup() {
  local f
  for f in "${TEMP_FILES[@]:-}"; do
    [[ -n "$f" && -e "$f" ]] && rm -rf "$f"
  done
  return 0
}
trap cleanup EXIT

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

# ----- Embedded OCI Python SDK extractor (showusage.py-based) -----
# Emitted verbatim to a temp .py at runtime. Single-quoted heredoc marker
# ('PYEOF') means the shell performs NO expansion on the Python body.
extract_embedded_python() {
cat <<'PYEOF'
#!/usr/bin/env python3
# coding: utf-8
#
# oci_usage_extract.py  (v2)
#
# Read-only OCI cost/usage extraction using the OCI Python SDK, modeled on
# Oracle's own example:
#   https://github.com/oracle/oci-python-sdk/tree/master/examples/showusage
#
# It reuses showusage.py's proven patterns:
#   - create_signer(): instance-principal, Cloud Shell delegation token, or
#     config-file user auth.
#   - RequestSummarizedUsagesDetails with query_type / granularity / group_by
#     and RFC3339 (%Y-%m-%dT%H:%M:%SZ) time strings.
#   - retry_strategy=oci.retry.DEFAULT_RETRY_STRATEGY on the API call.
#   - Reading each returned item as a MODEL OBJECT (item.computed_amount,
#     item.sku_part_number, ...), not as dict keys.
#
# Unlike showusage.py (which prints tables), this writes two stable CSV files
# for Power BI: a detail file and a summary file. A companion bash script
# uploads them to SharePoint.
#
# DISCLAIMER: Like showusage.py, this is a reporting aid. For authoritative
# figures use OCI Cost Analysis / official Cost & Usage Reports.
##########################################################################

import argparse
import csv
import datetime as dt
import os
import sys
from decimal import Decimal, InvalidOperation

try:
    import oci
except ImportError:
    sys.exit(
        "ERROR: The OCI Python SDK is not available. In Cloud Shell it ships "
        "with the CLI. Verify: python3 -c 'import oci; print(oci.__version__)'"
    )

# Valid Usage API groupBy dimensions (from showusage.py header comment).
VALID_GROUP_BY = {
    "tagNamespace", "tagKey", "tagValue", "service", "skuName", "skuPartNumber",
    "unit", "compartmentName", "compartmentPath", "compartmentId", "platform",
    "region", "logicalAd", "resourceId", "tenantId", "tenantName",
}

VALID_QUERY_TYPES = {
    "COST", "USAGE", "USAGE_ONLY", "CREDIT", "EXPIREDCREDIT", "ALLCREDIT",
}


def log(msg):
    print(msg, file=sys.stderr)


##########################################################################
# Create signer for authentication.
# Mirrors showusage.py create_signer(): instance principals, delegation token
# (Cloud Shell), or config-file user auth.
##########################################################################
def create_signer(config_file, config_profile, is_instance_principals,
                  is_delegation_token):
    if is_instance_principals:
        try:
            signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
            config = {"region": signer.region, "tenancy": signer.tenancy_id}
            return config, signer
        except Exception:
            sys.exit("ERROR: could not obtain instance-principals certificate.")

    if is_delegation_token:
        # Cloud Shell path. showusage.py reads OCI_CONFIG_FILE /
        # OCI_CONFIG_PROFILE, loads the config, then reads
        # config["delegation_token_file"] and builds the delegation signer.
        env_config_file = os.environ.get("OCI_CONFIG_FILE")
        env_config_section = os.environ.get("OCI_CONFIG_PROFILE")
        # Cloud Shell actually exports OCI_CLI_* names; accept both.
        if not env_config_file:
            env_config_file = os.environ.get("OCI_CLI_CONFIG_FILE")
        if not env_config_section:
            env_config_section = os.environ.get("OCI_CLI_PROFILE")
        if not env_config_file or not env_config_section:
            sys.exit(
                "ERROR: delegation-token auth requires OCI_CONFIG_FILE and "
                "OCI_CONFIG_PROFILE (or OCI_CLI_CONFIG_FILE / OCI_CLI_PROFILE). "
                "These are normally set automatically in OCI Cloud Shell."
            )
        try:
            config = oci.config.from_file(env_config_file, env_config_section)
        except Exception as exc:
            sys.exit(f"ERROR: unable to load OCI config "
                     f"[{env_config_section}] from {env_config_file}: {exc}")
        try:
            delegation_token_location = config["delegation_token_file"]
        except KeyError:
            sys.exit("ERROR: delegation_token_file not found in the OCI config "
                     "profile; are you running inside Cloud Shell?")
        try:
            with open(os.path.expanduser(delegation_token_location),
                      encoding="utf-8") as fh:
                delegation_token = fh.read().strip()
        except OSError as exc:
            sys.exit(f"ERROR: cannot read delegation token at "
                     f"{delegation_token_location}: {exc}")
        signer = oci.auth.signers.InstancePrincipalsDelegationTokenSigner(
            delegation_token=delegation_token
        )
        return config, signer

    # Config-file user authentication.
    try:
        config = oci.config.from_file(
            config_file if config_file else oci.config.DEFAULT_LOCATION,
            config_profile if config_profile else oci.config.DEFAULT_PROFILE,
        )
    except Exception as exc:
        sys.exit(f"ERROR: unable to load OCI config: {exc}")
    signer = oci.signer.Signer(
        tenancy=config["tenancy"],
        user=config["user"],
        fingerprint=config["fingerprint"],
        private_key_file_location=config.get("key_file"),
        pass_phrase=oci.config.get_config_value_or_default(config, "pass_phrase"),
        private_key_content=config.get("key_content"),
    )
    return config, signer


##########################################################################
# Helpers for reading model attributes and money-safe decimals.
##########################################################################
def attr(item, name, default=""):
    value = getattr(item, name, None)
    return default if value is None else value


def dec_strict(value, row_index, field):
    # Empty/None legitimately means zero (field simply absent for this row).
    # A non-empty value that will not parse as a number is a data-integrity
    # problem for financial reporting and must stop the run, not become 0.
    if value in ("", None):
        return Decimal("0")
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        sys.exit(
            f"ERROR: non-numeric {field}={value!r} in row {row_index}. "
            "Refusing to write financial data with an invalid value. "
            "Inspect the OCI response for this row before proceeding."
        )


def iso_z(value):
    # SDK returns datetime for time fields; normalize to ...Z string. If it is
    # already a string, pass through.
    if isinstance(value, dt.datetime):
        return value.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return str(value) if value else ""


##########################################################################
# Extract usage with pagination and write the two CSVs.
##########################################################################
def main():
    parser = argparse.ArgumentParser(
        description="Read-only OCI cost/usage extract to Power BI CSVs "
                    "(showusage.py-based)."
    )
    parser.add_argument("-c", dest="config_file", default="",
                        help="OCI config file (default: SDK default location).")
    parser.add_argument("-t", dest="config_profile", default="",
                        help="Config profile name.")
    parser.add_argument("-ip", dest="instance_principals", action="store_true",
                        help="Use instance principals for authentication.")
    parser.add_argument("-dt", dest="delegation_token", action="store_true",
                        help="Use Cloud Shell delegation token.")
    parser.add_argument("-ds", dest="date_start", required=True,
                        help="Start date YYYY-MM-DD (UTC, inclusive).")
    parser.add_argument("-de", dest="date_end", default="",
                        help="End date YYYY-MM-DD (UTC, exclusive).")
    parser.add_argument("-days", dest="days", type=int, default=0,
                        help="Days from start (overrides -de).")
    parser.add_argument("-g", dest="granularity", default="DAILY",
                        help="Granularity: HOURLY, DAILY, or MONTHLY.")
    parser.add_argument("-qt", dest="query_type", default="COST",
                        help="Query type: COST, USAGE, USAGE_ONLY, ...")
    parser.add_argument("-gb", dest="group_by", default=None,
                        help="Comma-separated groupBy dimensions "
                             "(default: service,compartmentName,resourceId,skuPartNumber).")
    parser.add_argument("--tenant-id", dest="tenant_id", default="",
                        help="Tenancy OCID (default: from signer/config).")
    parser.add_argument("--detail-csv", dest="detail_csv", required=True,
                        help="Output path for the detail CSV.")
    parser.add_argument("--summary-csv", dest="summary_csv", required=True,
                        help="Output path for the summary CSV.")
    parser.add_argument("--max-groupby", dest="max_groupby", type=int, default=4,
                        help="Max groupBy dimensions this tool allows.")
    args = parser.parse_args()

    # --- Validate query type / granularity ---
    query_type = args.query_type.upper()
    if query_type not in VALID_QUERY_TYPES:
        sys.exit(f"ERROR: invalid query type {query_type}. "
                 f"Use one of: {', '.join(sorted(VALID_QUERY_TYPES))}.")
    granularity = args.granularity.upper()
    if granularity not in {"HOURLY", "DAILY", "MONTHLY"}:
        sys.exit(f"ERROR: invalid granularity {granularity}. "
                 "Use HOURLY, DAILY, or MONTHLY.")

    # --- groupBy ---
    if args.group_by:
        group_by = [g.strip() for g in args.group_by.split(",") if g.strip()]
    else:
        group_by = ["service", "compartmentName", "resourceId", "skuPartNumber"]
    if len(group_by) > args.max_groupby:
        sys.exit(f"ERROR: {len(group_by)} groupBy dimensions requested; this "
                 f"tool limits grouping to {args.max_groupby}.")
    invalid = sorted(set(group_by) - VALID_GROUP_BY)
    if invalid:
        sys.exit(f"ERROR: unsupported groupBy dimensions: {', '.join(invalid)}.")

    # --- Dates ---
    try:
        start = dt.datetime.strptime(args.date_start, "%Y-%m-%d")
    except ValueError:
        sys.exit("ERROR: -ds must be YYYY-MM-DD.")
    if args.days and args.days > 0:
        end = start + dt.timedelta(days=args.days)
    elif args.date_end:
        try:
            end = dt.datetime.strptime(args.date_end, "%Y-%m-%d")
        except ValueError:
            sys.exit("ERROR: -de must be YYYY-MM-DD.")
    else:
        sys.exit("ERROR: provide either -de or -days.")
    if start >= end:
        sys.exit("ERROR: start date must be earlier than end date.")

    span_days = (end - start).days
    if granularity == "HOURLY" and span_days > 1:
        sys.exit(f"ERROR: HOURLY window should be <= 24h; got {span_days} days.")
    if granularity == "DAILY" and span_days > 90:
        sys.exit(f"ERROR: DAILY window cannot exceed 90 days; got {span_days}.")
    if granularity == "MONTHLY" and span_days > 366:
        sys.exit(f"ERROR: MONTHLY window cannot exceed ~12 months; "
                 f"got {span_days} days.")

    # --- Auth (showusage.py create_signer pattern) ---
    config, signer = create_signer(
        args.config_file, args.config_profile,
        args.instance_principals, args.delegation_token,
    )

    tenant_id = (args.tenant_id
                 or os.environ.get("OCI_TENANCY_OCID", "")
                 or (config.get("tenancy") if isinstance(config, dict) else "")
                 or getattr(signer, "tenancy_id", ""))
    if not tenant_id:
        sys.exit("ERROR: could not determine tenancy OCID. Pass --tenant-id.")

    usage_client = oci.usage_api.UsageapiClient(config, signer=signer)

    # The Usage API must be called in the tenancy HOME region. In Cloud Shell
    # the region comes from the selected profile / signer; if Cloud Shell was
    # opened in a non-home region this can fail. Surface the region so a
    # mismatch is diagnosable, and allow an override via OCI_HOME_REGION.
    active_region = ""
    if isinstance(config, dict):
        active_region = config.get("region", "") or ""
    active_region = active_region or getattr(signer, "region", "") or ""
    home_region = os.environ.get("OCI_HOME_REGION", "").strip()
    if home_region and active_region and home_region != active_region:
        log(f"Overriding endpoint region {active_region} -> home region "
            f"{home_region} (OCI_HOME_REGION).")
        try:
            usage_client.base_client.set_region(home_region)
            active_region = home_region
        except Exception as exc:
            log(f"WARNING: could not set home region {home_region}: {exc}")
    log(f"Usage API region: {active_region or '<from signer/default>'} "
        "(must be the tenancy HOME region).")

    details = oci.usage_api.models.RequestSummarizedUsagesDetails(
        tenant_id=tenant_id,
        granularity=granularity,
        query_type=query_type,
        group_by=group_by,
        is_aggregate_by_time=False,
        time_usage_started=start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        time_usage_ended=end.strftime("%Y-%m-%dT%H:%M:%SZ"),
    )

    log(f"Extracting OCI {query_type} data {start.date()} .. {end.date()} "
        f"(exclusive), granularity {granularity}, groupBy {group_by}")

    # --- Paginate: request_summarized_usages exposes next_page / opc-next-page ---
    items = []
    page = None
    page_number = 0
    seen = set()
    while True:
        page_number += 1
        kwargs = {"retry_strategy": oci.retry.DEFAULT_RETRY_STRATEGY}
        if page:
            kwargs["page"] = page
        try:
            resp = usage_client.request_summarized_usages(details, **kwargs)
        except oci.exceptions.ServiceError as exc:
            sys.exit(f"ERROR: OCI Usage API request failed (page {page_number}): "
                     f"{exc.status} {exc.code} - {exc.message}. Verify the policy "
                     "'read usage-report in tenancy' and your authentication.")
        page_items = resp.data.items or []
        items.extend(page_items)
        log(f"Retrieved OCI Usage API page {page_number}: {len(page_items)} row(s)")

        next_page = getattr(resp, "next_page", None)
        if not next_page:
            try:
                next_page = (resp.headers or {}).get("opc-next-page")
            except Exception:
                next_page = None
        if not next_page:
            break
        next_page = str(next_page).strip()
        if next_page in seen:
            sys.exit("ERROR: repeated pagination token; stopping to avoid a loop.")
        seen.add(next_page)
        page = next_page
        if page_number >= 200:
            sys.exit("ERROR: exceeded 200 pages; extraction may be incomplete. "
                     "Narrow the window or grouping. Nothing was written.")

    log(f"Retrieved {len(items)} total row(s) across {page_number} page(s).")

    extract_utc = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # --- Normalize using MODEL ATTRIBUTES (showusage.py reads item.<attr>) ---
    detail_fields = [
        "extract_utc", "usage_start_utc", "usage_end_utc", "service",
        "compartment_name", "compartment_id", "resource_name", "resource_id",
        "sku_name", "sku_part_number", "unit", "currency",
        "computed_quantity", "computed_amount", "attributed_cost",
        "subscription_id", "overages_flag", "overage",
    ]
    normalized = []
    for it in items:
        normalized.append({
            "extract_utc": extract_utc,
            "usage_start_utc": iso_z(getattr(it, "time_usage_started", None)),
            "usage_end_utc": iso_z(getattr(it, "time_usage_ended", None)),
            "service": attr(it, "service"),
            "compartment_name": attr(it, "compartment_name"),
            "compartment_id": attr(it, "compartment_id"),
            "resource_name": attr(it, "resource_name"),
            "resource_id": attr(it, "resource_id"),
            "sku_name": attr(it, "sku_name"),
            "sku_part_number": attr(it, "sku_part_number"),
            "unit": attr(it, "unit"),
            "currency": str(attr(it, "currency")).strip(),
            # computed_amount/quantity are floats; attributed_cost is a str per
            # the UsageSummary model. dec_strict() below rejects malformed data.
            "computed_quantity": attr(it, "computed_quantity", 0),
            "computed_amount": attr(it, "computed_amount", 0),
            "attributed_cost": attr(it, "attributed_cost", 0),
            "subscription_id": attr(it, "subscription_id"),
            # UsageSummary has BOTH overages_flag (the SPM OverageFlag) and
            # overage (the overage usage). Keep them as separate columns.
            "overages_flag": attr(it, "overages_flag"),
            "overage": attr(it, "overage"),
        })

    normalized.sort(key=lambda r: (
        str(r["usage_start_utc"]), str(r["service"]),
        str(r["compartment_name"]), str(r["resource_name"]),
        str(r["sku_name"]),
    ))

    # --- Fail-fast schema guard ---
    if normalized:
        populated_dates = sum(1 for r in normalized if r["usage_start_utc"])
        populated_amounts = sum(
            1 for r in normalized
            if r["computed_amount"] not in ("", None, 0, "0")
        )
        if populated_dates == 0:
            sys.exit("ERROR: rows returned but every usage_start_utc is blank; "
                     "the SDK model attribute mapping does not match the "
                     "response. Refusing to write unusable CSVs.")
        if populated_amounts == 0:
            log("WARNING: computed_amount is zero/blank for every row. May be "
                "legitimate (USAGE query or zero-cost period); verify.")

    # --- Validate all monetary/quantity values ONCE, strictly. A malformed
    # value stops the run with the row index and field identified, rather than
    # silently becoming zero and understating cost. ---
    for i, row in enumerate(normalized):
        row["_computed_quantity"] = dec_strict(row["computed_quantity"], i, "computed_quantity")
        row["_computed_amount"] = dec_strict(row["computed_amount"], i, "computed_amount")
        row["_attributed_cost"] = dec_strict(row["attributed_cost"], i, "attributed_cost")

    # --- Write detail CSV (UTF-8 BOM for Power BI) ---
    with open(args.detail_csv, "w", newline="", encoding="utf-8-sig") as fh:
        writer = csv.DictWriter(fh, fieldnames=detail_fields,
                                extrasaction="ignore")
        writer.writeheader()
        for row in normalized:
            out = dict(row)
            out["computed_quantity"] = str(row["_computed_quantity"])
            out["computed_amount"] = str(row["_computed_amount"])
            out["attributed_cost"] = str(row["_attributed_cost"])
            writer.writerow(out)

    # --- Summary CSV aggregated by date/service/compartment/currency/unit ---
    summary = {}
    for row in normalized:
        key = (row["usage_start_utc"], row["service"],
               row["compartment_name"], row["currency"], row["unit"])
        bucket = summary.setdefault(key, {
            "computed_quantity": Decimal("0"),
            "computed_amount": Decimal("0"),
            "attributed_cost": Decimal("0"),
            "row_count": 0,
        })
        bucket["computed_quantity"] += row["_computed_quantity"]
        bucket["computed_amount"] += row["_computed_amount"]
        bucket["attributed_cost"] += row["_attributed_cost"]
        bucket["row_count"] += 1

    summary_fields = [
        "extract_utc", "usage_start_utc", "service", "compartment_name",
        "currency", "unit", "computed_quantity", "computed_amount",
        "attributed_cost", "row_count",
    ]
    with open(args.summary_csv, "w", newline="", encoding="utf-8-sig") as fh:
        writer = csv.DictWriter(fh, fieldnames=summary_fields)
        writer.writeheader()
        for key in sorted(summary):
            usage_start, service, compartment, currency, unit = key
            v = summary[key]
            writer.writerow({
                "extract_utc": extract_utc,
                "usage_start_utc": usage_start,
                "service": service,
                "compartment_name": compartment,
                "currency": currency,
                "unit": unit,
                "computed_quantity": str(v["computed_quantity"]),
                "computed_amount": str(v["computed_amount"]),
                "attributed_cost": str(v["attributed_cost"]),
                "row_count": v["row_count"],
            })

    # --- Totals PER CURRENCY (adding across currencies is meaningless) ---
    totals_by_currency = {}
    for row in normalized:
        cur = row["currency"] or "UNKNOWN"
        totals_by_currency[cur] = totals_by_currency.get(cur, Decimal("0")) + row["_computed_amount"]

    currencies = sorted(c for c in totals_by_currency if c != "UNKNOWN")
    print(f"detail_rows={len(normalized)}")
    print(f"summary_rows={len(summary)}")
    print(f"currencies={','.join(currencies)}")
    # One machine-readable total line per currency, e.g.
    #   computed_amount_total[USD]=123.45
    for cur in sorted(totals_by_currency):
        print(f"computed_amount_total[{cur}]={totals_by_currency[cur]}")
    if len(totals_by_currency) > 1:
        log("NOTE: multiple currencies present; totals are reported separately "
            "per currency. There is no single combined total.")


if __name__ == "__main__":
    main()

PYEOF
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Runs the showusage-based OCI extractor and uploads the two stable CSVs to
SharePoint. Recommended first run:
  $SCRIPT_NAME --days 7 --no-upload

Options:
  --days N            UTC days to retrieve (default: $DAYS_BACK).
  --start YYYY-MM-DD  Explicit UTC start (inclusive).
  --end YYYY-MM-DD    Explicit UTC end (exclusive).
  --output-dir PATH   Local output directory (default: $OUTPUT_DIR).
  --no-upload         Create CSVs but do not upload.
  --no-archive        Do not keep timestamped local archive CSVs.
  --oci-auth METHOD   delegation_token | instance_principal | config.
                      Default: inferred from OCI_CLI_AUTH.
  --profile NAME      OCI config profile.
  -h, --help          Show help.

SharePoint env vars (required when uploading):
  MS_TENANT_ID MS_CLIENT_ID MS_CLIENT_SECRET
  SP_HOSTNAME SP_SITE_PATH SP_LIBRARY_NAME SP_FOLDER_PATH (must exist)

GCC High / DoD: set GRAPH_HOST=graph.microsoft.us,
  LOGIN_HOST=login.microsoftonline.us, GRAPH_SCOPE=https://graph.microsoft.us/.default

Other optional env: GRANULARITY, OCI_QUERY_TYPE, GROUP_BY, UPLOAD_EMPTY_REPORT,
  KEEP_LOCAL_ARCHIVE, UPLOAD_ARCHIVE_TO_SHAREPOINT, OCI_TENANCY_OCID.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)       DAYS_BACK="${2:?Missing value for --days}"; shift 2 ;;
    --start)      START_DATE="${2:?Missing value for --start}"; shift 2 ;;
    --end)        END_DATE="${2:?Missing value for --end}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:?Missing value for --output-dir}"; shift 2 ;;
    --no-upload)  UPLOAD_TO_SHAREPOINT=false; shift ;;
    --no-archive) KEEP_LOCAL_ARCHIVE=false; shift ;;
    --oci-auth)   OCI_AUTH="${2:?Missing value for --oci-auth}"; shift 2 ;;
    --profile)    OCI_PROFILE="${2:?Missing value for --profile}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "Unknown argument: $1" ;;
  esac
done

need python3
need curl
python3 -c 'import oci' >/dev/null 2>&1 || die "OCI Python SDK not available (import oci failed)."

# Write the embedded Python extractor to a temp file (see heredoc at EOF).
EXTRACTOR="$(mktemp --suffix=.py)"
TEMP_FILES+=("$EXTRACTOR")
extract_embedded_python > "$EXTRACTOR"

normalize_bool() {
  local name="$1"
  local value="${!name,,}"
  case "$value" in
    true|false) printf -v "$name" '%s' "$value" ;;
    *) die "$name must be 'true' or 'false'; received: ${!name}" ;;
  esac
}
normalize_bool UPLOAD_TO_SHAREPOINT
normalize_bool UPLOAD_EMPTY_REPORT
normalize_bool KEEP_LOCAL_ARCHIVE
normalize_bool UPLOAD_ARCHIVE_TO_SHAREPOINT
if [[ "$UPLOAD_ARCHIVE_TO_SHAREPOINT" == "true" ]]; then KEEP_LOCAL_ARCHIVE=true; fi

validate_filename() {
  local name="$1"
  local value="${!name}"
  [[ -n "$value" ]] || die "$name cannot be empty."
  [[ "$value" != */* && "$value" != *\\* ]] || die "$name must be a filename only: $value"
  [[ "$value" != "." && "$value" != ".." ]] || die "Invalid $name: $value"
}
validate_filename STABLE_CSV_NAME
validate_filename STABLE_SUMMARY_NAME
[[ "$STABLE_CSV_NAME" != "$STABLE_SUMMARY_NAME" ]] || die "Stable filenames must differ."

[[ "$DAYS_BACK" =~ ^[0-9]+$ ]] || die "--days must be a positive integer."
(( DAYS_BACK > 0 )) || die "--days must be greater than zero."

# Map OCI_AUTH (which may be the Cloud Shell value instance_obo_user) to the
# extractor's auth flags.
EXTRA_AUTH_ARGS=()
# Resolve empty OCI_AUTH: use delegation token only if we're actually in Cloud
# Shell (delegation token present); otherwise fall back to config-file auth so
# the tool is portable to a VM / laptop without requiring --oci-auth config.
if [[ -z "$OCI_AUTH" ]]; then
  DELEG_TOKEN_PATH="${OCI_CLI_DELEGATION_TOKEN_FILE:-/etc/oci/delegation_token}"
  if [[ "${OCI_CLI_AUTH:-}" == "instance_obo_user" || -r "$DELEG_TOKEN_PATH" ]]; then
    OCI_AUTH="delegation_token"
  else
    OCI_AUTH="config"
  fi
fi

case "${OCI_AUTH,,}" in
  instance_obo_user|delegation_token|delegation|obo)
    EXTRA_AUTH_ARGS+=(-dt)
    export OCI_CONFIG_FILE="${OCI_CONFIG_FILE:-${OCI_CLI_CONFIG_FILE:-/etc/oci/config}}"
    export OCI_CONFIG_PROFILE="${OCI_PROFILE:-${OCI_CLI_PROFILE:-DEFAULT}}"
    ;;
  instance_principal|instance_principals|ip)
    EXTRA_AUTH_ARGS+=(-ip)
    ;;
  config|api_key|user)
    [[ -n "$OCI_PROFILE" ]] && EXTRA_AUTH_ARGS+=(-t "$OCI_PROFILE")
    [[ -n "$OCI_CONFIG_FILE" ]] && EXTRA_AUTH_ARGS+=(-c "$OCI_CONFIG_FILE")
    ;;
  *)
    die "Unsupported --oci-auth: $OCI_AUTH (use delegation_token, instance_principal, or config)."
    ;;
esac

mkdir -p "$OUTPUT_DIR"
RUN_TS="$(date -u +'%Y%m%dT%H%M%SZ')"

# Resolve the date window (end exclusive). --days N == exactly N days.
if [[ -z "$START_DATE" ]]; then
  START_DATE="$(date -u -d "$((DAYS_BACK - 1)) days ago" +'%Y-%m-%d')"
fi
if [[ -z "$END_DATE" ]]; then
  END_DATE="$(date -u -d 'tomorrow' +'%Y-%m-%d')"
fi

LATEST_CSV="$OUTPUT_DIR/$STABLE_CSV_NAME"
SUMMARY_CSV="$OUTPUT_DIR/$STABLE_SUMMARY_NAME"
ARCHIVE_CSV="$OUTPUT_DIR/oci_cost_usage_${START_DATE}_to_${END_DATE}_${RUN_TS}.csv"
ARCHIVE_SUMMARY="$OUTPUT_DIR/oci_cost_summary_${START_DATE}_to_${END_DATE}_${RUN_TS}.csv"

# Print resolved context (no secrets).
log "Home:        $HOME"
log "Output dir:  $OUTPUT_DIR"
log "OCI auth:    ${OCI_AUTH:-<default: delegation_token>}"
log "OCI profile: ${OCI_CONFIG_PROFILE:-${OCI_PROFILE:-<none>}}"
log "Window:      $START_DATE .. $END_DATE (end exclusive)"

# Build extractor args.
EXTRACT_ARGS=(
  "${EXTRA_AUTH_ARGS[@]}"
  -ds "$START_DATE"
  -de "$END_DATE"
  -g "$GRANULARITY"
  -qt "$OCI_QUERY_TYPE"
  --detail-csv "$LATEST_CSV"
  --summary-csv "$SUMMARY_CSV"
)
[[ -n "$GROUP_BY" ]] && EXTRACT_ARGS+=(-gb "$GROUP_BY")
[[ -n "$OCI_TENANCY_OCID" ]] && EXTRACT_ARGS+=(--tenant-id "$OCI_TENANCY_OCID")

# Run the extractor, capturing its stdout key=value summary.
EXTRACT_OUT="$(python3 "$EXTRACTOR" "${EXTRACT_ARGS[@]}")" \
  || die "OCI extraction failed. See messages above."
printf '%s\n' "$EXTRACT_OUT" | while IFS= read -r line; do log "extract: $line"; done

get_kv() { printf '%s\n' "$EXTRACT_OUT" | sed -n "s/^$1=//p" | head -1; }
DETAIL_ROWS="$(get_kv detail_rows)"
SUMMARY_ROWS="$(get_kv summary_rows)"
CURRENCIES="$(get_kv currencies)"
# Per-currency totals arrive as lines like: computed_amount_total[USD]=123.45
CURRENCY_TOTALS="$(printf '%s\n' "$EXTRACT_OUT" | sed -n 's/^computed_amount_total\[\(.*\)\]=\(.*\)$/  \1: \2/p')"

[[ -s "$LATEST_CSV" ]] || die "Detail CSV was not created."
[[ -s "$SUMMARY_CSV" ]] || die "Summary CSV was not created."

# Empty-report protection.
if [[ "${DETAIL_ROWS:-0}" == "0" ]]; then
  log "WARNING: OCI returned zero rows for the window."
  if [[ "$UPLOAD_TO_SHAREPOINT" == "true" && "$UPLOAD_EMPTY_REPORT" != "true" ]]; then
    die "Refusing to overwrite the SharePoint Power BI source with an empty report. Set UPLOAD_EMPTY_REPORT=true to allow, or re-run --no-upload to inspect."
  fi
fi

# Local archive copies.
if [[ "$KEEP_LOCAL_ARCHIVE" == "true" ]]; then
  cp -f "$LATEST_CSV" "$ARCHIVE_CSV"
  cp -f "$SUMMARY_CSV" "$ARCHIVE_SUMMARY"
fi

##########################################################################
# SharePoint upload via Microsoft Graph.
##########################################################################
MAX_SIMPLE_UPLOAD_BYTES=$((250 * 1024 * 1024))

upload_file_graph() {
  local local_file="$1" remote_name="$2"
  local encoded_folder encoded_name upload_url http_code response_file size

  size="$(stat -c '%s' "$local_file")"
  if (( size > MAX_SIMPLE_UPLOAD_BYTES )); then
    die "File exceeds Graph's 250 MB simple-upload limit ($size bytes): $local_file"
  fi

  encoded_folder="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1].strip("/"), safe="/"))' "$SP_FOLDER_PATH")"
  encoded_name="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$remote_name")"

  if [[ -n "$encoded_folder" ]]; then
    upload_url="https://${GRAPH_HOST}/v1.0/drives/${DRIVE_ID}/root:/${encoded_folder}/${encoded_name}:/content"
  else
    upload_url="https://${GRAPH_HOST}/v1.0/drives/${DRIVE_ID}/root:/${encoded_name}:/content"
  fi

  response_file="$(mktemp)"; TEMP_FILES+=("$response_file")
  http_code="$(
    curl --silent --show-error \
      --retry 5 --retry-delay 2 --retry-max-time 120 --retry-all-errors \
      --output "$response_file" --write-out '%{http_code}' \
      --request PUT \
      --header "Authorization: Bearer $GRAPH_TOKEN" \
      --header "Content-Type: text/csv" \
      --data-binary "@$local_file" \
      "$upload_url"
  )"
  if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
    cat "$response_file" >&2 || true
    die "SharePoint upload failed for $remote_name (HTTP $http_code)."
  fi
  python3 - "$response_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    item = json.load(fh)
print("Uploaded:", item.get("name", "unknown"), "->", item.get("webUrl", ""))
PY
}

if [[ "$UPLOAD_TO_SHAREPOINT" == "true" ]]; then
  : "${MS_TENANT_ID:?Set MS_TENANT_ID}"
  : "${MS_CLIENT_ID:?Set MS_CLIENT_ID}"
  : "${MS_CLIENT_SECRET:?Set MS_CLIENT_SECRET}"
  : "${SP_HOSTNAME:?Set SP_HOSTNAME}"
  : "${SP_SITE_PATH:?Set SP_SITE_PATH}"
  : "${SP_LIBRARY_NAME:?Set SP_LIBRARY_NAME}"
  : "${SP_FOLDER_PATH:?Set SP_FOLDER_PATH}"

  log "Requesting Microsoft Graph app-only token..."
  TOKEN_RESPONSE="$(
    MS_CLIENT_ID="$MS_CLIENT_ID" MS_CLIENT_SECRET="$MS_CLIENT_SECRET" GRAPH_SCOPE="$GRAPH_SCOPE" \
    python3 <<'PY' |
import os, urllib.parse
print(urllib.parse.urlencode({
    "client_id": os.environ["MS_CLIENT_ID"],
    "client_secret": os.environ["MS_CLIENT_SECRET"],
    "scope": os.environ["GRAPH_SCOPE"],
    "grant_type": "client_credentials",
}), end="")
PY
    curl --silent --show-error --fail \
      --retry 5 --retry-delay 2 --retry-max-time 60 --retry-all-errors \
      --request POST \
      --header 'Content-Type: application/x-www-form-urlencoded' \
      --data-binary @- \
      "https://${LOGIN_HOST}/${MS_TENANT_ID}/oauth2/v2.0/token"
  )"
  GRAPH_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))' <<<"$TOKEN_RESPONSE")"
  [[ -n "$GRAPH_TOKEN" ]] || die "Microsoft Graph did not return an access token."
  unset TOKEN_RESPONSE MS_CLIENT_SECRET

  ENCODED_SITE_PATH="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1].strip("/"), safe="/"))' "$SP_SITE_PATH")"
  SITE_RESPONSE_FILE="$(mktemp)"; TEMP_FILES+=("$SITE_RESPONSE_FILE")
  SITE_HTTP_CODE="$(
    curl --silent --show-error --retry 5 --retry-delay 2 --retry-max-time 60 --retry-all-errors \
      --output "$SITE_RESPONSE_FILE" --write-out '%{http_code}' \
      --header "Authorization: Bearer $GRAPH_TOKEN" \
      "https://${GRAPH_HOST}/v1.0/sites/${SP_HOSTNAME}:/${ENCODED_SITE_PATH}"
  )"
  if [[ "$SITE_HTTP_CODE" != "200" ]]; then
    cat "$SITE_RESPONSE_FILE" >&2 || true
    die "Could not resolve SharePoint site (HTTP $SITE_HTTP_CODE). If using Sites.Selected, ensure the app was granted access to this site (POST /sites/{id}/permissions)."
  fi
  SITE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("id",""))' "$SITE_RESPONSE_FILE")"
  [[ -n "$SITE_ID" ]] || die "SharePoint response did not contain a site ID."

  # List document libraries, following @odata.nextLink so a library beyond the
  # first page is still found.
  DRIVE_ID=""
  DRIVES_URL="https://${GRAPH_HOST}/v1.0/sites/${SITE_ID}/drives"
  DRIVES_PAGE=0
  while [[ -n "$DRIVES_URL" && -z "$DRIVE_ID" ]]; do
    DRIVES_PAGE=$((DRIVES_PAGE + 1))
    (( DRIVES_PAGE <= 20 )) || die "Too many drive pages; aborting library search."
    DRIVES_RESPONSE_FILE="$(mktemp)"; TEMP_FILES+=("$DRIVES_RESPONSE_FILE")
    DRIVES_HTTP_CODE="$(
      curl --silent --show-error --retry 5 --retry-delay 2 --retry-max-time 60 --retry-all-errors \
        --output "$DRIVES_RESPONSE_FILE" --write-out '%{http_code}' \
        --header "Authorization: Bearer $GRAPH_TOKEN" \
        "$DRIVES_URL"
    )"
    if [[ "$DRIVES_HTTP_CODE" != "200" ]]; then
      cat "$DRIVES_RESPONSE_FILE" >&2 || true
      die "Could not list SharePoint document libraries (HTTP $DRIVES_HTTP_CODE)."
    fi
    # Emit either the matching drive id, or "NEXT<tab>url" to continue.
    MATCH="$(
      python3 - "$DRIVES_RESPONSE_FILE" "$SP_LIBRARY_NAME" <<'PY'
import json, sys
response_file, library_name = sys.argv[1:3]
with open(response_file, encoding="utf-8") as fh:
    payload = json.load(fh)
lib = library_name.casefold()
for drive in payload.get("value", []):
    if str(drive.get("name", "")).casefold() == lib:
        print("ID\t" + drive.get("id", "")); break
else:
    nxt = payload.get("@odata.nextLink", "")
    print("NEXT\t" + nxt if nxt else "NONE\t")
PY
    )"
    case "$MATCH" in
      ID*)   DRIVE_ID="${MATCH#ID$'\t'}" ;;
      NEXT*) DRIVES_URL="${MATCH#NEXT$'\t'}" ;;
      *)     DRIVES_URL="" ;;
    esac
  done
  [[ -n "$DRIVE_ID" ]] || die "SharePoint document library not found: $SP_LIBRARY_NAME"

  # Verify the folder exists and is a folder.
  ENCODED_FOLDER_CHECK="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1].strip("/"), safe="/"))' "$SP_FOLDER_PATH")"
  if [[ -n "$ENCODED_FOLDER_CHECK" ]]; then
    FOLDER_RESPONSE_FILE="$(mktemp)"; TEMP_FILES+=("$FOLDER_RESPONSE_FILE")
    FOLDER_HTTP_CODE="$(
      curl --silent --show-error --retry 5 --retry-delay 2 --retry-max-time 60 --retry-all-errors \
        --output "$FOLDER_RESPONSE_FILE" --write-out '%{http_code}' \
        --header "Authorization: Bearer $GRAPH_TOKEN" \
        "https://${GRAPH_HOST}/v1.0/drives/${DRIVE_ID}/root:/${ENCODED_FOLDER_CHECK}"
    )"
    if [[ "$FOLDER_HTTP_CODE" != "200" ]]; then
      cat "$FOLDER_RESPONSE_FILE" >&2 || true
      die "SharePoint folder does not exist or is inaccessible: $SP_FOLDER_PATH (HTTP $FOLDER_HTTP_CODE). Create it first."
    fi
    python3 - "$FOLDER_RESPONSE_FILE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    item = json.load(fh)
if not item.get("folder"):
    raise SystemExit("The configured SharePoint path exists but is not a folder.")
PY
  fi

  log "Uploading stable CSV files to SharePoint..."
  upload_file_graph "$LATEST_CSV" "$STABLE_CSV_NAME"
  upload_file_graph "$SUMMARY_CSV" "$STABLE_SUMMARY_NAME"

  if [[ "$UPLOAD_ARCHIVE_TO_SHAREPOINT" == "true" ]]; then
    [[ -f "$ARCHIVE_CSV" ]] || die "Archive upload requested but detail archive missing."
    [[ -f "$ARCHIVE_SUMMARY" ]] || die "Archive upload requested but summary archive missing."
    upload_file_graph "$ARCHIVE_CSV" "$(basename "$ARCHIVE_CSV")"
    upload_file_graph "$ARCHIVE_SUMMARY" "$(basename "$ARCHIVE_SUMMARY")"
  fi
else
  log "Upload skipped (--no-upload)."
fi

log "Completed successfully."
printf '\nOutput:\n'
printf '  Detail CSV:            %s (%s rows)\n' "$LATEST_CSV" "${DETAIL_ROWS:-?}"
printf '  Summary CSV:           %s (%s rows)\n' "$SUMMARY_CSV" "${SUMMARY_ROWS:-?}"
printf '  Currency value(s):     %s\n' "${CURRENCIES:-?}"
if [[ -n "$CURRENCY_TOTALS" ]]; then
  printf '  Computed amount total (per currency):\n'
  printf '%s\n' "$CURRENCY_TOTALS"
fi
printf '  Date window:           %s through %s (end exclusive)\n' "$START_DATE" "$END_DATE"
printf '\nReminder: compare each per-currency total against OCI Console > Cost Analysis before automating.\n'
printf 'Note: the Usage API must run in the tenancy HOME region. Open Cloud Shell in\n'
printf 'the home region, or set OCI_HOME_REGION, if extraction fails with a region error.\n'
printf 'Note: OCI Cloud Shell is not a durable scheduler (sessions time out). For\n'
printf 'recurring runs use OCI Functions + Resource Scheduler, a small Compute VM\n'
printf 'with cron, or OCI DevOps, pulling MS_CLIENT_SECRET from OCI Vault.\n'
