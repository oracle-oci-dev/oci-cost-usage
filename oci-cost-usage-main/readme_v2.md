# OCI Cost & Usage → SharePoint → Power BI (v2, showusage-based)

v2 rebuilds the OCI extraction around Oracle's official example,
[`examples/showusage`](https://github.com/oracle/oci-python-sdk/tree/master/examples/showusage),
in the OCI Python SDK. It is a **single self-contained file**,
`oci_cost_usage_to_sharepoint_v2.sh`:

- A bash wrapper resolves the Cloud Shell auth mode, then uploads the two stable
  CSVs to SharePoint via Microsoft Graph.
- The OCI Python SDK extractor is **embedded** in the script and written to a
  temporary file at runtime (cleaned up on exit). It uses the SDK exactly as
  `showusage.py` does: `create_signer()` for auth, `RequestSummarizedUsagesDetails`
  with `query_type` / `granularity` / `group_by` and RFC3339 time strings,
  `retry_strategy=oci.retry.DEFAULT_RETRY_STRATEGY`, and reads each returned row
  as an SDK **model object** (`item.computed_amount`, `item.sku_part_number`,
  `item.time_usage_started`, …). It writes two Power BI CSVs.

## Why this design

Reading results as model objects (like `showusage.py`) removes the whole class
of "which key format does the JSON use" bugs — there is no dict-key guessing.
The extractor also keeps a fail-fast guard: if rows come back but every usage
date is blank, it refuses to write, so a schema mismatch can't silently produce
a financially blank CSV.

## Authentication

The wrapper maps Cloud Shell's `OCI_CLI_AUTH=instance_obo_user` to the
extractor's `-dt` (delegation token) flag automatically. The extractor supports:

- `-dt` delegation token (Cloud Shell). Reads `OCI_CONFIG_FILE` /
  `OCI_CONFIG_PROFILE` (or the `OCI_CLI_*` equivalents), loads the config, reads
  `delegation_token_file`, and builds `InstancePrincipalsDelegationTokenSigner`.
- `-ip` instance principals.
- config-file user auth (`-c` / `-t`).

## IAM policy

`showusage.py` documents the policy as:

```text
Allow group <grp> to inspect tenancies in tenancy
Allow group <grp> to read usage-report in tenancy
```

Oracle's example uses `usage-report` for the Usage API. If your tenancy's
access model differs (some environments authorize the API under `usage-data`),
adjust and confirm with a `--no-upload` run — the extractor prints the exact
service error, including the policy hint, if the request is refused.

## Quick start (Cloud Shell)

```bash
chmod 700 oci_cost_usage_to_sharepoint_v2.sh

# 1) SDK present?
python3 -c 'import oci; print(oci.__version__)'

# 2) Safe first test (no upload)
./oci_cost_usage_to_sharepoint_v2.sh --days 7 --no-upload --no-archive

# 3) Inspect
head -5 ~/oci-cost-usage-report/oci_cost_usage_latest.csv
head -5 ~/oci-cost-usage-report/oci_cost_summary_latest.csv
```

Confirm the detail CSV has real values for `usage_start_utc`, `service`,
`compartment_name`, `resource_id`, `sku_part_number`, `computed_amount`,
`currency`. The wrapper also prints the computed-amount total; compare it with
OCI Console → Cost Analysis before automating.

## SharePoint upload

Set the Microsoft/SharePoint env vars, then drop `--no-upload`:

```bash
export MS_TENANT_ID=... MS_CLIENT_ID=... MS_CLIENT_SECRET=...
export SP_HOSTNAME=contoso.sharepoint.com SP_SITE_PATH=/sites/FinOps
export SP_LIBRARY_NAME=Documents SP_FOLDER_PATH=PowerBI/OCI   # folder must exist

./oci_cost_usage_to_sharepoint_v2.sh --days 7 --no-archive
```

The wrapper carries over the hardened Graph logic: `Sites.Selected`-aware site
resolution, library + folder validation (confirms it's a folder), 250 MB
simple-upload guard, retries on all calls, empty-report overwrite protection,
and the secret kept out of process arguments. For GCC High / DoD set
`GRAPH_HOST=graph.microsoft.us`, `LOGIN_HOST=login.microsoftonline.us`,
`GRAPH_SCOPE=https://graph.microsoft.us/.default`.

## Scheduling

Cloud Shell is not a durable scheduler (sessions time out). For recurring runs
use OCI Functions + Resource Scheduler, a small Compute VM with cron, or OCI
DevOps — and pull `MS_CLIENT_SECRET` from OCI Vault rather than an exported
variable.

## Disclaimer

Like `showusage.py`, this is a reporting aid. For authoritative figures use OCI
Cost Analysis and the official Cost & Usage Reports.
