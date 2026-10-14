terraform {
  required_version = ">= 1.6.0"

  # State in a Kubernetes Secret, so the rotator and your laptop share it.
  # Laptop: KUBE_CONFIG_PATH=~/.kube/config. Rotator: KUBE_IN_CLUSTER_CONFIG=true.
  backend "kubernetes" {
    secret_suffix = "example-app-secret" # unique per root
    namespace     = "tofu-state"
  }

  required_providers {
    azuread    = { source = "hashicorp/azuread", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.30" }
    time       = { source = "hashicorp/time", version = ">= 0.9" }
  }
}

provider "azuread" {}

# Uses KUBE_CONFIG_PATH locally and the pod's service account in the rotator.
provider "kubernetes" {}
