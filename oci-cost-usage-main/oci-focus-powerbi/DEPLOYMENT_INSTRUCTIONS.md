# OCI FOCUS v3: Cloud Shell-Only Deployment

This is the only deployment runbook to use for this project. Every command is
run inside **OCI Cloud Shell**. Do not install Docker, Terraform, Python, OCI
CLI, or Fn on a Mac, Windows PC, or other laptop.

```text
OCI Billing FOCUS reports in Oracle's bling bucket
  -> OCI Function deployed from Cloud Shell
  -> private bucket in your tenancy
  -> raw gzip copies, CSV copies, and manifests
  -> optional SharePoint and Power BI delivery later
```

The Function reads Oracle's already-generated FOCUS reports. It does not use
the OCI Usage API and does not calculate or remove correction rows.

## Before you start

You need an OCI user that can manage these resources in the tenancy home region:

- Object Storage buckets and objects in the target compartment.
- Functions applications and functions in the target compartment.
- Dynamic groups and IAM policies at tenancy scope.
- Resource schedules at tenancy scope.
- OCI Container Registry repositories in the target compartment.

If you do not have these permissions, give this document to your OCI
administrator. Do not attempt to use a more powerful account without approval.

The pipeline must be deployed in the tenancy **home region**. In OCI Console,
open your tenancy details and record the home-region identifier, such as
`us-ashburn-1`.

Also confirm that **Billing & Cost Management > Cost and Usage Reports** shows
FOCUS report folders. There must be at least one completed usage date to test.

## 1. Open Cloud Shell and bring in this project

In OCI Console, click the **Cloud Shell** icon in the top bar. Cloud Shell
already includes OCI CLI, Docker, and Fn Project CLI, and is pre-authenticated
to the tenancy selected in the Console.

Check the bundled tools:

```bash
oci --version
docker --version
fn version
```

Fetch the project into Cloud Shell. The recommended approach is cloning the
repository from its remote Git URL:

```bash
cd ~
git clone <YOUR-GIT-REPOSITORY-URL> oci-cost-usage
cd ~/oci-cost-usage/oci-focus-powerbi
```

If the code is not yet in a Git repository, use Cloud Shell's upload feature to
upload a project archive, extract it under your Cloud Shell home directory, and
then change into `oci-focus-powerbi`. Cloud Shell has 5 GB of encrypted,
persistent home-directory storage, so the project remains there between Cloud
Shell sessions.

Run the project tests in Cloud Shell:

```bash
python3 -m unittest discover -s function/tests -v
```

All three tests must pass before deployment.

## 2. Set the deployment values in Cloud Shell

In the commands below, replace every `REPLACE_ME` value. Do not paste an auth
token into a file or commit it to Git.

```bash
export FOCUS_REGION='us-ashburn-1'
export REGION_KEY='iad'
export COMPARTMENT_OCID='ocid1.compartment.oc1..REPLACE_ME'
export TENANCY_OCID='ocid1.tenancy.oc1..REPLACE_ME'
export FUNCTION_SUBNET_OCID='ocid1.subnet.oc1.iad.REPLACE_ME'

export APP_NAME='oci-focus-powerbi'
export FUNCTION_NAME='oci-focus-exporter'
export FOCUS_BUCKET='oci-focus-powerbi'
export FUNCTION_DG='dg-oci-focus-exporter'
export FUNCTION_POLICY='policy-oci-focus-exporter'
```

Get the Object Storage namespace from the active Cloud Shell tenancy:

```bash
export OCI_NAMESPACE="$(oci os ns get --query data --raw-output)"
printf '%s\n' "${OCI_NAMESPACE}"
```

Set the Oracle Container Registry host and project path:

```bash
export OCIR_HOST="${REGION_KEY}.ocir.io"
export OCIR_PROJECT='oci-focus'
```

The `REGION_KEY` is not always obvious. For example, Ashburn is `iad` and
Phoenix is `phx`. Verify it from the region/registry information in OCI Console
before proceeding.

