#!/usr/bin/env bash
# Nix post-build-hook: sign every build output and copy its closure to the
# shared binary cache (NIX_CACHE_URL, a file:// store on a shared volume).
# Nix sets OUT_PATHS and DRV_PATH. Runs synchronously after each build, so it
# must not fail the build if the cache is unreachable: the job still has its
# outputs in the local store, and the next build of the same path pushes again.
set -u
[ -n "${NIX_CACHE_URL:-}" ] || exit 0
# The hook only reads the local store, so it must never trigger nix's
# min-free garbage collection, or every copy queues for the GC lock behind
# other pods' collections.
# shellcheck disable=SC2086
if ! nix copy --option min-free 0 --option max-free 0 --to "$NIX_CACHE_URL" $OUT_PATHS 2>&1; then
  echo "push-to-cache: WARNING: could not push $OUT_PATHS to $NIX_CACHE_URL" >&2
fi
exit 0
