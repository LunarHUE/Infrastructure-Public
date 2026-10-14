variable "kubeconfig_path" {
  type    = string
  default = "~/.kube/config"
}

variable "kube_context" {
  type    = string
  default = null
}

variable "namespace" {
  description = "Namespace for the rotator CronJob"
  type        = string
  default     = "secret-rotator"
}

variable "state_namespace" {
  description = "Namespace holding the rotated roots' state (kubernetes backend); created here"
  type        = string
  default     = "tofu-state"
}

variable "target_namespaces" {
  description = "Namespaces the rotated roots write to (app Secrets, Deployments); the rotator gets target_cluster_role there"
  type        = list(string)
  default     = []
}

variable "target_cluster_role" {
  type    = string
  default = "edit"
}

variable "schedule" {
  type    = string
  default = "23 4 * * *"
}

variable "repo_url" {
  description = "Git repo holding the roots to rotate"
  type        = string
}

variable "repo_ref" {
  type    = string
  default = "main"
}

variable "git_ssh_key_path" {
  description = "Deploy key for a private repo (SSH repo_url); null for a public HTTPS one"
  type        = string
  default     = null
}

variable "roots" {
  description = "Root directories in the repo to plan and apply, e.g. [\"rotation/minio\"]"
  type        = list(string)
}

variable "allowed_resource_types" {
  description = "Resource types the job may change; any other change in a plan blocks the apply"
  type        = list(string)
  default = [
    "time_rotating",
    "time_sleep",
    "azuread_application_password",
    "kubernetes_secret_v1",
    "kubernetes_annotations",
  ]
}

variable "tofu_version" {
  type    = string
  default = "1.13.1"
}

variable "image" {
  type    = string
  default = "alpine:3.22"
}

# Entra identity: an app with Application.ReadWrite.OwnedBy and a federated
# credential trusting this cluster's service account tokens (no secret).
variable "service_account_issuer" {
  description = "The cluster's service-account issuer URL. Entra must be able to fetch <issuer>/.well-known/openid-configuration and its JWKS."
  type        = string
}
