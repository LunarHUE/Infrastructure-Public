output "value" {
  value     = azuread_application_password.this.value
  sensitive = true
}

output "key_id" {
  value = azuread_application_password.this.key_id
}

output "end_date" {
  value = azuread_application_password.this.end_date
}
