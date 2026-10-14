locals {
  caches          = var.cache_host_dir != null
  nix_binary      = var.enable_nix && var.nix_binary_cache != null
  nix_gc          = var.enable_nix && local.caches
  nix_cache_mount = "/mnt/nix-cache"
  nix_cache_claim = coalesce(try(var.nix_binary_cache.existing_claim, null), "nix-cache-store")

  listener_scheduled = length(var.controller_node_selector) + length(var.controller_tolerations) > 0

  nix_substituters = concat(
    local.nix_binary ? ["file://${local.nix_cache_mount}"] : [],
    var.nix_extra_substituters,
    ["https://cache.nixos.org"],
  )
  nix_trusted_public_keys = compact(concat(
    ["cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="],
    var.nix_extra_trusted_public_keys,
    [local.nix_binary ? try(var.nix_binary_cache.public_key, "") : ""],
  ))

  # Lists below are built with `[for x in [...] : x if cond]` rather than
  # `cond ? [...] : []` so elements of different shapes can sit together.
  cache_volumes = [for v in [
    # Persistent per-node caches shared by every runner pod on the node; nix,
    # Gradle and pnpm all lock correctly on a local filesystem.
    { name = "nix-store", hostPath = { path = "${coalesce(var.cache_host_dir, "-")}/nix", type = var.cache_host_path_type } },
    { name = "gradle-home", hostPath = { path = "${coalesce(var.cache_host_dir, "-")}/gradle", type = var.cache_host_path_type } },
    { name = "pnpm-store", hostPath = { path = "${coalesce(var.cache_host_dir, "-")}/pnpm-store", type = var.cache_host_path_type } },
  ] : v if local.caches]

  cache_mounts = [for m in [
    { name = "nix-store", mountPath = "/nix" },
    { name = "gradle-home", mountPath = "/home/runner/.gradle" },
    { name = "pnpm-store", mountPath = "/home/runner/.local/share/pnpm/store" },
  ] : m if local.caches]

  nix_binary_volumes = [for v in [
    { name = "nix-cache", persistentVolumeClaim = { claimName = local.nix_cache_claim } },
    { name = "nix-cache-key", secret = { secretName = "nix-cache-signing-key", defaultMode = 292 } }, # 0444
    { name = "nix-hooks", configMap = { name = "nix-hooks", defaultMode = 365 } },                    # 0555
  ] : v if local.nix_binary]

  nix_binary_mounts = [for m in [
    { name = "nix-cache", mountPath = local.nix_cache_mount },
    { name = "nix-cache-key", mountPath = "/etc/nix-cache", readOnly = true },
    { name = "nix-hooks", mountPath = "/etc/nix-hooks", readOnly = true },
  ] : m if local.nix_binary]

  docker_volumes = [for v in [
    { name = "dind-sock", emptyDir = {} },
    { name = "dind-externals", emptyDir = {} },
  ] : v if var.enable_docker]

  # First run on a node: create the cache dirs owned by the runner uid,
  # register the image's nix closure in the node store (idempotent; also
  # upgrades nix), and seed the Gradle home from the image.
  seed_containers = [for c in [{
    name            = "seed-ci-caches"
    image           = var.runner_image
    securityContext = { runAsUser = 0 }
    command = ["bash", "-euo", "pipefail", "-c", <<-SEED
      install -d -o 1001 -g 1001 /mnt/nix/nix /mnt/gradle /mnt/pnpm-store
      if [ -x /opt/nix-bin/nix ]; then
        runuser -u runner -- /opt/nix-bin/nix copy --no-check-sigs --to 'local?root=/mnt/nix' "$(dirname "$(readlink -f /opt/nix-bin)")"
        # Roots that survive across pods: jobs link outputs here (see README).
        runuser -u runner -- mkdir -p /mnt/nix/nix/var/nix/gcroots/ci
      fi
      if [ -d /home/runner/.gradle ] && [ ! -e /mnt/gradle/wrapper ]; then
        runuser -u runner -- cp -a /home/runner/.gradle/. /mnt/gradle/
      fi
    SEED
    ]
    volumeMounts = [
      { name = "nix-store", mountPath = "/mnt/nix/nix" },
      { name = "gradle-home", mountPath = "/mnt/gradle" },
      { name = "pnpm-store", mountPath = "/mnt/pnpm-store" },
    ]
  }] : c if local.caches]

  # Docker-in-Docker is spelled out instead of containerMode.type=dind so the
  # daemon can be given a registry mirror. These entries, the DOCKER_* env and
  # the dind volumes are what the chart renders for dind mode.
  docker_containers = [for c in [
    {
      name         = "init-dind-externals"
      image        = var.runner_image
      command      = ["cp"]
      args         = ["-r", "/home/runner/externals/.", "/home/runner/tmpDir/"]
      volumeMounts = [{ name = "dind-externals", mountPath = "/home/runner/tmpDir" }]
    },
    {
      name          = "dind"
      image         = "docker:dind"
      restartPolicy = "Always"
      args = concat(
        ["dockerd", "--host=unix:///var/run/docker.sock", "--group=$(DOCKER_GROUP_GID)"],
        # dockerd only supports mirrors for Docker Hub.
        var.docker_registry_mirror != null ? ["--registry-mirror=${var.docker_registry_mirror}"] : [],
        [for r in var.docker_insecure_registries : "--insecure-registry=${r}"],
      )
      env             = [{ name = "DOCKER_GROUP_GID", value = "123" }]
      securityContext = { privileged = true }
      startupProbe = {
        exec                = { command = ["docker", "info"] }
        initialDelaySeconds = 0
        periodSeconds       = 5
        failureThreshold    = 24
      }
      volumeMounts = [
        { name = "work", mountPath = "/home/runner/_work" },
        { name = "dind-sock", mountPath = "/var/run" },
        { name = "dind-externals", mountPath = "/home/runner/externals" },
      ]
    },
  ] : c if var.enable_docker]

  classes = {
    for name, c in var.runner_classes : name => {
      # taskset needs a whole number of cores.
      pin = var.pin_runner_cpus && can(regex("^[0-9]+$", c.cpu_limit))
      # nix's max-jobs / cores, from the CPU limit ("12" or "1500m").
      cpus = max(1, try(ceil(tonumber(c.cpu_limit)), ceil(tonumber(trimsuffix(c.cpu_limit, "m")) / 1000), 1))
      # Memory-backed, so it counts against the memory limit.
      shm = coalesce(c.shm_size, try("${max(1, floor(tonumber(trimsuffix(c.memory_limit, "Gi")) / 4))}Gi", "1Gi"))
    }
  }

  runner_values = {
    for name, c in var.runner_classes : name => {
      githubConfigUrl    = var.github_config_url
      githubConfigSecret = "github-arc-auth"
      runnerScaleSetName = name
      runnerGroup        = var.runner_group
      minRunners         = c.min_runners
      maxRunners         = c.max_runners

      listenerTemplate = local.listener_scheduled ? {
        spec = {
          nodeSelector = var.controller_node_selector
          tolerations  = var.controller_tolerations
          containers   = [{ name = "listener" }]
        }
      } : null

      template = {
        spec = {
          nodeSelector      = merge(var.runner_node_selector, c.node_selector)
          tolerations       = var.runner_tolerations
          priorityClassName = try(var.runner_priority_class.name, null)
          initContainers    = concat(local.seed_containers, local.docker_containers)
          containers = [
            {
              name  = "runner"
              image = var.runner_image
              env = concat(
                [for k, v in var.runner_extra_env : { name = k, value = v }],
                # pnpm only uses its default store when it can hardlink into
                # the workspace; the hostPath store is a different mount, so
                # without this it falls back to a per-pod store.
                local.caches ? [{ name = "npm_config_store_dir", value = "/home/runner/.local/share/pnpm/store" }] : [],
                var.npm_registry != null ? [{ name = "npm_config_registry", value = var.npm_registry }] : [],
                # nix counts cores with hardware_concurrency (not affinity- or
                # cgroup-aware), so max-jobs and cores follow the class. The
                # store is kept bounded by the nix-store-gc CronJob; min-free
                # here is an emergency floor only (see nix-gc.sh).
                var.enable_nix ? [{ name = "NIX_CONFIG", value = join("\n", compact([
                  "substituters = ${join(" ", local.nix_substituters)}",
                  "trusted-public-keys = ${join(" ", local.nix_trusted_public_keys)}",
                  local.nix_binary ? "secret-key-files = /etc/nix-cache/secret-key" : "",
                  local.nix_binary ? "post-build-hook = /etc/nix-hooks/push-to-cache.sh" : "",
                  "min-free = ${var.nix_store_min_free}",
                  "max-free = ${var.nix_store_max_free}",
                  "connect-timeout = 5",
                  "max-jobs = ${local.classes[name].cpus}",
                  "cores = ${local.classes[name].cpus}",
                ])) }] : [],
                local.nix_binary ? [{ name = "NIX_CACHE_URL", value = "file://${local.nix_cache_mount}?compression=zstd&parallel-compression=true" }] : [],
                var.enable_docker ? [
                  { name = "DOCKER_HOST", value = "unix:///var/run/docker.sock" },
                  { name = "RUNNER_WAIT_FOR_DOCKER_IN_SECONDS", value = "120" },
                ] : [],
              )
              # A CPU limit is only a cgroup quota; tools that size parallelism
              # from nproc (ninja, node, turbo, make) still see every host core
              # and oversubscribe it. Pin the runner and everything it spawns
              # to a random set of cores equal to the limit so nproc matches.
              command = local.classes[name].pin ? ["bash", "-c", <<-CMD
                n=$(( ${c.cpu_limit} < $(nproc) ? ${c.cpu_limit} : $(nproc) ))
                cores=$(shuf -i 0-$(( $(nproc) - 1 )) -n "$n" | sort -n | paste -sd,)
                exec taskset -c "$cores" /home/runner/run.sh
              CMD
              ] : ["/home/runner/run.sh"]
              resources = {
                requests = { cpu = c.cpu_request, memory = c.memory_request }
                limits   = { cpu = c.cpu_limit, memory = c.memory_limit }
              }
              volumeMounts = concat(
                local.cache_mounts,
                [
                  { name = "work", mountPath = "/home/runner/_work" },
                  # /tmp on the container overlayfs is slow to fsync; an
                  # emptyDir on the node disk is much faster.
                  { name = "tmp", mountPath = "/tmp" },
                  # Kubernetes' default /dev/shm is 64 MiB.
                  { name = "dshm", mountPath = "/dev/shm" },
                ],
                [for m in [{ name = "dind-sock", mountPath = "/var/run" }] : m if var.enable_docker],
                local.nix_binary_mounts,
              )
            }
          ]
          volumes = concat(
            local.cache_volumes,
            local.nix_binary_volumes,
            local.docker_volumes,
            [
              { name = "work", emptyDir = {} },
              { name = "tmp", emptyDir = {} },
              { name = "dshm", emptyDir = { medium = "Memory", sizeLimit = local.classes[name].shm } },
            ],
          )
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Namespace
# -----------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "arc" {
  metadata {
    name = var.namespace
  }
}

# -----------------------------------------------------------------------------
# GitHub credentials (GitHub App, or a PAT when github_token is set)
# -----------------------------------------------------------------------------
resource "kubernetes_secret_v1" "github_arc_auth" {
  metadata {
    name      = "github-arc-auth"
    namespace = kubernetes_namespace_v1.arc.metadata[0].name
  }

  data = var.github_token != null ? tomap({
    github_token = var.github_token
    }) : tomap({
    github_app_id              = var.github_app_id
    github_app_installation_id = var.github_app_installation_id
    github_app_private_key     = file(var.github_app_private_key_path)
  })

  lifecycle {
    precondition {
      condition     = var.github_token != null || (var.github_app_id != null && var.github_app_installation_id != null)
      error_message = "Set github_token, or github_app_id and github_app_installation_id (plus the PEM at github_app_private_key_path)."
    }
  }
}

# -----------------------------------------------------------------------------
# ARC controller: watches for workflow jobs and scales runners
# -----------------------------------------------------------------------------
resource "helm_release" "arc_controller" {
  name       = "arc-controller"
  namespace  = kubernetes_namespace_v1.arc.metadata[0].name
  repository = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart      = "gha-runner-scale-set-controller"
  version    = var.arc_controller_version

  values = [yamlencode({
    nodeSelector = var.controller_node_selector
    tolerations  = var.controller_tolerations
  })]

  wait = true
}

# -----------------------------------------------------------------------------
# Runner scale sets, one per class in var.runner_classes
# -----------------------------------------------------------------------------
resource "helm_release" "arc_runner_set" {
  for_each = var.runner_classes

  name       = "arc-${each.key}"
  namespace  = kubernetes_namespace_v1.arc.metadata[0].name
  repository = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart      = "gha-runner-scale-set"
  version    = var.arc_runner_set_version

  depends_on = [
    helm_release.arc_controller,
    kubernetes_secret_v1.github_arc_auth,
    kubernetes_priority_class_v1.ci_runner,
    kubernetes_persistent_volume_claim_v1.nix_cache,
    kubernetes_secret_v1.nix_cache_key,
    kubernetes_config_map_v1.nix_hooks,
  ]

  values = [yamlencode(local.runner_values[each.key])]
}

# -----------------------------------------------------------------------------
# Shared nix binary cache (optional, var.nix_binary_cache). A post-build hook
# signs every output and copies its closure here; it is the first substituter,
# so the node-local /nix store is only a working set.
# -----------------------------------------------------------------------------
resource "kubernetes_persistent_volume_v1" "nix_cache" {
  count = local.nix_binary && try(var.nix_binary_cache.existing_claim, null) == null ? 1 : 0

  metadata {
    name = "nix-cache-store-${var.namespace}"
  }
  spec {
    capacity                         = { storage = var.nix_binary_cache.size }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "" # static; do not let a provisioner adopt it
    mount_options                    = var.nix_binary_cache.nfs_mount_options
    persistent_volume_source {
      nfs {
        server = var.nix_binary_cache.nfs_server
        path   = var.nix_binary_cache.nfs_path
      }
    }
    claim_ref {
      namespace = kubernetes_namespace_v1.arc.metadata[0].name
      name      = local.nix_cache_claim
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "nix_cache" {
  count = length(kubernetes_persistent_volume_v1.nix_cache)

  metadata {
    name      = local.nix_cache_claim
    namespace = kubernetes_namespace_v1.arc.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = ""
    volume_name        = kubernetes_persistent_volume_v1.nix_cache[0].metadata[0].name
    resources {
      requests = { storage = var.nix_binary_cache.size }
    }
  }
  wait_until_bound = true
}

resource "kubernetes_secret_v1" "nix_cache_key" {
  count = local.nix_binary ? 1 : 0

  metadata {
    name      = "nix-cache-signing-key"
    namespace = kubernetes_namespace_v1.arc.metadata[0].name
  }
  data = {
    "secret-key" = file(var.nix_binary_cache.secret_key_path)
  }
}

resource "kubernetes_config_map_v1" "nix_hooks" {
  count = local.nix_binary ? 1 : 0

  metadata {
    name      = "nix-hooks"
    namespace = kubernetes_namespace_v1.arc.metadata[0].name
  }
  data = {
    "push-to-cache.sh" = file("${path.module}/push-to-cache.sh")
  }
}

# -----------------------------------------------------------------------------
# Scheduled GC of the node-local nix store (nix-gc.sh). Runs as the runner uid
# against the same hostPath the pods mount, on a node matching
# var.runner_node_selector; it asks the API whether any EphemeralRunner has a
# job and only collects when none does.
# -----------------------------------------------------------------------------
resource "kubernetes_config_map_v1" "nix_gc" {
  count = local.nix_gc ? 1 : 0

  metadata {
    name      = "nix-store-gc"
    namespace = kubernetes_namespace_v1.arc.metadata[0].name
  }
  data = {
    "nix-gc.sh" = file("${path.module}/nix-gc.sh")
  }
}

resource "kubernetes_service_account_v1" "nix_gc" {
  count = local.nix_gc ? 1 : 0

  metadata {
    name      = "nix-store-gc"
    namespace = kubernetes_namespace_v1.arc.metadata[0].name
  }
}

resource "kubernetes_role_v1" "nix_gc" {
  count = local.nix_gc ? 1 : 0

  metadata {
    name      = "nix-store-gc"
    namespace = kubernetes_namespace_v1.arc.metadata[0].name
  }
  rule {
    api_groups = ["actions.github.com"]
    resources  = ["ephemeralrunners"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding_v1" "nix_gc" {
  count = local.nix_gc ? 1 : 0

  metadata {
    name      = "nix-store-gc"
    namespace = kubernetes_namespace_v1.arc.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.nix_gc[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.nix_gc[0].metadata[0].name
    namespace = kubernetes_namespace_v1.arc.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "nix_gc" {
  count = local.nix_gc ? 1 : 0

  metadata {
    name      = "nix-store-gc"
    namespace = kubernetes_namespace_v1.arc.metadata[0].name
  }
  spec {
    schedule                      = var.nix_store_gc.schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit           = 0
        active_deadline_seconds = 3600
        template {
          metadata {}
          spec {
            service_account_name            = kubernetes_service_account_v1.nix_gc[0].metadata[0].name
            automount_service_account_token = true
            restart_policy                  = "Never"
            node_selector                   = var.runner_node_selector
            dynamic "toleration" {
              for_each = var.runner_tolerations
              content {
                key      = try(toleration.value.key, null)
                operator = try(toleration.value.operator, null)
                value    = try(toleration.value.value, null)
                effect   = try(toleration.value.effect, null)
              }
            }
            # The store is owned by the runner uid; never touch it as root
            # (nix as root re-owns it and every runner fails to lock).
            security_context {
              run_as_user  = 1001
              run_as_group = 1001
            }
            container {
              name    = "nix-gc"
              image   = var.runner_image
              command = ["bash", "/etc/nix-gc/nix-gc.sh"]
              env {
                name  = "HOME"
                value = "/home/runner"
              }
              env {
                name  = "NIX_CONFIG"
                value = "experimental-features = nix-command flakes\nmin-free = 0\nmax-free = 0"
              }
              env {
                name  = "NAMESPACE"
                value = kubernetes_namespace_v1.arc.metadata[0].name
              }
              env {
                name  = "NIX_GC_MIN_FREE"
                value = var.nix_store_gc.min_free
              }
              env {
                name  = "NIX_GC_MAX_FREE"
                value = var.nix_store_gc.max_free
              }
              env {
                name  = "NIX_GC_FORCE_FREE"
                value = var.nix_store_gc.force_free
              }
              env {
                name  = "NIX_GC_STALE_BUILD_HOURS"
                value = tostring(var.nix_store_gc.stale_build_hours)
              }
              env {
                name  = "NIX_GC_ROOT_HOURS"
                value = tostring(var.nix_store_gc.root_hours)
              }
              # Tiny request so it still fits when runners have the node's
              # memory reserved.
              resources {
                requests = { cpu = "100m", memory = "256Mi" }
                limits   = { cpu = "4", memory = "4Gi" }
              }
              volume_mount {
                name       = "nix-store"
                mount_path = "/nix"
              }
              volume_mount {
                name       = "nix-gc"
                mount_path = "/etc/nix-gc"
                read_only  = true
              }
            }
            volume {
              name = "nix-store"
              host_path {
                path = "${var.cache_host_dir}/nix"
                type = var.cache_host_path_type
              }
            }
            volume {
              name = "nix-gc"
              config_map {
                name = kubernetes_config_map_v1.nix_gc[0].metadata[0].name
              }
            }
          }
        }
      }
    }
  }
}
