output "service_principal_object_id" {
  description = "Pass to each rotated root as rotator_object_id so the rotator owns the app"
  value       = azuread_service_principal.rotator.object_id
}

output "client_id" {
  value = azuread_application.rotator.client_id
}
