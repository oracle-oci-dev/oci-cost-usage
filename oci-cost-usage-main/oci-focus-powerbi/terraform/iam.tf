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
    "Define tenancy bling as ocid1.tenancy.oc1..aaaaaaaaned4fkpkisbwjlr56u7cj63lf3wffbilvqknstgtvzub7vhqkggq",
    "Endorse dynamic-group ${oci_identity_dynamic_group.focus_function.name} to read objects in tenancy bling"
  ]
}
