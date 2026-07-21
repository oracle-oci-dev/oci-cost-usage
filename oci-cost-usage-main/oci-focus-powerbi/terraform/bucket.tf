resource "oci_objectstorage_bucket" "focus" {
  compartment_id = var.compartment_ocid
  name           = var.bucket_name
  namespace      = data.oci_objectstorage_namespace.current.namespace
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"
  auto_tiering   = "InfrequentAccess"
}

data "oci_objectstorage_namespace" "current" {
  compartment_id = var.compartment_ocid
}
