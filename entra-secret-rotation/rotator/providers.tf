terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azuread    = { source = "hashicorp/azuread", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.30" }
  }
}

provider "azuread" {}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}
