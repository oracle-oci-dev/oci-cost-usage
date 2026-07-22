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

# Optional: the weekly Object Storage PAR + Power BI publisher (delivery/focus_to_sharepoint.py).
# Deployed as a second function in the same app so it gets its own least-privilege
# dynamic group and PAR-creation policy instead of borrowing the daily copier's identity.
resource "oci_functions_function" "delivery" {
  count                            = var.delivery_function_image == "" ? 0 : 1
  application_id                   = oci_functions_application.focus.id
  display_name                     = var.delivery_function_name
  image                            = var.delivery_function_image
  memory_in_mbs                    = 1024
  timeout_in_seconds               = 300
  detached_mode_timeout_in_seconds = 900
  config = {
    TARGET_BUCKET = oci_objectstorage_bucket.focus.name
  }
}
