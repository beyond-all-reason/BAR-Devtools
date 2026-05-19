# bar-sync: WSL-only container for the filesystem mirror daemon.
# Pinned to fc42: Meta only publishes fc42 watchman RPMs, and they link
# libdwarf.so.0 which fc43 dropped.
FROM registry.fedoraproject.org/fedora:42

RUN dnf install -y --setopt=install_weak_deps=False \
        python3 python3-pip python3-devel \
        gcc \
        rsync \
        inotify-tools \
        curl jq \
    && pip3 install --break-system-packages --no-cache-dir pywatchman \
    && dnf remove -y gcc python3-devel \
    && dnf clean all

# Keep in lockstep with docker/dev.Containerfile.
ARG WATCHMAN_VERSION=v2026.05.04.00
RUN ARCH=$(uname -m) \
    && [ "$ARCH" = "x86_64" ] \
       || { echo "Watchman: only x86_64 RPM is published by Meta; got $ARCH" >&2; exit 1; } \
    && URL=$(curl -fsSL "https://api.github.com/repos/facebook/watchman/releases/tags/${WATCHMAN_VERSION}" \
       | jq -r '.assets[] | select(.name | test("\\.x86_64\\.rpm$")) | .browser_download_url') \
    && [ -n "$URL" ] && [ "$URL" != "null" ] \
       || { echo "Watchman: no x86_64.rpm asset on tag ${WATCHMAN_VERSION}" >&2; exit 1; } \
    && curl -fsSL "$URL" -o /tmp/watchman.rpm \
    && dnf install -y /tmp/watchman.rpm \
    && rm /tmp/watchman.rpm

LABEL com.github.containers.toolbox="true"
