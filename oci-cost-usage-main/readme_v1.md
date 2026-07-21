# OCI Cost and Usage → SharePoint → Power BI

## What this workflow does

1. Runs in OCI Cloud Shell.
2. Calls the OCI Usage API using read-only operations.
3. Extracts cost and usage detail for a UTC date range.
4. Creates:
   - `oci_cost_usage_latest.csv`
   - `oci_cost_summary_latest.csv`
   - Optional timestamped archive files.
5. Uploads or overwrites those CSVs in a SharePoint document-library folder.
6. Power BI reads the stable `*_latest.csv` files.

## 1. OCI IAM permissions

This script calls the **Usage API** (`request-summarized-usages`), not the
downloadable cost-report CSVs in Oracle's `bling` bucket. Those are two
different resources with two different policies, and they are easy to confuse:

- **Usage API** (what this script uses): the resource is `usage-data`.

  ```text
  Allow group <your-group-name> to read usage-data in tenancy
  ```

  A dynamic group works too (for example, when the same logic later runs from
  an OCI Function with a resource principal):

  ```text
  Allow dynamic-group <your-dynamic-group> to read usage-data in tenancy
  ```

  Note: the OCI Console's Cost Analysis page documents a `usage-report` policy,
  but that governs the *saved-report* and downloadable-file features, which are
  a different resource. The programmatic Usage API call this script makes
  (`request_summarized_usages`) is authorized by `usage-data`. If your tenancy's
  policy design differs, adjust accordingly and test with a small `--no-upload`
  run first.

- **Downloadable cost/usage report files** (NOT used here): those live in an
  Oracle-owned Object Storage bucket and use a `usage-report` /
  `read objects` endorsement. You do not need this for this script.

If your tenancy uses identity domains, the group name may need to be
domain-qualified (for example, `'MyDomain'/MyGroup`).

## 2. Microsoft Entra app registration

Create an app registration for unattended uploads.

Recommended production approach:

- Microsoft Graph application permission: `Sites.Selected`
- **Two steps are required.** Granting `Sites.Selected` in Entra ID alone gives
  the app *no* access to any site. You must also make an explicit per-site
  grant via Graph:

  ```http
  POST https://graph.microsoft.com/v1.0/sites/{site-id}/permissions
  {
    "roles": ["write"],
    "grantedToIdentities": [
      { "application": { "id": "<app-client-id>", "displayName": "<app-name>" } }
    ]
  }
  ```

  Skipping this second step is the most common cause of a 403 when the script
  resolves the site. The script's error message calls this out explicitly.
- Admin consent is required for the application permission.

**The target folder (`SP_FOLDER_PATH`) must already exist** in the document
library. The upload endpoint does not reliably create missing parent folders,
so the script checks the folder up front and stops with a clear message if it
is absent. Transient network failures on the token, site, drive, folder, and
upload calls are retried automatically.

Broader but less restrictive alternatives include `Sites.ReadWrite.All` or
`Files.ReadWrite.All`. Use them only when your security team approves.

Create a client secret or, preferably for a hardened implementation, replace
the secret with certificate authentication.

## 3. Copy the script into Cloud Shell

```bash
chmod 700 oci_cost_usage_to_sharepoint.sh
```

## 4. Export settings

```bash
export MS_TENANT_ID='00000000-0000-0000-0000-000000000000'
export MS_CLIENT_ID='00000000-0000-0000-0000-000000000000'
export MS_CLIENT_SECRET='REPLACE_WITH_SECRET'

export SP_HOSTNAME='contoso.sharepoint.com'
export SP_SITE_PATH='/sites/FinOps'
export SP_LIBRARY_NAME='Documents'
export SP_FOLDER_PATH='PowerBI/OCI'   # must already exist in the library

# OCI auth in Cloud Shell is handled for you: Cloud Shell exports
# OCI_CLI_AUTH=instance_obo_user, OCI_CLI_CONFIG_FILE=/etc/oci/config,
# OCI_CLI_PROFILE=<region>, and OCI_CLI_TENANCY automatically, and the script
# honors all of them. You normally do NOT need to set OCI_AUTH, OCI_PROFILE, or
# the tenancy. Only set these if running outside Cloud Shell or overriding.
```

`OCI_AUTH` defaults to whatever `OCI_CLI_AUTH` is set to. In Cloud Shell that is
`instance_obo_user` (delegation-token auth), which the script handles via the
delegation token at `/etc/oci/delegation_token` using the SDK's
`InstancePrincipalsDelegationTokenSigner`. Outside Cloud Shell the script also
supports `security_token` (session-token profiles), `instance_principal`,
`resource_principal`, and default API-key profiles (`api_key` or empty). An
unrecognized value fails with a clear error. Extraction uses the OCI **Python
SDK**, which ships with the CLI, so no separate install is needed.

Do not save the Microsoft secret inside the script. Avoid placing it in shell
history. OCI Vault is the better long-term secret store.

### GCC High / DoD (US Government) tenants

If your SharePoint tenant is GCC High or DoD, the commercial Microsoft
endpoints will not work. Override them:

```bash
export GRAPH_HOST='graph.microsoft.us'
export LOGIN_HOST='login.microsoftonline.us'
export GRAPH_SCOPE='https://graph.microsoft.us/.default'
```

Also confirm cross-cloud egress from your OCI (OC2/OC3) Cloud Shell to the
government Graph endpoint is permitted. If it is blocked, download the CSVs
from Cloud Shell and let a Power BI gateway pick them up from SharePoint
instead.

## 5. Test locally without SharePoint upload

