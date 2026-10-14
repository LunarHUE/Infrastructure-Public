# -----------------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------------
variable "kubeconfig_path" {
  description = "Path to the kubeconfig for the target cluster"
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubeconfig context to use; null uses the current context"
  type        = string
  default     = null
}

variable "namespace" {
  description = "Kubernetes namespace for ARC"
  type        = string
  default     = "github-arc"
}

# -----------------------------------------------------------------------------
# GitHub
# -----------------------------------------------------------------------------
variable "github_config_url" {
  description = "Where the runners register: an org (https://github.com/my-org), an enterprise (https://github.com/enterprises/my-ent) or a single repo (https://github.com/me/my-repo)"
  type        = string
}

variable "runner_group" {
  description = "GitHub runner group the scale sets join; null uses the org's Default group"
  type        = string
  default     = null
}

# Authenticate with either a GitHub App (recommended for orgs) or a PAT.
variable "github_app_id" {
  description = "GitHub App ID (numeric). Leave null when using github_token."
  type        = string
  default     = null
}

variable "github_app_installation_id" {
  description = "GitHub App installation ID (numeric). Leave null when using github_token."
  type        = string
  default     = null
}

variable "github_app_private_key_path" {
  description = "Path to the GitHub App private key PEM file"
  type        = string
  default     = "github-app.pem"
}

