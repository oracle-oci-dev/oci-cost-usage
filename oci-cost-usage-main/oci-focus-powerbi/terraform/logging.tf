resource "oci_logging_log_group" "focus" {
  compartment_id = var.compartment_ocid
  display_name   = "oci-focus-powerbi"
  description    = "Log group reserved for OCI FOCUS pipeline operational logs"
}
