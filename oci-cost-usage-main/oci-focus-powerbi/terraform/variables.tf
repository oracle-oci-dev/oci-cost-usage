variable "region" { type = string }
variable "tenancy_ocid" { type = string }
variable "compartment_ocid" { type = string }
variable "function_subnet_ocids" { type = list(string) }
variable "function_image" {
  type        = string
  description = "OCIR image URI built from ../function, for example iad.ocir.io/<namespace>/oci-focus-exporter:0.1.0"
}
variable "bucket_name" {
  type    = string
  default = "oci-focus-powerbi"
}

variable "application_name" {
  type    = string
  default = "oci-focus-powerbi"
}

variable "function_name" {
  type    = string
  default = "oci-focus-exporter"
}

variable "delivery_function_image" {
  type        = string
  default     = ""
  description = "Pre-built OCIR image for delivery/focus_to_sharepoint.py, for example iad.ocir.io/<namespace>/oci-focus-delivery:0.1.0. Leave empty to skip deploying the optional weekly PAR/Power BI publisher."
}

variable "delivery_function_name" {
  type    = string
  default = "oci-focus-delivery"
}
