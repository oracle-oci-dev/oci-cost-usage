# OCI native FOCUS → Object Storage → SharePoint → Power BI (v3)

v3 replaces the older Usage API extracts with an OCI Function that copies the
native FOCUS files Oracle already generates. It does not re-create cost
calculations or discard correction rows.

```text
Oracle-owned bling bucket (FOCUS Reports/YYYY/MM/DD/*.csv.gz)
  -> OCI Function (resource principal)
  -> private customer bucket (raw, csv, manifests)
  -> optional SharePoint stable file
  -> Power BI
```

OCI generates cost reports every six hours, can delay data by up to 24 hours,
and may split a report into `-00001`, `-00002`, etc. files. Therefore the
function processes yesterday and the previous day by default, lists every gzip
file in each date partition, and is safe to replay.

## Contents

- `function/`: the deployable Python OCI Function and its tests.
- `terraform/`: bucket, Function application/function, dynamic group and IAM.
- `delivery/`: optional separate SharePoint publisher.
- `powerbi/`: a starting Power Query query and data-model guidance.

## Deployment method

Use [DEPLOYMENT_INSTRUCTIONS.md](DEPLOYMENT_INSTRUCTIONS.md) as the production
runbook. It uses OCI Cloud Shell and Fn Project CLI only; no laptop tooling is
required. The `terraform/` directory is retained as an optional infrastructure
reference, not as the primary deployment path.

## Terraform reference deployment

1. Build and push `function/` as an OCI Functions image (or use your normal
   Fn/OCIR deployment workflow). Set `terraform.function_image` to that OCIR
   image URI.
2. In `terraform/`, supply your home region, tenancy and compartment OCIDs, and
   Function subnet OCIDs. The subnet needs a Service Gateway or NAT/Internet
   Gateway so the Function can reach Object Storage.
3. Run `terraform init`, then `terraform apply`. Deploy the Function in the
   tenancy home region. It gets a 300-second timeout and 1 GB memory by default.
   Raise memory after observing actual partition sizes.
4. Confirm the IAM policy produced by Terraform. The root-compartment `Endorse`
   statement for Oracle's `bling` tenancy is mandatory. Do not remove it.
5. Make a manual two-day invocation before scheduling:

   ```json
   {"start_date":"2026-07-18","end_date":"2026-07-19","force":false}
   ```

   The empty body has the same two-day window. `force: true` reprocesses files
   even when the source ETag and size match existing objects.

The target-bucket layout is stable:

```text
focus/raw/YYYY/MM/DD/<original>.csv.gz
focus/csv/YYYY/MM/DD/<original>.csv
manifests/YYYY/MM/DD.json
```

The CSV is decompressed through a temporary file in chunks, then uploaded with
the OCI SDK upload manager, which uses multipart upload when necessary. The raw
gzip is also retained. Before either destination is written, the function checks
for key FOCUS columns (`BillingAccountId`, `BilledCost`, and
`ChargePeriodStart`). Any source, decompression, validation, or manifest failure
fails the complete invocation; it never reports a partial run as successful.

## Daily scheduling

Schedule a daily Function invocation at **04:00 UTC**, with the default empty
request body, using the OCI Functions Console's **Create schedule** flow. OCI
Resource Scheduler invokes scheduled functions in detached mode. After creating
the schedule, copy its OCID and create a scheduler dynamic group:

```text
ALL {resource.type='resourceschedule', resource.id='<schedule_ocid>'}
```

Then grant that group permission to invoke Functions:

```text
Allow dynamic-group <focus-scheduler-dg> to manage functions-family in tenancy
```

The schedule is deliberately left out of Terraform because the OCI provider's
generic Resource Scheduler schema does not cleanly express the Functions-console
workflow. The deployed Function sets a 900-second detached timeout; increase it
only after measuring real report partition sizes.

## SharePoint and Power BI

The optional delivery job combines the current month’s CSV partitions and writes
`oci_focus_current_month.csv` plus `oci_focus_manifest.json` to SharePoint. Run
it only after one or more daily manifests are complete. It uses its own resource
principal and needs the same read permission on the target bucket.

Required environment variables:

```text
TARGET_BUCKET TARGET_NAMESPACE(optional)
MS_TENANT_ID MS_CLIENT_ID MS_CLIENT_SECRET
SP_HOSTNAME SP_SITE_PATH SP_LIBRARY_NAME SP_FOLDER_PATH(optional)
```

Install `delivery/requirements.txt`, then run
`python focus_to_sharepoint.py --month 2026-07`. For production, store the
Microsoft secret in OCI Vault and inject it at runtime. The current publisher
uses Graph's simple-upload API and refuses payloads over 250 MB; add an upload
session implementation before publishing a larger month.

In Power BI Desktop, use the SharePoint Folder connector and adapt
`powerbi/power-query-m.txt`. Cost values should be fixed decimals and dates UTC.
Do not remove correction rows. Reconcile `lineItem/iscorrection` and
`lineItem/backReference` in a measure if a netted presentation is required.

## Verify before production

```bash
python3 -m unittest discover -s function/tests -v
```

Then check one manual run: every source gzip has both a `raw` and `csv` target,
all split files appear, the manifest is `complete`, a forced replay stays
consistent, and `BilledCost` totals are compared by currency with OCI Cost
Analysis. Run this for seven days before enabling long-term scheduling.

## References

This is based on Oracle's [native FOCUS report documentation](https://docs.oracle.com/en-us/iaas/Content/Billing/Concepts/costusagereportsoverview.htm),
the [A-Team FOCUS copier](https://www.ateam-oracle.com/automating-the-export-of-oci-finops-open-cost-and-usage-specification-focus-reports-to-object-storage),
and Oracle's [FOCUS Converter documentation](https://docs.oracle.com/en-us/iaas/Content/Functions/Tasks/functions_pbf_catalog_cost_reports_focus_converter.htm).
Use the converter only for historical proprietary-report conversion or a
selected date range; recurring v3 copies OCI's native FOCUS output directly.
