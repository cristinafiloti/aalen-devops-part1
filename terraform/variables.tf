###############################################################################
# variables.tf
# All values that can change between environments live here.
###############################################################################

variable "prefix" {
  description = "Short lowercase prefix used in every resource name. Must be globally unique enough for the storage account."
  type        = string
  default     = "aalenproj"

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.prefix))
    error_message = "Prefix must be 3-12 chars, lowercase letters or digits only."
  }
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "uaenorth"
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
  description = "SKU for the App Service Plan. B1 is the cheapest Linux SKU that supports custom containers and managed identity."
  type        = string
  default     = "B1"
}

variable "python_version" {
  description = "Python runtime version for the App Service."
  type        = string
  default     = "3.12"
}
