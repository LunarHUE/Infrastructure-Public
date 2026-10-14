resource "time_rotating" "this" {
  rotation_days = var.rotation_days
}

resource "azuread_application_password" "this" {
  application_id = "/applications/${var.application_object_id}"
  display_name   = "${var.display_name_prefix}-${formatdate("YYYYMMDD", time_rotating.this.rfc3339)}"
  end_date       = timeadd(time_rotating.this.rotation_rfc3339, "${var.grace_days * 24}h")

  rotate_when_changed = { rotation = time_rotating.this.id }

  # New secret first; the old one is deleted only after everything that
  # references this resource has been updated.
  lifecycle {
    create_before_destroy = true
  }
}

resource "azuread_application_owner" "this" {
  for_each = var.owner_object_ids

  application_id  = "/applications/${var.application_object_id}"
  owner_object_id = each.value
}
