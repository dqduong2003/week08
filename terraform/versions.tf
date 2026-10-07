terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Remote state in Azure Blob Storage, so every GitHub Actions run (and the
  # destroy workflow) shares one state file. Partial configuration: the
  # storage account / container / key are passed by the workflow with
  # `terraform init -backend-config=...`, and authentication uses the same
  # GitHub OIDC token as the provider (ARM_USE_OIDC=true).
  backend "azurerm" {}
}

# Authentication comes entirely from environment variables set by the
# workflow (ARM_CLIENT_ID / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID /
# ARM_USE_OIDC) - no credentials live in this configuration.
provider "azurerm" {
  features {
    # This resource group exists only for this deployment. Enabling Azure
    # Monitor managed Prometheus on AKS creates data collection rules and
    # Prometheus rule groups inside it that Terraform does not manage, so let
    # `terraform destroy` delete the group together with those leftovers.
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
