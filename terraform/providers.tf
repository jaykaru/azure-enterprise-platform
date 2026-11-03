terraform {
  required_version = "~> 1.13.0"

  # Values are passed at init time with -backend-config (variables are not allowed here)
  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.2, < 5.0"
    }
  }
}

provider "azurerm" {
  features {}
}
