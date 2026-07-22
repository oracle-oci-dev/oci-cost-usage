# OCI Resource Manager deployment

Oracle's A-Team FOCUS article now supports deployment through OCI Resource
Manager. Create a stack from this directory, supply the values described in
`terraform.tfvars.example`, run **Plan**, then run **Apply**.

This stack expects a pre-built Function image in OCIR. Build and push
`../function` with Fn from OCI Cloud Shell first, then pass its immutable image
URI as `function_image`. The stack creates the bucket, Functions application,
Function, and least-privilege cross-tenancy policy. Create the daily Function
schedule afterward in the Functions console as described in the parent runbook.

To also deploy the optional weekly Object Storage PAR / Power BI publisher,
build and push `../delivery` the same way and set `delivery_function_image`.
This creates a second Function in the same application plus its own dynamic
group and policy (`dg-oci-focus-delivery` / `policy-oci-focus-delivery`),
scoped only to the destination bucket — it never gets the `bling`-tenancy
endorsement the daily copier has. Leave `delivery_function_image` empty to
skip it entirely. Create its weekly schedule the same way, in the Functions
console, as described in the parent runbook's Step 12.
