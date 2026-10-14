# Pre-warmed runner image

Derived from `ghcr.io/actions/actions-runner:latest` with a toolchain already
installed, so ephemeral jobs stop re-downloading it. It's an example: edit the
Dockerfile to match what your workflows use.

| Baked in                      | Replaces per-job                              |
|-------------------------------|-----------------------------------------------|
| Node 22 in tool cache         | actions/setup-node download                   |
| Temurin JDK 17 in tool cache  | actions/setup-java download                   |
| Android SDK 35/36, NDK 27.1, cmake, licences accepted | android-actions/setup-android + AGP downloads |
| Gradle 9.0.0 wrapper dist     | gradlew distribution download                 |
| azure-cli                     | `apt-get install azure-cli` in jobs           |
| nix (single-user, `/opt/nix-bin`) | installing nix per job; required for `enable_nix` |

The setup-* actions still run; they find the tool-cache entries (the image
sets `RUNNER_TOOL_CACHE=/opt/hostedtoolcache`) and skip the download. No
workflow changes are required. If a workflow asks for a version that isn't
baked in, the setup action downloads it as usual.

## Build and roll out

Push to a registry the cluster can pull from:

```
IMAGE_REPO=ghcr.io/me/actions-runner PUSH=1 ./build.sh
```

Or, on a single k3s node with runners pinned to it, skip the registry:

```
K3S_IMPORT=1 ./build.sh
```

Then set `runner_image` in `../terraform.tfvars` and run `tofu -chdir=.. apply`.
A non-`:latest` tag uses `imagePullPolicy: IfNotPresent`, so an imported image
is used as-is.