Run a small window first to confirm permissions, pagination, and output before
attempting any upload:

```bash
# In Cloud Shell, auth is already configured — just run:
./oci_cost_usage_to_sharepoint.sh --days 7 --no-upload --no-archive
```

Then inspect the raw response and the generated CSVs under
`$HOME/oci-cost-usage-report/`. If OCI returns zero rows for the window, the
script warns and still writes header-only CSVs.

## 6. Run the full workflow

```bash
./oci_cost_usage_to_sharepoint.sh --days 90
```

Or use an explicit range:

```bash
./oci_cost_usage_to_sharepoint.sh \
  --start 2026-01-01 \
  --end 2026-04-01
```

The end date is exclusive. `--days N` now returns exactly `N` calendar days
(today plus the preceding `N-1`), ending tomorrow-exclusive.

### Grouping dimensions, granularity, and pagination

- The default grouping is `["service","compartmentName","resourceId","skuPartNumber"]`.
  The script limits grouping to **4 dimensions** by default as a design choice
  for predictable response size and Power BI performance; this is enforced
  locally, not asserted as a hard API limit. Override with `GROUP_BY`, and raise
  `MAX_GROUPBY` if your tenancy accepts more and you need them. A bad dimension
  name or malformed JSON fails fast before any API call.
- Granularity is validated: `HOURLY` (≤ 24 hours), `DAILY` (≤ 90 days), or
  `MONTHLY` (≤ ~12 months). `TOTAL` is rejected because the API does not yet
  support it.
- `OCI_QUERY_TYPE` is validated against `COST`, `USAGE`, `USAGE_ONLY`,
  `CREDIT`, `EXPIREDCREDIT`, `ALLCREDIT` (case-insensitive).
- The Usage API aggregates server-side via `groupBy`. Extraction uses the OCI
  **Python SDK** (which ships with the OCI CLI, so it is already present in
  Cloud Shell) rather than the CLI, because the pagination token
  (`opc-next-page`) is returned in the HTTP response header — which the CLI does
  not expose on stdout. The SDK reads the token from the response object and
  follows every page, so large resource-level exports are captured in full
  rather than silently truncated after the first page. Extraction stops with an
  error (and uploads nothing) if it would exceed 200 pages or detects a repeated
  token.
- If extraction fails with an SDK import error, verify with
  `python3 -c 'import oci; print(oci.__version__)'`.
- Each Usage API call uses the SDK's `DEFAULT_RETRY_STRATEGY`
  (exponential backoff with jitter) to ride out transient throttling (429) and
  5xx responses. This degrades gracefully on older SDK builds that lack it.
- `resourceId` is a documented grouping dimension. `resourceName` is kept in the
  CSV when OCI returns it but may be blank for some services or charge types.

## 7. Connect Power BI

In Power BI Desktop:

1. Select **Get data**.
2. Select **SharePoint Folder**.
3. Enter the SharePoint site URL, such as:
   `https://contoso.sharepoint.com/sites/FinOps`
4. Filter `Folder Path` to the configured folder.
5. Filter `Name` to:
   - `oci_cost_usage_latest.csv`, or
   - `oci_cost_summary_latest.csv`.
6. Select the `Content` binary and combine/transform the CSV.
7. Publish the semantic model.

Use the stable `latest` filename for the primary report. The script overwrites
it on each run, preventing Power BI queries from depending on a changing
filename.

### Safety and archive behavior

- If OCI returns **zero rows**, the script will not overwrite the SharePoint
  Power BI source by default — it stops with an error so a transient permission
  or query problem can't wipe your usable data. Set `UPLOAD_EMPTY_REPORT=true`
  to override when an empty result is genuinely expected.
- Timestamped archive CSVs are kept **locally** by default but are **not**
  uploaded to SharePoint (a daily run would otherwise accumulate ~730 files/year
  in the library). Set `UPLOAD_ARCHIVE_TO_SHAREPOINT=true` if you want them in
  SharePoint, or `KEEP_LOCAL_ARCHIVE=false` / `--no-archive` to skip local
  archives entirely. Power BI only needs the two `*_latest.csv` files.
- The raw OCI API response (`oci_cost_usage_raw_*.json`) is deleted on exit by
  default, since it can contain more detailed billing metadata than the CSVs and
  would otherwise accumulate under a daily schedule. Set `KEEP_RAW_JSON=true` to
  retain it for audit or troubleshooting.

## 8. Scheduling limitation

OCI Cloud Shell is intended for interactive administration and is not a
dependable unattended scheduler; sessions time out and the ephemeral host is
reclaimed. For production automation, run the same logic from one of these:

- OCI Functions plus an OCI Scheduler / Resource Scheduler trigger
- OCI DevOps build pipeline
- A small OCI Compute instance with cron
- An external CI runner

A Cloud Shell test confirms permissions and output, but it should not be
treated as an always-on production host.

## Upload size

Microsoft Graph's simple upload (used here) supports files up to 250 MB. The
script checks each file and stops with a clear message if a detailed
resource-level 90-day export exceeds that. Above 250 MB you would need a
resumable upload session.

## CSV design

The detail CSV includes:

- Extract timestamp (UTC)
- Usage start/end
- Service
- Compartment name and OCID
- Resource name and OCID
- SKU name and part number
- Unit and currency
- Computed quantity
- Computed amount
- Attributed cost
- Subscription and correction metadata
- Tags as JSON

The summary CSV aggregates by date, service, compartment, currency, and unit.

Both CSVs are written with a UTF-8 BOM (`utf-8-sig`) so Power BI correctly
detects encoding on accented tag or compartment values.
