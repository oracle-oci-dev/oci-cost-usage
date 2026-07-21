resource "oci_functions_application" "focus" {
  compartment_id = var.compartment_ocid
  display_name   = var.application_name
  subnet_ids     = var.function_subnet_ocids
}

resource "oci_functions_function" "focus" {
  application_id                   = oci_functions_application.focus.id
  display_name                     = var.function_name
  image                            = var.function_image
  memory_in_mbs                    = 1024
  timeout_in_seconds               = 300
  detached_mode_timeout_in_seconds = 900
  config = {
    TARGET_BUCKET = oci_objectstorage_bucket.focus.name
  }
}
