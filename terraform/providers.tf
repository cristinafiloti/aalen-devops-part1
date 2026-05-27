terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # OPTIONAL: enable a remote backend once a storage account for state exists.
  # Until then, Terraform uses the local backend (terraform.tfstate on disk).
  #
  # backend "azurerm" {
  #   resource_group_name  = "tfstate-rg"
  #   storage_account_name = "tfstateXXXXXX"
  #   container_name       = "tfstate"
  #   key                  = "part1.terraform.tfstate"
  # }
}

provider "azurerm" {
  features {
    key_vault {
      # Required when destroying: purge_protection is disabled by default in
      # this lab project so that `terraform destroy` actually frees the name.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
