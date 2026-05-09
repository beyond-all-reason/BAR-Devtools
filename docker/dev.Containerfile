# BAR development environment — canonical list of system dependencies.
# Used with distrobox: just setup::distrobox
# Or as a reference for manual installs on any distro / WSL / macOS (brew).
# Pinned to fc42 because that's the Meta watchman RPM's target (kept in
# the WSL-only sister container docker/sync.Containerfile). Same base image
# for both keeps interactive dev shells (`distrobox enter bar-dev`) feeling
# the same as the sync container's runtime.
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

# lumen-oss/lux dropped .deb packaging at v0.29.0 in favor of plain
# tarballs named lx-<arch>-unknown-linux-gnu.tar.gz. Extract `lx` straight
# into /usr/local/bin -- no ar/dpkg dance needed anymore.
ARG LUX_VERSION=latest
RUN ARCH=$(uname -m) \
    && case "$ARCH" in x86_64|aarch64) ;; *) echo "unsupported: $ARCH" >&2; exit 1;; esac \
    && URL=$(curl -fsSL "https://api.github.com/repos/lumen-oss/lux/releases/${LUX_VERSION}" \
       | jq -r --arg arch "$ARCH" '.assets[] | select(.name == "lx-" + $arch + "-unknown-linux-gnu.tar.gz") | .browser_download_url') \
    && [ -n "$URL" ] && [ "$URL" != "null" ] \
       || { echo "lux: no asset for arch $ARCH on tag ${LUX_VERSION}" >&2; exit 1; } \
    && curl -fsSL "$URL" | tar xz -C /usr/local/bin \
    && chmod +x /usr/local/bin/lx

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

LABEL com.github.containers.toolbox="true"
