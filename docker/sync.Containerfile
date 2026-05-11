# bar-sync: minimal WSL-only container for the filesystem mirror daemon.
#
# Why this is its own container instead of riding in bar-dev:
# bar-dev is a cross-platform dev environment (lux, stylua, emmylua, lua libs)
# that Linux-native contributors also enter. The sync daemon, by contrast, is
# a WSL-only concern -- it bridges /home/daniel/code (ext4) -> /mnt/c (drvfs)
# so spring.exe on Windows can read what the user just edited in Linux. Linux
# natives never run sync.py at all.
#
# Putting sync deps in bar-dev would force every Linux contributor to pull
# watchman + pywatchman they'll never use. Splitting keeps each container's
# purpose clean: bar-dev for "I'm developing BAR," bar-sync for "I'm bridging
# the WSL/Windows boundary."
#
# Watchman install is duplicated from docker/dev.Containerfile (Meta's RPM
# pin matters). Bump in lockstep when Meta cuts a new release.
FROM registry.fedoraproject.org/fedora:43

# python3 is in the base image; we need pywatchman for the subscription API
# and rsync for the actual file copy. inotify-tools is handy for live debug
# (watchman uses inotify under the hood, so the limit / kernel events show
# up the same way they would for inotify-tools).
#
# pywatchman isn't packaged in Fedora's repos and isn't in Meta's watchman
# RPM either, so we pip-install it system-wide. This container has exactly
# one job, so PEP 668's "externally-managed" marker doesn't add safety here
# -- override it once at build time and we're done.
RUN dnf install -y --setopt=install_weak_deps=False \
        python3 python3-pip python3-devel \
        gcc \
        rsync \
        inotify-tools \
        curl jq \
    && pip3 install --break-system-packages --no-cache-dir pywatchman \
    && dnf remove -y gcc python3-devel \
    && dnf clean all

# Watchman (kept in lockstep with docker/dev.Containerfile).
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
