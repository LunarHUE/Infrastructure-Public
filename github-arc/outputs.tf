output "runs_on_labels" {
  description = "All runner classes; use any as the `runs-on` value in GitHub Actions workflows."
  value       = sort(keys(var.runner_classes))
}

output "namespace" {
  value = kubernetes_namespace_v1.arc.metadata[0].name
}
