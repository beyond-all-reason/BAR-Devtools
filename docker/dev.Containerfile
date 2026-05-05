# BAR development environment — canonical list of system dependencies.
# Used with distrobox: just setup::distrobox
# Or as a reference for manual installs on any distro / WSL / macOS (brew).
# Pinned to fc42: Meta's watchman RPM (v2026.05.04.00) is built against
# fc42 libs (boost 1.83, libglog.so.0, libdwarf.so.0). fc44+ bumps Boost
# and breaks the install. Bump in lockstep when Meta cuts a new release.
FROM registry.fedoraproject.org/fedora:42

RUN dnf install -y --setopt=install_weak_deps=False \
        compat-lua compat-lua-devel readline-devel \
        nodejs npm \
        rust cargo \
        clang-tools-extra cmake \
        just \
        gcc gcc-c++ make git curl jq unzip binutils \
        gawk \
        SDL2-devel DevIL-devel glew-devel openal-soft-devel \
        libvorbis-devel freetype-devel fontconfig-devel \
        libunwind-devel libcurl-devel jsoncpp-devel minizip-devel \
        expat-devel libXcursor-devel p7zip \
    && (dnf install -y starship || curl -sS https://starship.rs/install.sh | sh -s -- -y -b /usr/local/bin) \
    && dnf clean all \
    && ln -s /usr/bin/lua-5.1 /usr/local/bin/lua

# Enable starship for `distrobox enter bar-dev` interactive sessions without
# touching the user's host ~/.bashrc. Login shells source /etc/profile.d/*
# BEFORE the user's home rc files, so any custom PS1 they have wins. Recipes
# that auto-enter via enter_distrobox run `bash -s` (non-interactive,
# non-login) and skip profile.d entirely -- zero overhead for `just bar::*`.
RUN printf '%s\n' \
        '# /etc/profile.d/starship.sh -- baked by dev.Containerfile' \
        '# User PS1 in ~/.bashrc still wins (loaded after this).' \
        'command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"' \
    > /etc/profile.d/starship.sh \
    && chmod 0644 /etc/profile.d/starship.sh

ARG LUX_VERSION=latest
RUN ARCH=$(uname -m) \
    && case "$ARCH" in x86_64) DEB_ARCH=amd64;; aarch64) DEB_ARCH=arm64;; *) echo "unsupported: $ARCH" >&2; exit 1;; esac \
    && DEB_URL=$(curl -fsSL "https://api.github.com/repos/lumen-oss/lux/releases/${LUX_VERSION}" \
       | jq -r --arg arch "$DEB_ARCH" '.assets[] | select(.name | test("_" + $arch + "\\.deb$")) | .browser_download_url') \
    && curl -fsSL "$DEB_URL" -o /tmp/lux.deb \
    && cd /tmp && ar x lux.deb \
    && tar xf data.tar.* -C / \
    && rm -f /tmp/lux.deb /tmp/data.tar.* /tmp/control.tar.* /tmp/debian-binary

# lux's bundled lua 5.1 lacks dlopen, breaking C modules like luafilesystem.
# Symlink the system lua-5.1 over it so lx test / lx shell work correctly.
RUN lx --lua-version 5.1 install-lua \
    && ln -sf /usr/bin/lua-5.1 /root/.local/share/lux/tree/5.1/.lua/bin/lua

ARG STYLUA_VERSION=2.0.2
RUN ARCH=$(uname -m) \
    && case "$ARCH" in x86_64) PLAT=linux-x86_64;; aarch64) PLAT=linux-aarch64;; esac \
    && curl -fsSL "https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/stylua-${PLAT}.zip" \
       -o /tmp/stylua.zip \
    && unzip -o /tmp/stylua.zip -d /usr/local/bin \
    && chmod +x /usr/local/bin/stylua \
    && rm /tmp/stylua.zip

# emmylua_ls and emmylua_check are distrobox-exported by `just setup::editor`,
# so the host-side wrappers always use this exact version. Direct download
# (no GitHub API hop) — `/releases/<tag>` isn't a valid endpoint, only
# `/releases/tags/<tag>` is, and unauthenticated API requests rate-limit
# to 60/hour anyway. The release-asset CDN has neither problem.
ARG EMMYLUA_VERSION=0.22.0
RUN ARCH=$(uname -m) \
    && case "$ARCH" in \
         x86_64)  LS_ASSET="emmylua_ls-linux-x64.tar.gz";              CHECK_ASSET="emmylua_check-linux-x64.tar.gz" ;; \
         aarch64) LS_ASSET="emmylua_ls-linux-arm64-glibc.2.17.tar.gz"; CHECK_ASSET="emmylua_check-linux-arm64-glibc.2.17.tar.gz" ;; \
         *) echo "unsupported arch for EmmyLua binaries: $ARCH" >&2; exit 1;; \
       esac \
    && BASE="https://github.com/EmmyLuaLs/emmylua-analyzer-rust/releases/download/${EMMYLUA_VERSION}" \
    && curl -fsSL "$BASE/$LS_ASSET"    | tar xz -C /usr/local/bin \
    && curl -fsSL "$BASE/$CHECK_ASSET" | tar xz -C /usr/local/bin \
    && chmod +x /usr/local/bin/emmylua_ls /usr/local/bin/emmylua_check

# Watchman: Meta publishes a current Fedora RPM but does NOT run an apt
# repo, and explicitly warns against the distro-shipped 4.9.0. Inside the
# Fedora container the install is one dnf call against the release RPM.
# sync.py uses watchman for "what changed since clock T" queries to skip
# the 80s rsync stat-walk on daemon restart; setup.sh exposes it on the
# host via distrobox-export.
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
