# BAR development environment — canonical list of system dependencies.
# Used with distrobox: just setup::distrobox
# Or as a reference for manual installs on any distro
FROM registry.fedoraproject.org/fedora:43

RUN dnf install -y --setopt=install_weak_deps=False \
        compat-lua compat-lua-devel readline-devel \
        nodejs npm \
        rust cargo \
        clang-tools-extra cmake \
        just \
        gcc gcc-c++ make git curl jq unzip binutils \
        gawk \
        gpgme \
        SDL2-devel DevIL-devel glew-devel openal-soft-devel \
        libvorbis-devel freetype-devel fontconfig-devel \
        libunwind-devel libcurl-devel jsoncpp-devel minizip-devel \
        expat-devel libXcursor-devel p7zip \
    && dnf clean all \
    && ln -s /usr/bin/lua-5.1 /usr/local/bin/lua

# lux (lumen-oss/lux) is fetched via cargo-binstall instead of a hand-rolled
# GitHub Releases query. cargo-binstall recognizes a wide range of asset
# naming conventions, so when upstream renames or repackages (as lux did at
# v0.29.0, dropping .deb in favor of tarballs) we don't have to chase it
# here. Bootstrap cargo-binstall first since neither Fedora's repos nor the
# stock `cargo` package ships it.
RUN curl -L --proto '=https' --tlsv1.2 -sSf \
        https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh \
      | bash

# Bump in lockstep with .github/workflows/test_unit.yml in the BAR repo.
# Pass `--build-arg LUX_VERSION=X.Y.Z` to override locally.
ARG LUX_VERSION=0.28.3
RUN /root/.cargo/bin/cargo-binstall --no-confirm \
        ${LUX_VERSION:+--version $LUX_VERSION} \
        --install-path /usr/local/bin \
        lux-cli \
    && mv /root/.cargo/bin/cargo-binstall /usr/local/bin/ \
    && rm -rf /root/.cargo

# No `lx install-lua`: lux uses the system Lua 5.1 (compat-lua, symlinked to
# `lua` above) directly -- that build has dlopen, so C rocks (luafilesystem,
# busted's deps) compile and load. `install-lua` instead builds lux's own Lua
# *without* dlopen, which then has to be patched back out. Mirrors BAR's
# .github/workflows/test_unit.yml, which also skips it.

# stylua is installed directly rather than via `lx install` because BAR has
# luarocks-conformant trees (non-src/ layouts) that we need to format, and
# lux's tool runner only resolves targets under src/ today. Track:
# https://github.com/lumen-oss/lux/issues/953
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
