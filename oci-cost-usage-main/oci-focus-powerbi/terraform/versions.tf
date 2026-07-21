terraform {
  required_version = ">= 1.6"
  required_providers {
    oci = { source = "oracle/oci", version = "~> 7.0" }
  }
}

provider "oci" {
  region = var.region
}
