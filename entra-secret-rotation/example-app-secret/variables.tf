variable "application_object_id" {
  description = "Object ID of the Entra application whose client secret rotates"
  type        = string
}

variable "namespace" {
  description = "Namespace of the app that uses the secret"
  type        = string
}

variable "secret_name" {
  description = "Kubernetes Secret the app reads the client secret from"
  type        = string
}

variable "secret_key" {
  type    = string
  default = "client-secret"
}

variable "restart_deployments" {
  description = "Deployments in var.namespace to restart after a rotation"
  type        = list(string)
  default     = []
}

variable "rotation_days" {
  type    = number
  default = 90
}

variable "rotator_object_id" {
  description = "Rotator service principal object ID (rotator output), made an owner of the app"
  type        = string
  default     = null
}

variable "propagation_seconds" {
  description = "Wait after creating a secret before handing it to the app (Entra can take a minute)"
  type        = number
  default     = 60
}

variable "drain_seconds" {
  description = "Wait after restarting the app before deleting the old secret"
  type        = number
  default     = 120
}
