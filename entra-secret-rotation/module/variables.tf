variable "application_object_id" {
  description = "Object ID of the Entra application (not the client ID)"
  type        = string
}

variable "display_name_prefix" {
  description = "Secret display name; the rotation date is appended"
  type        = string
  default     = "rotated"
}

variable "rotation_days" {
  description = "Days between rotations"
  type        = number
  default     = 90
}

variable "grace_days" {
  description = "Days a secret stays valid past its rotation date, so missed cron runs don't break anything"
  type        = number
  default     = 30
}

variable "owner_object_ids" {
  description = "Extra owners for the application, e.g. the rotator's service principal (Application.ReadWrite.OwnedBy only covers owned apps)"
  type        = set(string)
  default     = []
}
