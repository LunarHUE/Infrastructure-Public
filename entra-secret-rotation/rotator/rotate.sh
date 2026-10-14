#!/bin/sh
# Plan each root in $ROOTS and apply only if every change is to a resource type
# in $ALLOWED_TYPES (JSON array). Anything else fails the job without applying.
set -eu

apk add --no-cache -q git jq curl openssh-client >/dev/null

arch=$(uname -m)
case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
curl -fsSL "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${arch}.tar.gz" \
  | tar -xz -C /usr/local/bin tofu

if [ -f /etc/git-ssh/id_key ]; then
  export GIT_SSH_COMMAND="ssh -i /etc/git-ssh/id_key -o StrictHostKeyChecking=accept-new"
fi
git clone -q --depth 1 --branch "$REPO_REF" "$REPO_URL" /work
export TF_IN_AUTOMATION=1 TF_INPUT=0 TF_PLUGIN_CACHE_DIR=/tmp/plugins
mkdir -p "$TF_PLUGIN_CACHE_DIR"

failed=""
for root in $ROOTS; do
  echo "== $root"
  cd "/work/$root"
  if ! tofu init -no-color >/dev/null; then failed="$failed $root"; continue; fi

  set +e
  tofu plan -no-color -detailed-exitcode -out=plan.bin >plan.log
  rc=$?
  set -e
  case $rc in
    0) echo "no changes"; continue ;;
    2) ;;
    *) cat plan.log; failed="$failed $root"; continue ;;
  esac

  blocked=$(tofu show -json plan.bin | jq -r --argjson allowed "$ALLOWED_TYPES" '
    .resource_changes[]?
    | select(.mode == "managed" and .change.actions != ["no-op"])
    | select((.type as $t | $allowed | index($t)) == null or .change.actions == ["delete"])
    | "\(.address) \(.change.actions | join(","))"')
  if [ -n "$blocked" ]; then
    echo "not applying; changes outside the allowed set:"
    echo "$blocked"
    failed="$failed $root"
    continue
  fi

  tofu show -no-color plan.bin | grep -E '^\s+# ' || true
  tofu apply -no-color plan.bin || failed="$failed $root"
done

if [ -n "$failed" ]; then
  echo "FAILED:$failed"
  exit 1
fi
