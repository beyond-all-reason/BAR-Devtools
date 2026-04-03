# BAR development environment — canonical list of system dependencies.
# Used with distrobox: just setup::distrobox
# Or as a reference for manual installs on any distro / WSL / macOS (brew).
FROM registry.fedoraproject.org/fedora:latest

RUN dnf install -y --setopt=install_weak_deps=False \
        compat-lua compat-lua-devel readline-devel \
        nodejs npm \
        rust cargo \
        clang-tools-extra cmake \
        just \
        gcc gcc-c++ make git curl jq unzip binutils \
        SDL2-devel DevIL-devel glew-devel openal-soft-devel \
        libvorbis-devel freetype-devel fontconfig-devel \
        libunwind-devel libcurl-devel jsoncpp-devel minizip-devel \
        expat-devel libXcursor-devel p7zip \
    && dnf clean all \
    && ln -s /usr/bin/lua-5.1 /usr/local/bin/lua

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

ARG EMMYLUA_VERSION=latest
RUN ARCH=$(uname -m) \
    && case "$ARCH" in x86_64) PLAT=linux-x64;; aarch64) PLAT=linux-arm64;; esac \
    && URL=$(curl -fsSL "https://api.github.com/repos/EmmyLuaLs/emmylua-analyzer-rust/releases/${EMMYLUA_VERSION}" \
       | jq -r --arg plat "emmylua_ls-${PLAT}.tar.gz" '.assets[] | select(.name == $plat) | .browser_download_url') \
    && curl -fsSL "$URL" | tar xz -C /usr/local/bin \
    && chmod +x /usr/local/bin/emmylua_ls

LABEL com.github.containers.toolbox="true"