## 3. Create Function network access

The Function needs a private subnet with a route to Oracle services.

If you already have a Functions subnet, use its OCID as `FUNCTION_SUBNET_OCID`
and verify both conditions below. Otherwise, have the network administrator
create one in the home region.

Required networking:

```text
Private regional subnet
  + Service Gateway
  + route: All <region> Services in Oracle Services Network -> Service Gateway
  + egress TCP 443 allowed by security list or NSG
```

A NAT Gateway is not required for this pipeline because it reads and writes
Object Storage through the Oracle Services Network. Do not use a public subnet
for the Function solely to avoid adding the Service Gateway route.

## 4. Create the destination Object Storage bucket

Run this in Cloud Shell:

```bash
oci os bucket create \
  --compartment-id "${COMPARTMENT_OCID}" \
  --namespace "${OCI_NAMESPACE}" \
  --name "${FOCUS_BUCKET}" \
  --public-access-type NoPublicAccess \
  --versioning Enabled \
  --auto-tiering InfrequentAccess
```

If OCI reports that the bucket already exists, inspect it instead of creating a
second bucket:

```bash
oci os bucket get \
  --namespace "${OCI_NAMESPACE}" \
  --bucket-name "${FOCUS_BUCKET}"
```

The bucket must be private. The Function will create these paths inside it:

```text
focus/raw/YYYY/MM/DD/<source>.csv.gz
focus/csv/YYYY/MM/DD/<source>.csv
manifests/YYYY/MM/DD.json
```

## 5. Create the Container Registry repository and auth token

In OCI Console, open **Developer Services > Container Registry** in the home
region and create a private repository named:

```text
oci-focus/oci-focus-exporter
```

Then generate a Registry auth token:

1. Open the profile menu in OCI Console.
2. Select **User settings > Auth tokens**.
3. Select **Generate token**.
4. Copy the token immediately. OCI does not show it again.

Back in Cloud Shell, log in to OCI Registry:

```bash
docker login "${OCIR_HOST}"
```

When prompted:

```text
Username: <your-tenancy-name>/<your-OCI-username>
Password: the auth token just generated
```

The tenancy name in this login is not necessarily the Object Storage namespace.
Use the exact tenancy name shown in OCI Console. Do not use your regular OCI
password as the Docker password.

## 6. Configure Fn in Cloud Shell and deploy the Function

Select the home-region Fn context and configure it:

```bash
fn list context
fn use context "${FOCUS_REGION}"
fn update context oracle.compartment-id "${COMPARTMENT_OCID}"
fn update context registry "${OCIR_HOST}/${OCI_NAMESPACE}/${OCIR_PROJECT}"
```

Verify the context before creating anything:

```bash
fn list context
```

Create the Functions application. This command uses the private subnet prepared
in Step 3:

```bash
fn create app "${APP_NAME}" \
  --annotation oracle.com/oci-subnet-ids="[\"${FUNCTION_SUBNET_OCID}\"]"
```

If the application already exists, inspect it and confirm the subnet instead:

```bash
fn list apps
```

Deploy from the Function source directory. `fn deploy` builds the Linux image,
pushes it to OCIR, creates or updates the Function definition, and associates
the image with the Function:

```bash
cd ~/oci-cost-usage/oci-focus-powerbi/function
fn deploy --app "${APP_NAME}"
```

Set the destination bucket as Function configuration:

```bash
fn config function "${APP_NAME}" "${FUNCTION_NAME}" \
  TARGET_BUCKET "${FOCUS_BUCKET}"
```

Set the detached timeout to 900 seconds. This is used by the daily schedule;
the Function's normal synchronous timeout remains 300 seconds:

```bash
export FUNCTION_OCID="$(fn inspect function "${APP_NAME}" "${FUNCTION_NAME}" | jq -r '.id')"

oci fn function update \
  --function-id "${FUNCTION_OCID}" \
  --detached-mode-timeout-in-seconds 900
```

