locals {
  service_account = "secret-rotator"
  graph_app_id    = "00000003-0000-0000-c000-000000000000"
  # Microsoft Graph application permission Application.ReadWrite.OwnedBy
  graph_app_rw_owned_by = "18a4783c-866b-4cc7-a460-3d5e5662c884"
}

# ── Entra identity ─────────────────────────────────────────────────────────
data "azuread_client_config" "current" {}

data "azuread_service_principal" "graph" {
  client_id = local.graph_app_id
}

resource "azuread_application" "rotator" {
  display_name = "secret-rotator"
  owners       = [data.azuread_client_config.current.object_id]

  required_resource_access {
    resource_app_id = local.graph_app_id
    resource_access {
      id   = local.graph_app_rw_owned_by
      type = "Role"
    }
  }
}

resource "azuread_service_principal" "rotator" {
  client_id = azuread_application.rotator.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

# Admin consent for the Graph permission.
resource "azuread_app_role_assignment" "graph" {
  app_role_id         = local.graph_app_rw_owned_by
  principal_object_id = azuread_service_principal.rotator.object_id
  resource_object_id  = data.azuread_service_principal.graph.object_id
}

resource "azuread_application_federated_identity_credential" "rotator" {
  application_id = azuread_application.rotator.id
  display_name   = "k8s-${var.namespace}-${local.service_account}"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = var.service_account_issuer
  subject        = "system:serviceaccount:${var.namespace}:${local.service_account}"
}

# ── Kubernetes ─────────────────────────────────────────────────────────────
resource "kubernetes_namespace_v1" "rotator" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_namespace_v1" "state" {
  metadata {
    name = var.state_namespace
  }
}

resource "kubernetes_service_account_v1" "rotator" {
  metadata {
    name      = local.service_account
    namespace = kubernetes_namespace_v1.rotator.metadata[0].name
  }
}

# The kubernetes backend keeps state in Secrets and locks with Leases.
resource "kubernetes_role_v1" "state" {
  metadata {
    name      = "tofu-state"
    namespace = kubernetes_namespace_v1.state.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
    verbs      = ["get", "list", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "state" {
  metadata {
    name      = "secret-rotator"
    namespace = kubernetes_namespace_v1.state.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.state.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.rotator.metadata[0].name
    namespace = kubernetes_namespace_v1.rotator.metadata[0].name
  }
}

resource "kubernetes_role_binding_v1" "target" {
  for_each = toset(var.target_namespaces)

  metadata {
    name      = "secret-rotator"
    namespace = each.value
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = var.target_cluster_role
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.rotator.metadata[0].name
    namespace = kubernetes_namespace_v1.rotator.metadata[0].name
  }
}

resource "kubernetes_config_map_v1" "script" {
  metadata {
    name      = "secret-rotator"
    namespace = kubernetes_namespace_v1.rotator.metadata[0].name
  }
  data = {
    "rotate.sh" = file("${path.module}/rotate.sh")
  }
}

resource "kubernetes_secret_v1" "git_ssh" {
  count = var.git_ssh_key_path != null ? 1 : 0

  metadata {
    name      = "secret-rotator-git"
    namespace = kubernetes_namespace_v1.rotator.metadata[0].name
  }
  data = {
    id_key = file(var.git_ssh_key_path)
  }
}

resource "kubernetes_cron_job_v1" "rotator" {
  metadata {
    name      = "secret-rotator"
    namespace = kubernetes_namespace_v1.rotator.metadata[0].name
  }
  spec {
    schedule                      = var.schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5
    job_template {
      metadata {}
      spec {
        backoff_limit           = 0
        active_deadline_seconds = 3600
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account_v1.rotator.metadata[0].name
            restart_policy       = "Never"
            container {
              name    = "rotate"
              image   = var.image
              command = ["sh", "/etc/rotator/rotate.sh"]

              dynamic "env" {
                for_each = {
                  REPO_URL                 = var.repo_url
                  REPO_REF                 = var.repo_ref
                  ROOTS                    = join(" ", var.roots)
                  ALLOWED_TYPES            = jsonencode(var.allowed_resource_types)
                  TOFU_VERSION             = var.tofu_version
                  KUBE_IN_CLUSTER_CONFIG   = "true"
                  ARM_USE_OIDC             = "true"
                  ARM_OIDC_TOKEN_FILE_PATH = "/var/run/secrets/azure/token"
                  ARM_CLIENT_ID            = azuread_application.rotator.client_id
                  ARM_TENANT_ID            = data.azuread_client_config.current.tenant_id
                }
                content {
                  name  = env.key
                  value = env.value
                }
              }

              resources {
                requests = { cpu = "100m", memory = "256Mi" }
                limits   = { memory = "1Gi" }
              }
              volume_mount {
                name       = "script"
                mount_path = "/etc/rotator"
                read_only  = true
              }
              volume_mount {
                name       = "azure-token"
                mount_path = "/var/run/secrets/azure"
                read_only  = true
              }
              dynamic "volume_mount" {
                for_each = kubernetes_secret_v1.git_ssh
                content {
                  name       = "git-ssh"
                  mount_path = "/etc/git-ssh"
                  read_only  = true
                }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map_v1.script.metadata[0].name
              }
            }
            # Service-account token Entra accepts through the federated credential.
            volume {
              name = "azure-token"
              projected {
                sources {
                  service_account_token {
                    audience           = "api://AzureADTokenExchange"
                    expiration_seconds = 3600
                    path               = "token"
                  }
                }
              }
            }
            dynamic "volume" {
              for_each = kubernetes_secret_v1.git_ssh
              content {
                name = "git-ssh"
                secret {
                  secret_name  = volume.value.metadata[0].name
                  default_mode = "0400"
                }
              }
            }
          }
        }
      }
    }
  }
}
