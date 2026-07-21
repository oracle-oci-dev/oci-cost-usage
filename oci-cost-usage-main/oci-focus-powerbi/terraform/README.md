# OCI Resource Manager deployment

Oracle's A-Team FOCUS article now supports deployment through OCI Resource
Manager. Create a stack from this directory, supply the values described in
`terraform.tfvars.example`, run **Plan**, then run **Apply**.

This stack expects a pre-built Function image in OCIR. Build and push
`../function` with Fn from OCI Cloud Shell first, then pass its immutable image
URI as `function_image`. The stack creates the bucket, Functions application,
Function, and least-privilege cross-tenancy policy. Create the daily Function
schedule afterward in the Functions console as described in the parent runbook.