Confirm the Function exists and save its OCID somewhere safe:

```bash
oci fn function get --function-id "${FUNCTION_OCID}"
printf 'Function OCID: %s\n' "${FUNCTION_OCID}"
```

## 7. Create the Function's dynamic group and IAM policy

The Function must access two locations:

- Read Oracle's FOCUS reporting bucket in tenancy `bling`.
- Write only to your target bucket.

Create the Function dynamic group in Cloud Shell:

```bash
oci iam dynamic-group create \
  --compartment-id "${TENANCY_OCID}" \
  --name "${FUNCTION_DG}" \
  --description 'OCI native FOCUS copier Function resource principal' \
  --matching-rule "ALL {resource.type = 'fnfunc', resource.id = '${FUNCTION_OCID}'}"
```

Create a file named `focus-function-policy.json` in the Cloud Shell editor with
this JSON array. Replace nothing in the `bling` OCID; replace only the shell
variables with their actual values before saving:

```json
[
  "Allow dynamic-group dg-oci-focus-exporter to read objectstorage-namespaces in tenancy",
  "Allow dynamic-group dg-oci-focus-exporter to manage objects in compartment id <COMPARTMENT_OCID> where target.bucket.name = 'oci-focus-powerbi'",
  "Define tenancy bling as ocid1.tenancy.oc1..aaaaaaaaned4fkpkisbwjlr56u7cj63lf3wffbilvqknstgtvzub7vhqkggq",
  "Endorse dynamic-group dg-oci-focus-exporter to read objects in tenancy bling"
]
```

Create the policy at tenancy scope:

```bash
oci iam policy create \
  --compartment-id "${TENANCY_OCID}" \
  --name "${FUNCTION_POLICY}" \
  --description 'Allow the OCI native FOCUS copier to read bling and write its target bucket' \
  --statements file://focus-function-policy.json
```

The policy names in the JSON must exactly match your actual dynamic-group and
bucket names. If you chose different names, edit the JSON accordingly.

Wait approximately 15 minutes after creating or changing the dynamic group or
policy. Resource-principal permissions are cached; an immediate test can fail
even when the policy is correct.

## 8. Run a manual one-day test

Choose a recent UTC date that exists under OCI Billing FOCUS reports. Replace
the sample date with that date.

```bash
oci --read-timeout 330 fn function invoke \
  --function-id "${FUNCTION_OCID}" \
  --file response.json \
  --body '{"start_date":"2026-07-18","end_date":"2026-07-18","force":false}'
```

Read the response:

```bash
cat response.json
```

Expected result:

```json
{
  "status": "complete",
  "dates": ["YYYY-MM-DD"],
  "manifests": ["manifests/YYYY/MM/DD.json"]
}
```

If the result is an authorization failure, do not weaken the IAM policy. Check
the Function's home region, Service Gateway route, Function OCID in the dynamic
group, bucket name in the policy, `bling` endorsement, and IAM propagation time.

## 9. Validate the data in the destination bucket

Replace the sample date in every prefix below with the test date.

```bash
oci os object list \
  --namespace-name "${OCI_NAMESPACE}" \
  --bucket-name "${FOCUS_BUCKET}" \
  --prefix 'focus/csv/2026/07/18/'
```

```bash
oci os object list \
  --namespace-name "${OCI_NAMESPACE}" \
  --bucket-name "${FOCUS_BUCKET}" \
  --prefix 'focus/raw/2026/07/18/'
```

```bash
oci os object get \
  --namespace-name "${OCI_NAMESPACE}" \
  --bucket-name "${FOCUS_BUCKET}" \
  --name 'manifests/2026/07/18.json' \
  --file manifest.json

cat manifest.json
```

