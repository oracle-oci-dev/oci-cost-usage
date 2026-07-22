resource "oci_identity_dynamic_group" "focus_function" {
  compartment_id = var.tenancy_ocid
  name           = "dg-oci-focus-exporter"
  description    = "Resource principal for the OCI native FOCUS copier"
  matching_rule  = "ALL {resource.type = 'fnfunc', resource.id = '${oci_functions_function.focus.id}'}"
}

resource "oci_identity_policy" "focus_function" {
  compartment_id = var.tenancy_ocid
  name           = "policy-oci-focus-exporter"
  description    = "Least-privilege Object Storage access for the native FOCUS copier"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.focus_function.name} to read objectstorage-namespaces in tenancy",
    "Allow dynamic-group ${oci_identity_dynamic_group.focus_function.name} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.focus.name}'",
    "Define tenancy usage-report as ocid1.tenancy.oc1..aaaaaaaaned4fkpkisbwjlr56u7cj63lf3wffbilvqknstgtvzub7vhqkggq",
    "Endorse dynamic-group ${oci_identity_dynamic_group.focus_function.name} to read objects in tenancy usage-report"
  ]
}

# Optional: identity for the weekly delivery function (delivery/focus_to_sharepoint.py).
# Kept separate from dg-oci-focus-exporter because this workload only needs read/write
# on the customer bucket plus PAR creation -- it must never get the bling endorsement.
resource "oci_identity_dynamic_group" "focus_delivery" {
  count          = var.delivery_function_image == "" ? 0 : 1
  compartment_id = var.tenancy_ocid
  name           = "dg-oci-focus-delivery"
  description    = "Resource principal for the weekly FOCUS Object Storage PAR / Power BI publisher"
  matching_rule  = "ALL {resource.type = 'fnfunc', resource.id = '${oci_functions_function.delivery[0].id}'}"
}

resource "oci_identity_policy" "focus_delivery" {
  count          = var.delivery_function_image == "" ? 0 : 1
  compartment_id = var.tenancy_ocid
  name           = "policy-oci-focus-delivery"
  description    = "Least-privilege Object Storage and PAR access for the weekly FOCUS Power BI publisher"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.focus_delivery[0].name} to read objectstorage-namespaces in tenancy",
    "Allow dynamic-group ${oci_identity_dynamic_group.focus_delivery[0].name} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.focus.name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.focus_delivery[0].name} to manage buckets in compartment id ${var.compartment_ocid} where all {target.bucket.name = '${oci_objectstorage_bucket.focus.name}', request.permission = 'PAR_MANAGE'}"
  ]
}
