# Pre-warmed self-hosted runner image for the github-arc scale sets.
#
# Bakes in what ephemeral jobs would otherwise download every run:
#   - Node 22 and Temurin JDK 17 in the runner tool cache, so
#     actions/setup-node and actions/setup-java find them and skip the download
#   - Android SDK platforms/build-tools/NDK/cmake with licences accepted, so
#     android-actions/setup-android and AGP have nothing to fetch
#   - Gradle 9.0.0 wrapper distribution in ~/.gradle/wrapper/dists
#   - azure-cli
#   - nix (single-user, owned by runner) for `nix develop` based workflows
#
# Trim whatever your workflows don't need. Build with ./build.sh (see README.md).
FROM ghcr.io/actions/actions-runner:latest

USER root
ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg jq unzip zip xz-utils git \
      build-essential python3 lsb-release \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ noble main" > /etc/apt/sources.list.d/azure-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends azure-cli \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -o runner -g runner /opt/hostedtoolcache /opt/android-sdk /nix

# Everything below is installed as the runner user so no chown pass is needed
# (a recursive chown over the SDK/NDK copies every file up a layer).
USER runner

# --- Node 22 -> runner tool cache (layout expected by actions/setup-node) ----
ARG NODE_MAJOR=22
RUN set -eux; \
    ver=$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/SHASUMS256.txt" \
          | grep -oE 'node-v[0-9.]+-linux-x64\.tar\.xz' | head -1 | sed -E 's/node-v([0-9.]+)-linux-x64\.tar\.xz/\1/'); \
    d=/opt/hostedtoolcache/node/$ver/x64; mkdir -p "$d"; \
    curl -fsSL "https://nodejs.org/dist/v$ver/node-v$ver-linux-x64.tar.xz" | tar -xJ --strip-components=1 -C "$d"; \
    touch "$d.complete"; \
    sudo ln -s "$d" /opt/node

# --- Temurin JDK 17 -> runner tool cache (layout expected by actions/setup-java)
ARG JAVA_MAJOR=17
RUN set -eux; \
    json=$(curl -fsSL "https://api.adoptium.net/v3/assets/latest/${JAVA_MAJOR}/hotspot?architecture=x64&image_type=jdk&os=linux&vendor=eclipse"); \
    url=$(echo "$json" | jq -r '.[0].binary.package.link'); \
    ver=$(echo "$json" | jq -r '.[0].release_name' | sed -E 's/^jdk-//; s/\+/-/'); \
    d=/opt/hostedtoolcache/Java_Temurin-Hotspot_jdk/$ver/x64; mkdir -p "$d"; \
    curl -fsSL "$url" | tar -xz --strip-components=1 -C "$d"; \
    touch "$d.complete"; \
    sudo ln -s "$d" /opt/java
ENV JAVA_HOME=/opt/java
ENV PATH=/opt/java/bin:/opt/node/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:$PATH

# --- Android SDK (versions from Expo 55 / RN 0.83 defaults) ------------------
ARG CMDLINE_TOOLS_BUILD=13114758
ARG ANDROID_PACKAGES="platform-tools platforms;android-36 platforms;android-35 build-tools;36.0.0 build-tools;35.0.0 ndk;27.1.12297006 cmake;3.22.1"
RUN set -eux; \
    mkdir -p "$ANDROID_HOME/cmdline-tools"; \
    curl -fsSL -o /tmp/ct.zip "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_BUILD}_latest.zip"; \
    unzip -q /tmp/ct.zip -d /tmp/ct && mv /tmp/ct/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"; \
    rm -rf /tmp/ct /tmp/ct.zip; \
    yes | sdkmanager --licenses >/dev/null; \
    sdkmanager --install $ANDROID_PACKAGES >/dev/null; \
    rm -rf "$ANDROID_HOME"/.temp /home/runner/.android

# --- Gradle 9.0.0 wrapper distribution into ~/.gradle/wrapper/dists ----------
ARG GRADLE_VERSION=9.0.0
RUN set -eux; cd /tmp && mkdir gw && cd gw; \
    curl -fsSL -o g.zip "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"; \
    unzip -q g.zip; touch settings.gradle; \
    ./gradle-${GRADLE_VERSION}/bin/gradle wrapper --gradle-version "${GRADLE_VERSION}" --no-daemon -q; \
    ./gradlew --version --no-daemon >/dev/null; \
    cd / && rm -rf /tmp/gw /home/runner/.gradle/daemon /home/runner/.gradle/native

# --- Nix: single-user install owned by runner --------------------------------
# With cache_host_dir set, /nix is replaced at runtime by a per-node hostPath
# (see ../main.tf) that the
# seed-ci-caches init container populates from this image's store with
# `nix copy`, so the store survives across jobs. /opt/nix-bin is a stable path
# to the nix binaries that does not depend on profile symlinks. No min-free
# here: GC of the shared store is scheduled (../nix-gc.sh) and the pods' NIX_CONFIG
# sets the emergency floor; a value here would be overridden anyway.
ENV NIX_INSTALLER_NO_MODIFY_PROFILE=1
RUN set -eux; \
    curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon --yes; \
    mkdir -p /home/runner/.config/nix; \
    printf 'experimental-features = nix-command flakes\n' > /home/runner/.config/nix/nix.conf; \
    sudo ln -s "$(dirname "$(readlink -f /home/runner/.nix-profile/bin/nix)")" /opt/nix-bin; \
    /opt/nix-bin/nix --version
ENV PATH=/opt/nix-bin:$PATH

WORKDIR /home/runner
