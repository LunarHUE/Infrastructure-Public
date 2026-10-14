# GitHub Actions runners on Kubernetes (ARC)

Self-hosted GitHub Actions runners using
[actions-runner-controller](https://github.com/actions/actions-runner-controller)
(the `gha-runner-scale-set` charts), deployed with OpenTofu / Terraform.

On top of a stock ARC install it adds:

- **Size classes**: several `runs-on` labels, each its own scale set with its
  own warm pool and limits.
- **Node selection**: pin runners (and, separately, the controller and
  listeners) to particular nodes, globally or per class.
- **CPU pinning**: `nproc` inside a job reports the class's CPU limit, not the
  host's core count.
- **Docker in Docker**, with an optional Docker Hub mirror.
- **Optional persistent caches** on the node for nix, Gradle and pnpm, an npm
  registry override, and a shared nix binary cache with scheduled GC.

Everything past the GitHub credentials is optional. The defaults give working
runners with Docker that keep nothing between jobs.

## Quick start

1. Create a GitHub App for your org with **Administration: read & write**
   (repo) or **Self-hosted runners: read & write** (org) permission, install
   it, and download its private key as `github-app.pem` here. A personal
   access token (`github_token`) also works.
2. `cp terraform.tfvars.example terraform.tfvars` and set `github_config_url`
   and the App IDs.
3. `tofu init && tofu apply`
4. Use a class name as `runs-on`:

```yaml
jobs:
  test:
    runs-on: k8s-sm
    steps:
      - uses: actions/checkout@v4
      - run: make test
```

Requirements: a Kubernetes cluster you have a kubeconfig for, and OpenTofu
>= 1.6 (or Terraform).

## Runner classes

Each key in `runner_classes` is a `runs-on` label and its own scale set.
Defaults:

| `runs-on` | CPU req / limit | Memory req / limit | Warm / max |
|-----------|-----------------|--------------------|------------|
| `k8s-sm`  | 0.5 / 2         | 1 / 4 GiB          | 0 / 4      |
| `k8s`     | 1 / 4           | 2 / 8 GiB          | 0 / 4      |
| `k8s-lg`  | 2 / 8           | 8 / 16 GiB         | 0 / 2      |

Override the whole map in `terraform.tfvars` to rename, resize or add classes.
Set `min_runners` above 0 to keep warm pods waiting for jobs. Per class you can
also set `node_selector` (merged over `runner_node_selector`) and `shm_size`
(`/dev/shm`, a memory tmpfs; defaults to a quarter of the memory limit).

With `pin_runner_cpus` (default on), a class whose `cpu_limit` is a whole
number runs its runner under `taskset` on that many random cores. A CPU limit
alone is only a cgroup quota: ninja, node, turbo and make size their
parallelism from `nproc` and would oversubscribe it.

## Choosing nodes

| Variable                   | Applies to                              |
|----------------------------|-----------------------------------------|
| `runner_node_selector`     | every runner pod (and the nix GC job)   |
| `runner_classes[*].node_selector` | one class, merged on top         |
| `runner_tolerations`       | every runner pod, e.g. a tainted build node |
| `controller_node_selector` / `controller_tolerations` | the ARC controller and the per-class listener pods |
| `runner_priority_class`    | creates a PriorityClass for runner pods |

All default to empty, so pods go wherever the scheduler puts them. For a
dedicated build node:

```hcl
runner_node_selector = { "kubernetes.io/hostname" = "build-01" }
runner_tolerations   = [{ key = "ci", operator = "Exists", effect = "NoSchedule" }]
```

On a shared cluster, `runner_priority_class = { name = "ci-runner", value = -1000 }`
keeps a runner that doesn't fit from preempting other workloads, and makes
runner pods the first evicted under node pressure.

## Docker

`enable_docker` (default on) runs a privileged `docker:dind` sidecar in each
runner pod, with `DOCKER_HOST` pointing at it. The daemon is fresh per job, so
there is no layer cache between jobs. `docker_registry_mirror` sends Docker Hub
pulls through a pull-through cache (dockerd only mirrors Docker Hub). Add the
mirror's `host:port` to `docker_insecure_registries` if it is plain HTTP.

## Caches

Off by default. Each one is independent:

- **`npm_registry`**: sets `npm_config_registry` for jobs, e.g. an in-cluster
  Verdaccio.
- **`cache_host_dir`**: a directory on the node(s) mounted into every runner
  pod as:

  | In the pod                             | Holds                                   |
  |----------------------------------------|-----------------------------------------|
  | `/nix`                                 | the nix store                           |
  | `/home/runner/.gradle`                 | Gradle wrapper dists, dependency and build cache |
  | `/home/runner/.local/share/pnpm/store` | pnpm store (`npm_config_store_dir` points here) |

  Concurrent jobs share them; nix, Gradle and pnpm all lock correctly on a
  local filesystem. The caches are per node, so pin runners with
  `runner_node_selector` to get hits. Use local disk, not NFS: a nix store on
  NFS is roughly 10x slower and its SQLite db needs local locking. If the
  directory is a mount that must be present (a dedicated disk), set
  `cache_host_path_type = "Directory"` so pods refuse to start without it
  instead of filling the root disk. Gradle and pnpm caches are not pruned
  automatically.

Everything else is fresh per job: the checkout, `~/.cache`, `/tmp` and the
Docker daemon. `/tmp` and `_work` are emptyDirs on the node disk (fast fsync)
rather than the container overlayfs.

## Nix

Needs an image with nix at `/opt/nix-bin`, such as the one in `runner-image/`.
Set `enable_nix = true` and the pods get a `NIX_CONFIG` with `max-jobs` and
`cores` set from the class CPU limit (nix doesn't see cgroup or affinity
limits), an emergency GC floor, and substituters: the binary cache below if
set, `nix_extra_substituters`, then cache.nixos.org.

### Binary cache

`nix_binary_cache` points at a ReadWriteMany volume, either an existing PVC
(`existing_claim`) or an NFS export (`nfs_server` + `nfs_path`, made into a
static PersistentVolume). A `post-build-hook` (`push-to-cache.sh`) signs every
build output and copies its closure there, and it's the first substituter, so
the node-local store is only a working set. The hook never fails a build: if
the cache is unreachable it warns and the next build of that path pushes
again. Large sequential NAR files are fine on NFS; only the store itself needs
local disk.

Generate a key pair and put the private half next to this file (gitignored):

```
nix-store --generate-binary-cache-key my-ci-1 nix-cache-key.sec nix-cache-key.pub
```

and set `nix_binary_cache.public_key` to the contents of `nix-cache-key.pub`.

### Garbage collection

With `enable_nix` and `cache_host_dir` set, a `nix-store-gc` CronJob
(`nix-gc.sh`, `nix_store_gc`) runs hourly on a node matching
`runner_node_selector`, as the runner uid, against the same hostPath. Each run:

1. removes `/nix/var/nix/builds/*` older than 6 h (pods killed mid-build leave
   them) and `/nix/var/nix/gcroots/ci/*` older than 24 h;
2. stops if the node has more than `min_free` (50G) free;
3. otherwise checks whether any EphemeralRunner has a job and, if none does,
   collects until `max_free` (100G) is free. Below `force_free` (15G) it
   collects even with jobs running.

If `runner_node_selector` matches several nodes, the CronJob only cleans one of
them per run; pin runners to one node when using the shared store.

The pods only keep `nix_store_min_free` as an emergency floor. Don't raise it:
with several pods on one store, nix's in-build GC makes every derivation in
every pod queue on one exclusive lock, and a GC in one pod can't see another
pod's `result` symlinks, so it deletes outputs other jobs are still uploading.
A job that needs an output to survive until it's uploaded should root it in
the shared directory:

```bash
nix build .#iso --out-link "/nix/var/nix/gcroots/ci/${GITHUB_RUN_ID}-${GITHUB_JOB}-iso"
```

To run a pass by hand:
`kubectl -n github-arc create job --from=cronjob/nix-store-gc nix-store-gc-manual`.

The store directory belongs to uid 1001 and is used by single-user nix. Never
point a root nix at it (`nix ... --store local?root=...`): a root nix re-owns
`store/` and every runner then fails with `opening lock file ...: Permission
denied`. If that happens: `chown 1001:1001 <dir>/nix/store && chmod 0755 <dir>/nix/store`.

## Operating

```
kubectl -n github-arc get autoscalingrunnerset          # per-class counts
kubectl -n github-arc get pods -l actions-ephemeral-runner=True
kubectl -n github-arc logs deploy/<class>-listener      # why a job was / was not assigned
kubectl -n github-arc delete pod <runner-pod>           # kill a stuck job; ARC replaces it
```

Changing the config and running `tofu apply` rolls the scale sets: idle warm
pods are replaced with the new template, and running jobs finish on the old one.

## Security

Treat every job on these runners as root on the node it runs on:

- **Privileged Docker sidecar.** With `enable_docker`, a job can
  `docker run --privileged`, mount the node's disk, and read any Secret the
  kubelet has mounted on that node. Give runners their own node(s).
- **sudo.** The stock actions-runner image gives the runner user passwordless
  sudo.
- **Shared caches.** With `cache_host_dir`, every job can write the caches the
  next job uses. With `nix_binary_cache`, the signing key is readable by every
  job and the store is writable, so a compromised dependency in one repo's CI
  can poison the cache for all of them.

So **never let public repositories or pull requests from forks use these
runners**. Keep "Allow public repositories" off on the runner group, use
`runner_group` to limit which repos can use them, and use GitHub-hosted runners
for public repos.
