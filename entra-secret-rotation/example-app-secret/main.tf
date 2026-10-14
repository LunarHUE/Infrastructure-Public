module "client_secret" {
  source = "../module"

  application_object_id = var.application_object_id
  display_name_prefix   = var.secret_name
  rotation_days         = var.rotation_days
  owner_object_ids      = var.rotator_object_id == null ? [] : [var.rotator_object_id]
}

# A new Entra secret isn't accepted everywhere straight away.
resource "time_sleep" "propagate" {
  create_duration = "${var.propagation_seconds}s"
  triggers        = { key_id = module.client_secret.key_id }
}

resource "kubernetes_secret_v1" "client_secret" {
  metadata {
    name      = var.secret_name
    namespace = var.namespace
  }
  data = {
    (var.secret_key) = module.client_secret.value
  }
  depends_on = [time_sleep.propagate]
}

# Changing a pod-template annotation rolls the deployment onto the new secret.
resource "kubernetes_annotations" "restart" {
  for_each = toset(var.restart_deployments)

  api_version = "apps/v1"
  kind        = "Deployment"
  metadata {
    name      = each.value
    namespace = var.namespace
  }
  template_annotations = {
    "entra-secret-rotation/key-id" = module.client_secret.key_id
  }
  force      = true
  depends_on = [kubernetes_secret_v1.client_secret]
}

# Keeps the old secret alive while pods roll. It references the secret
# directly, so create_before_destroy deletes the old one only after this.
resource "time_sleep" "drain" {
  create_duration = "${var.drain_seconds}s"
  triggers = {
    key_id  = module.client_secret.key_id
    restart = join(",", [for r in kubernetes_annotations.restart : r.id])
  }
}