variable "github_token" {
  description = "Personal access token, used instead of a GitHub App when set (repo scope for a repo, admin:org for an org)"
  type        = string
  default     = null
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Chart versions and image
# -----------------------------------------------------------------------------
variable "arc_controller_version" {
  description = "Helm chart version for the ARC controller"
  type        = string
  default     = "0.14.2"
}

variable "arc_runner_set_version" {
  description = "Helm chart version for the ARC runner scale sets"
  type        = string
  default     = "0.14.2"
}

variable "runner_image" {
  description = "Runner container image. The stock image works; runner-image/ builds a pre-warmed one (required for enable_nix)."
  type        = string
  default     = "ghcr.io/actions/actions-runner:latest"
}

# -----------------------------------------------------------------------------
# Scheduling
# -----------------------------------------------------------------------------
variable "runner_node_selector" {
  description = "nodeSelector for every runner pod, e.g. { \"kubernetes.io/hostname\" = \"build-01\" }. Empty schedules anywhere. Per-class node_selector entries are merged on top."
  type        = map(string)
  default     = {}
}

variable "runner_tolerations" {
  description = "Tolerations for every runner pod (Kubernetes toleration objects), e.g. for a tainted build node"
  type        = list(any)
  default     = []
}

variable "controller_node_selector" {
  description = "nodeSelector for the ARC controller and the per-class listener pods. Empty schedules anywhere."
  type        = map(string)
  default     = {}
}

variable "controller_tolerations" {
  description = "Tolerations for the ARC controller and listener pods"
  type        = list(any)
  default     = []
}

variable "runner_priority_class" {
  description = "When set, creates a PriorityClass and runs runner pods at it. A negative value (e.g. -1000) keeps CI from preempting other workloads and makes it evicted first. null leaves runner pods at the cluster default."
  type = object({
    name  = string
    value = number
  })
  default = null
}

variable "pin_runner_cpus" {
  description = "Pin each runner to as many cores as its class's cpu_limit with taskset, so nproc reports the limit instead of the host's core count. Only applies to classes whose cpu_limit is a whole number."
  type        = bool
  default     = true
}

# Runner size classes. Every key is a `runs-on` label and becomes its own ARC
# scale set. Requests must fit on a node at once; limits are ceilings.
variable "runner_classes" {
  description = "Runner size classes; each key is a runs-on label"
  type = map(object({
    min_runners    = optional(number, 0)
    max_runners    = optional(number, 4)
    cpu_request    = string
    cpu_limit      = string
    memory_request = string
    memory_limit   = string
    shm_size       = optional(string) # /dev/shm size; defaults to a quarter of memory_limit (min 1Gi)
    node_selector  = optional(map(string), {})
  }))
  default = {
    "k8s-sm" = {
      max_runners = 4
      cpu_request = "500m", cpu_limit = "2", memory_request = "1Gi", memory_limit = "4Gi"
    }
    "k8s" = {
      max_runners = 4
      cpu_request = "1", cpu_limit = "4", memory_request = "2Gi", memory_limit = "8Gi"
    }
    "k8s-lg" = {
      max_runners = 2
      cpu_request = "2", cpu_limit = "8", memory_request = "8Gi", memory_limit = "16Gi"
    }
  }
}

# -----------------------------------------------------------------------------
# Docker in Docker
# -----------------------------------------------------------------------------
variable "enable_docker" {
  description = "Run a privileged Docker-in-Docker sidecar so jobs can use docker. Privileged: see the security notes in README.md."
  type        = bool
  default     = true
}

variable "docker_registry_mirror" {
  description = "Docker Hub pull-through mirror for the dind daemon, e.g. http://registry-mirror.registry.svc.cluster.local:5000. null pulls direct."
  type        = string
  default     = null
}

variable "docker_insecure_registries" {
  description = "Registries (host:port) the dind daemon may reach over plain HTTP, e.g. an HTTP mirror"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Package caches
# -----------------------------------------------------------------------------
variable "npm_registry" {
  description = "npm/pnpm registry for jobs (e.g. an in-cluster Verdaccio). null uses registry.npmjs.org."
  type        = string
  default     = null
}

variable "runner_extra_env" {
  description = "Extra environment variables for the runner container"
  type        = map(string)
  default     = {}
}

variable "cache_host_dir" {
  description = "Directory on the runner node(s) holding persistent nix/, gradle/ and pnpm-store/ caches shared by runner pods (hostPath). null keeps nothing between jobs. Caches are per node, so pin runners with runner_node_selector for the best hit rate."
  type        = string
  default     = null
}

variable "cache_host_path_type" {
  description = "hostPath type for the cache directories. DirectoryOrCreate creates them on first use; Directory refuses to start a pod when they are missing (use it when cache_host_dir is a mount that must be present)."
  type        = string
  default     = "DirectoryOrCreate"

  validation {
    condition     = contains(["Directory", "DirectoryOrCreate"], var.cache_host_path_type)
    error_message = "cache_host_path_type must be Directory or DirectoryOrCreate."
  }
}

# -----------------------------------------------------------------------------
# Nix (requires the image from runner-image/)
# -----------------------------------------------------------------------------
variable "enable_nix" {
  description = "Configure nix in runner pods (max-jobs/cores per class, GC floor, substituters). Needs an image with nix at /opt/nix-bin, such as runner-image/."
  type        = bool
  default     = false
}

variable "nix_extra_substituters" {
  description = "Extra nix substituters tried before cache.nixos.org (e.g. an in-cluster read-through cache)"
  type        = list(string)
  default     = []
}

variable "nix_extra_trusted_public_keys" {
  description = "Public keys for nix_extra_substituters"
  type        = list(string)
  default     = []
}

variable "nix_binary_cache" {
  description = <<-EOT
    Shared nix binary cache every build output is signed and pushed to. null disables it.
    Give either existing_claim (a ReadWriteMany PVC in var.namespace) or nfs_server + nfs_path
    (a static NFS PersistentVolume is created). Generate the key pair with
    `nix-store --generate-binary-cache-key <name> nix-cache-key.sec nix-cache-key.pub`.
  EOT
  type = object({
    public_key        = string
    secret_key_path   = optional(string, "nix-cache-key.sec")
    existing_claim    = optional(string)
    nfs_server        = optional(string)
    nfs_path          = optional(string)
    nfs_mount_options = optional(list(string), ["hard", "noatime", "nconnect=8"])
    size              = optional(string, "1Ti")
  })
  default = null

  validation {
    condition = var.nix_binary_cache == null || (
      try(var.nix_binary_cache.existing_claim, null) != null ||
      (try(var.nix_binary_cache.nfs_server, null) != null && try(var.nix_binary_cache.nfs_path, null) != null)
    )
    error_message = "nix_binary_cache needs existing_claim, or both nfs_server and nfs_path."
  }
}

variable "nix_store_min_free" {
  description = "Emergency floor: a runner's own nix garbage-collects when free disk drops below this. Keep it well below nix_store_gc.min_free so it only fires if the scheduled GC fails."
  type        = string
  default     = "10G"
}

variable "nix_store_max_free" {
  description = "…and stops collecting once this much is free"
  type        = string
  default     = "20G"
}

# Scheduled GC of the shared node-local store (nix-gc.sh). Only created with
# enable_nix and cache_host_dir; it only collects while no runner has a job.
variable "nix_store_gc" {
  type = object({
    schedule          = optional(string, "17 * * * *") # cron, cluster local time
    min_free          = optional(string, "50G")        # collect when free disk is below this
    max_free          = optional(string, "100G")       # collect until this much is free
    force_free        = optional(string, "15G")        # below this, collect even while jobs run
    stale_build_hours = optional(number, 6)            # remove /nix/var/nix/builds/* older than this
    root_hours        = optional(number, 24)           # remove /nix/var/nix/gcroots/ci/* older than this
  })
  default = {}
}
