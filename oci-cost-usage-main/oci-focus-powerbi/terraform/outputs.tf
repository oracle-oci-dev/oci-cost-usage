output "focus_bucket" { value = oci_objectstorage_bucket.focus.name }
output "function_ocid" { value = oci_functions_function.focus.id }
output "function_application_ocid" { value = oci_functions_application.focus.id }
output "dynamic_group" { value = oci_identity_dynamic_group.focus_function.name }
