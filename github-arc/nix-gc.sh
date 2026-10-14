#!/usr/bin/env bash
# Scheduled garbage collection of the node-local CI nix store (/nix, the
# hostPath every runner pod shares). Runs from the nix-store-gc CronJob as the
# runner uid, never from inside a job.
#
# Why not let nix do it (min-free/max-free)? Every runner pod would GC the same
# shared store on its own, and a GC running in one pod cannot see the other
# pods' `result` symlinks (their _work dirs are pod-private), so it deletes
# outputs other jobs are still uploading. And when the disk is low for a reason
# nix cannot fix (other workloads' volumes), every derivation in every pod
# waits for the GC lock, frees nothing, and the next derivation does it again:
# 3-5x job times. So the pods keep only an emergency floor and this job does the
# real collection, only while no runner is executing a job.
#
# Env (set by the CronJob): NIX_GC_MIN_FREE (collect when free < this),
# NIX_GC_MAX_FREE (collect until this much is free), NIX_GC_FORCE_FREE (below
# this, collect even while jobs are running: a single pass beats the kubelet
# evicting the node), NIX_GC_STALE_BUILD_HOURS, NIX_GC_ROOT_HOURS, NAMESPACE.
set -euo pipefail

to_bytes() { numfmt --from=iec "$1"; }
min_free=$(to_bytes "${NIX_GC_MIN_FREE:-120G}")
max_free=$(to_bytes "${NIX_GC_MAX_FREE:-200G}")
force_free=$(to_bytes "${NIX_GC_FORCE_FREE:-40G}")
stale_build_min=$(( ${NIX_GC_STALE_BUILD_HOURS:-6} * 60 ))
root_min=$(( ${NIX_GC_ROOT_HOURS:-24} * 60 ))
free() { df -B1 --output=avail /nix | tail -1; }
human() { numfmt --to=iec "$1"; }

echo "nix-gc: /nix has $(human "$(free)") free (collect below $(human "$min_free"), force below $(human "$force_free"))"

# 1. Build directories left behind by pods that were killed mid-build. A live
#    build is never older than GitHub's 6 h job limit.
#    nix materialises source trees read-only (Go vendor dirs come out
#    dr-xr-xr-x), and a directory without its write bit will not let even its
#    owner unlink the children, so restore write before removing. And never let
#    one undeletable straggler abort the script: a single "rm: Permission
#    denied" tripping `set -e` here would stop step 3 -- the collection that
#    actually frees the disk -- from ever running.
if [ -d /nix/var/nix/builds ]; then
  while IFS= read -r -d '' d; do
    chmod -R u+w "$d" 2>/dev/null || true
    if rm -rf "$d"; then
      echo "nix-gc: removed stale build dir $d"
    else
      echo "nix-gc: WARNING: could not remove stale build dir $d"
    fi
  done < <(find /nix/var/nix/builds -mindepth 1 -maxdepth 1 -type d -mmin "+$stale_build_min" -print0)
fi

# 2. Per-job roots that jobs create with `nix build --out-link /nix/var/nix/gcroots/ci/<name>`
#    (the only kind of root another pod's GC can see). Jobs are long gone after a day.
if [ -d /nix/var/nix/gcroots/ci ]; then
  find /nix/var/nix/gcroots/ci -mindepth 1 -maxdepth 1 -mmin "+$root_min" -print -delete \
    | sed 's/^/nix-gc: removed expired job root /' || true
fi

now=$(free)
if [ "$now" -ge "$min_free" ]; then
  echo "nix-gc: $(human "$now") free, nothing to do"
  exit 0
fi

# 3. Only collect while no runner is executing a job. ARC sets
#    status.jobWorkflowRef on an EphemeralRunner once a job is assigned
#    (jobRequestId stays null in 0.14). If the API is unreachable, assume busy.
sa=/var/run/secrets/kubernetes.io/serviceaccount
busy=$(curl -sSf --max-time 20 --cacert "$sa/ca.crt" -H "Authorization: Bearer $(cat "$sa/token")" \
  "https://kubernetes.default.svc/apis/actions.github.com/v1alpha1/namespaces/${NAMESPACE:-github-arc}/ephemeralrunners" \
  | jq '[.items[] | select((.status.jobWorkflowRef // "") != "")] | length' 2>/dev/null || echo unknown)
if [ "$busy" != "0" ] && [ "$now" -ge "$force_free" ]; then
  echo "nix-gc: $busy runner(s) busy and $(human "$now") free is above the force floor; skipping until the node is idle"
  exit 0
fi
[ "$busy" = "0" ] || echo "nix-gc: WARNING: collecting with $busy busy runner(s) because free space is below $(human "$force_free")"

want=$(( max_free - now ))
echo "nix-gc: collecting up to $(human "$want")"
nix store gc --max "$want"
echo "nix-gc: done, $(human "$(free)") free"
