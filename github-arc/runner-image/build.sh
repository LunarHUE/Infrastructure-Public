#!/usr/bin/env bash
# Build the runner image and get it onto the cluster.
#
#   ./build.sh                      # tags $IMAGE_REPO:YYYYMMDD
#   ./build.sh mytag                # custom tag
#
#   IMAGE_REPO=ghcr.io/me/actions-runner ./build.sh    # repo to tag as
#   PUSH=1 ./build.sh               # docker push to the registry
#   K3S_IMPORT=1 ./build.sh         # load into this node's k3s containerd (no registry);
#                                   # pin runners to this node with runner_node_selector
#
# Then set runner_image in ../terraform.tfvars and `tofu apply`.
set -euo pipefail
cd "$(dirname "$0")"
TAG="${1:-$(date +%Y%m%d)}"
IMAGE="${IMAGE_REPO:-local/actions-runner}:${TAG}"

docker build --pull -t "$IMAGE" .

if [ "${PUSH:-0}" = 1 ]; then
  docker push "$IMAGE"
fi
if [ "${K3S_IMPORT:-0}" = 1 ]; then
  docker save "$IMAGE" | sudo k3s ctr -n k8s.io images import -
  sudo k3s ctr -n k8s.io images ls -q | grep -F "$IMAGE"
  echo "Loaded $IMAGE into containerd on $(hostname)."
fi
echo "Now set:  runner_image = \"$IMAGE\"  in terraform.tfvars and run tofu apply."
