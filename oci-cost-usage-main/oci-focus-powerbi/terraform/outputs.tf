output "focus_bucket" { value = oci_objectstorage_bucket.focus.name }
output "function_ocid" { value = oci_functions_function.focus.id }
output "function_application_ocid" { value = oci_functions_application.focus.id }
output "dynamic_group" { value = oci_identity_dynamic_group.focus_function.name }
output "delivery_function_ocid" { value = var.delivery_function_image == "" ? "" : oci_functions_function.delivery[0].id }
output "delivery_dynamic_group" { value = var.delivery_function_image == "" ? "" : oci_identity_dynamic_group.focus_delivery[0].name }
