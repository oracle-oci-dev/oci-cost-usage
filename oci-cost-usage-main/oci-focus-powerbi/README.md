# OCI native FOCUS -> Object Storage -> PAR -> Power BI (v3)

v3 replaces the older Usage API extracts with an OCI Function that copies the
native FOCUS files Oracle already generates. It does not re-create cost
calculations or discard correction rows.

```text
Oracle-owned bling bucket (FOCUS Reports/YYYY/MM/DD/*.csv.gz)
  -> OCI Function (resource principal)
  -> private customer bucket (raw, csv, manifests)
  -> weekly stable CSV object + PAR URL
  -> Power BI Web connector
```

OCI generates cost reports every six hours, can delay data by up to 24 hours,
and may split a report into `-00001`, `-00002`, etc. files. Therefore the
function processes yesterday and the previous day by default. A missing source
partition is reported as pending (not as an invocation failure) and is retried
by the next rolling invocation.

## Contents

- `function/`: the deployable Python OCI Function and its tests.
- `terraform/`: bucket, Function application/function, dynamic group and IAM.
- `delivery/`: optional weekly Object Storage publisher and PAR creator,
  deployable as its own Function (`func.yaml`/`Dockerfile`) or run as a CLI.
- `powerbi/`: a starting Power Query query and data-model guidance.

## Deployment method

Use [DEPLOYMENT_INSTRUCTIONS.md](DEPLOYMENT_INSTRUCTIONS.md) as the production
runbook. It supports both OCI Cloud Shell/Fn deployment and OCI Resource
Manager. The `terraform/` directory is a Resource Manager-compatible stack for
teams that want OCI-managed Terraform state.

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

The Function accepts the native `.csv.gz` packages plus `.zip` and plain `.csv`
packages handled by Oracle's reference copier. CSV content is decompressed
through a temporary file in chunks, then uploaded with the OCI SDK upload
manager, which uses multipart upload when necessary. The raw package is also
retained. Before either destination is written, the function checks
for key FOCUS columns (`BillingAccountId`, `BilledCost`, and
`ChargePeriodStart`). Any source, decompression, validation, or manifest failure
fails the invocation; an absent source date is the one intentional exception and
is returned in `pending_dates` for the next rolling run.

## Daily scheduling

Schedule a daily Function invocation at **04:00 UTC**, with the default empty
request body, using the OCI Functions Console's **Create schedule** flow. OCI
Resource Scheduler invokes scheduled functions in detached mode. After creating
the schedule, copy its OCID and use the scheduler-principal policy from the
Oracle A-Team article:

```text
Allow any-user to manage functions-family in tenancy where all {
  request.principal.type='resourceschedule',
  request.principal.id='<schedule_ocid>'
}
```

The schedule is deliberately left out of Terraform because the OCI provider's
generic Resource Scheduler schema does not cleanly express the Functions-console
workflow. The deployed Function sets a 900-second detached timeout; increase it
only after measuring real report partition sizes.

## Oracle A-Team alignment

This implementation follows Oracle's A-Team FOCUS export pattern: resource
principal authentication, the `bling` reporting namespace, the tenancy OCID as
the source bucket, the `FOCUS Reports/YYYY/MM/DD` prefix, daily scheduling, and
the `usage-report` cross-tenancy endorsement. It deliberately adds streaming
decompression, safe ZIP extraction, validation, idempotency, and manifests for
production operation. See the [Oracle A-Team article](https://www.ateam-oracle.com/automating-the-export-of-oci-finops-open-cost-and-usage-specification-focus-reports-to-object-storage).

## Object Storage PAR and Power BI

The optional delivery job combines the previous completed UTC calendar week and
writes these stable objects to the same private Object Storage bucket:

```text
powerbi/oci_focus_previous_week.csv
powerbi/oci_focus_manifest.json
powerbi/oci_focus_previous_week.par.json
```

It fails closed unless all seven daily copier manifests are complete. The CSV is
uploaded with the OCI SDK upload manager, so large reports use multipart upload.
The PAR grants time-bound read access to only
`powerbi/oci_focus_previous_week.csv`; because the object name is stable, the
same PAR URL keeps working when later weekly runs overwrite that object.

`delivery/focus_to_sharepoint.py` exposes both an OCI Function handler and a CLI
entry point around the same `run()` logic:

- **As a Function (production):** deployed as a second Function in the same
  `oci-focus-powerbi` app (`delivery/func.yaml`, `delivery/Dockerfile`), on its
  own weekly schedule, under its own dynamic group
  (`dg-oci-focus-delivery`) and least-privilege policy
  (`policy-oci-focus-delivery`) that is separate from the daily copier's. This
  is required because `oci.auth.signers.get_resource_principals_signer()` only
  resolves inside a resource-principal-eligible OCI service — it does not work
  from Cloud Shell or a laptop. See [DEPLOYMENT_INSTRUCTIONS.md](DEPLOYMENT_INSTRUCTIONS.md)
  Step 12 for the exact commands, or `terraform/` with `delivery_function_image`
  set.
- **As a CLI (manual/testing):** from anywhere with an active resource or
  instance principal, run `python focus_to_sharepoint.py --week-start
  2026-07-13`. Omit `--week-start` to publish the previous completed UTC week.
  Use `--rotate-par` only when you need to issue a new URL before the stored
  PAR is near expiry.

Required environment variables (both modes):

```text
TARGET_BUCKET TARGET_NAMESPACE(optional)
PAR_TTL_DAYS(optional, default 90)
OCI_REGION or OBJECT_STORAGE_ENDPOINT(optional if the SDK endpoint is available)
```

Install `delivery/requirements.txt` before running either mode.

Both modes print/return a JSON manifest containing `powerbi_url`. In Power BI
Desktop, create a text parameter named `OCI_FOCUS_PAR_URL`, paste that URL,
then use `powerbi/power-query-m.txt`. Treat the PAR URL like a secret: anyone
who has it can read the weekly CSV until the PAR expires or is deleted. Cost
values should be fixed decimals and dates UTC. Do not remove correction rows.
Reconcile `lineItem/iscorrection` and `lineItem/backReference` in a measure if
a netted presentation is required.

## Verify before production

```bash
python3 -m unittest discover -s function/tests -v
python3 -m unittest discover -s delivery/tests -v
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
