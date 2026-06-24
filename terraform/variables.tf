###############################################################################
# variables.tf
###############################################################################

variable "prefix" {
  description = "Short lowercase prefix for every resource name."
  type        = string
  default     = "aalenproj"

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.prefix))
    error_message = "Prefix must be 3-12 chars, lowercase letters or digits only."
  }
}

variable "suffix" {
  description = <<-EOT
    4-character random suffix used in every globally-unique resource name
    (storage account, key vault, web app). For Part II, this is set to the
    same suffix that was generated during Part I, so that Terraform matches
    and updates the existing resources instead of creating new ones.
  EOT
  type    = string

  validation {
    condition     = can(regex("^[a-z0-9]{4}$", var.suffix))
    error_message = "Suffix must be exactly 4 lowercase letters/digits."
  }
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "westeurope"
}

variable "environment" {
  description = "Environment tag (dev/test/prod)."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag – student name / matriculation number."
  type        = string
  default     = "student@hs-aalen.de"
}

variable "app_service_sku" {
  description = "App Service Plan SKU. B1 is cheap and supports custom containers + MI."
  type        = string
  default     = "B1"
}

variable "python_version" {
  description = "Python runtime version on the Linux App Service."
  type        = string
  default     = "3.12"
}

variable "max_upload_mb" {
  description = "Maximum upload size in MB enforced by the application."
  type        = number
  default     = 10
}