Confirm every source `.csv.gz` has both a raw gzip object and a CSV object.
Confirm all split files (`-00001`, `-00002`, and so on) exist. The manifest
must say `"status": "complete"`.

Then verify replay behavior:

```bash
oci --read-timeout 330 fn function invoke \
  --function-id "${FUNCTION_OCID}" \
  --file replay.json \
  --body '{"start_date":"2026-07-18","end_date":"2026-07-18","force":true}'
```

Do not create the schedule until both manual runs succeed.

## 10. Create the daily schedule

OCI Functions schedules are backed by OCI Resource Scheduler. The current CLI
Resource Scheduler interface exposes generic start/stop actions, so use the
OCI Functions schedule page for this specific Function workflow. You are still
working entirely within OCI; no local machine is used.

1. In OCI Console, open **Developer Services > Functions > Applications**.
2. Select `oci-focus-powerbi`, then `oci-focus-exporter`.
3. Choose **More actions > Create schedule**.
4. Create a daily schedule at **04:00 UTC**.
5. Leave the request body empty; the Function automatically reprocesses
   yesterday and the prior day.
6. Create the schedule and copy its OCID.

Back in Cloud Shell, create the scheduler dynamic group. Replace
`<SCHEDULE_OCID>`:

```bash
export SCHEDULE_DG='dg-oci-focus-scheduler'
export SCHEDULE_OCID='ocid1.resourceschedule.oc1.REPLACE_ME'

oci iam dynamic-group create \
  --compartment-id "${TENANCY_OCID}" \
  --name "${SCHEDULE_DG}" \
  --description 'OCI Resource Scheduler principal for the FOCUS copier' \
  --matching-rule "ALL {resource.type='resourceschedule', resource.id='${SCHEDULE_OCID}'}"
```

Create `focus-scheduler-policy.json` in the Cloud Shell editor:

```json
[
  "Allow dynamic-group dg-oci-focus-scheduler to manage functions-family in tenancy"
]
```

Create the policy:

```bash
oci iam policy create \
  --compartment-id "${TENANCY_OCID}" \
  --name 'policy-oci-focus-scheduler' \
  --description 'Allow the FOCUS schedule to invoke OCI Functions' \
  --statements file://focus-scheduler-policy.json
```

Wait for IAM propagation, then leave the schedule enabled.

## 11. Operate the pipeline

For the first seven days, check the Function invocation and each manifest daily.
Confirm that the two rolling dates complete and compare `BilledCost` by currency
with OCI Cost Analysis. Do not delete correction rows; OCI FOCUS reports add
corrections as additional records.

Use OCI Console Function logs and invocation details for failures. Increase the
memory or detached timeout only after observing actual report size and runtime.

## 12. Optional SharePoint and Power BI delivery

Do this only after the FOCUS copy workload has run successfully for seven days.
The SharePoint publisher is a separate workload:

`delivery/focus_to_sharepoint.py`

Run it from a separate, scheduled OCI workload with its Microsoft credentials
stored in OCI Vault. Never put `MS_CLIENT_SECRET` in Cloud Shell command
history, source control, or Function configuration.

Use the SharePoint Folder connector in Power BI and start from:

`powerbi/power-query-m.txt`

Set costs to fixed decimal, period fields to UTC datetime, and preserve source
file and correction-row provenance.

## References

- [OCI Functions Cloud Shell quickstart](https://docs.oracle.com/en-us/iaas/Content/developer/functions/func-setup-cs/01-summary.htm)
- [OCI Cloud Shell](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cloudshellintro.htm)
- [OCI FOCUS cost reports](https://docs.oracle.com/en-us/iaas/Content/Billing/Concepts/costusagereportsoverview.htm)
- [OCI Functions resource principals](https://docs.oracle.com/iaas/Content/Functions/Tasks/functionsaccessingociresources.htm)
- [OCI Function scheduling](https://docs.oracle.com/en-us/iaas/Content/Functions/Tasks/functionsschedulingfunctions-about.htm)
