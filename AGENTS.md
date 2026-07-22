# AGENTS.md

## Project purpose

This repository exports OCI cost data for Power BI. The active production path
is `oci-cost-usage-main/oci-focus-powerbi/`: an OCI Function copies native
FOCUS reports to Object Storage, then an optional delivery job publishes a
weekly CSV to SharePoint.

## Important invariants

- Treat FOCUS data as authoritative. Preserve correction rows and provenance.
- All report-date logic is UTC.
- The SharePoint report is the previous completed UTC calendar week (Monday
  through Sunday). Do not publish it unless every daily manifest is `complete`.
- Never overwrite a published file with an incomplete or empty report.
- Keep OCI and Microsoft credentials out of source control, logs, and command
  history. Use OCI Vault/runtime secret injection in deployed workloads.

## Key files

- `oci-focus-powerbi/function/func.py`: OCI Function copier.
- `oci-focus-powerbi/delivery/focus_to_sharepoint.py`: weekly SharePoint job.
- `oci-focus-powerbi/powerbi/power-query-m.txt`: Power BI query; it must use
  the same published filename as the delivery job.
- `oci-focus-powerbi/terraform/`: bucket, Function, IAM, and logging setup.
- `cost-usage-exporter-powerbi-v2.0_TEST.sh`: standalone OCI Usage API exporter.

## Validation

Run from `oci-cost-usage-main/oci-focus-powerbi`:

```sh
python3 -m unittest discover -s function/tests -v
python3 -m unittest discover -s delivery/tests -v
```

Use `bash -n` for each shell exporter. Terraform validation requires provider
initialization first; do not run apply or contact OCI/Microsoft unless asked.

The `v1` and `v1.1` shell exporters are historical test scripts. Prefer
`cost-usage-exporter-powerbi-v2.0_TEST.sh` for standalone exports and keep any
future changes focused on the active FOCUS pipeline unless legacy compatibility
is explicitly requested.
