FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git \
        build-essential pkg-config \
        libssl-dev zlib1g-dev libyaml-dev libffi-dev libreadline-dev \
        p7zip-full \
        libsdl2-2.0-0 libxcursor1 libx11-6 libopenal1 \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-c"]

RUN curl https://mise.run | sh
ENV PATH="/root/.local/bin:/root/.local/share/mise/shims:${PATH}"

WORKDIR /recoil/doc/site
COPY mise.toml mise.ci.toml ./

RUN mise trust . && \
    mise use -g node@lts rust@stable go@latest && \
    MISE_ENV=ci mise install

# lua-language-server is task-scoped (used by lua_check) and isn't installed
# by `mise install` since mise.ci.toml doesn't list it. Pre-install it so
# runtime users (which can't write to the root-owned data dir) don't trip
# trying to install it on first run.
ARG LUA_LANGUAGE_SERVER_VERSION=3.15.0
RUN MISE_ENV=ci mise use -g lua-language-server@${LUA_LANGUAGE_SERVER_VERSION}

COPY go.mod go.sum hugo.toml ./
RUN MISE_ENV=ci mise exec -- hugo mod get

# Make the mise install/state readable+executable by any uid so this image
# can run as the host user (compose passes `user: ${UID}:${GID}` so files
# the extractor writes to the mounted /recoil tree end up host-owned, not
# root-owned — otherwise host-side `git clean`/`rm` of generated/ fails).
#
# lua-language-server generates per-locale/version meta files inside its
# install dir on first run (e.g. `meta/Lua 5.4 en-us utf8/`); make that
# subtree world-writable so any uid can populate it. Everything else
# stays read-only.
RUN chmod -R a+rX /root /root/.local && \
    chmod -R a+rwX /root/.local/share/mise/installs/lua-language-server

# Mise looks at $XDG_DATA_HOME/mise (or $HOME/.local/share/mise) for installed
# tools. Pin both so a non-root runtime user picks up the root-installed
# tools. HOME=/tmp keeps mise's runtime cache writable for any uid.
# MISE_TRUSTED_CONFIG_PATHS short-circuits mise's per-user trust check so the
# root-side `mise trust .` from build time carries over to the runtime user.
ENV HOME=/tmp \
    MISE_DATA_DIR=/root/.local/share/mise \
    MISE_GLOBAL_CONFIG_FILE=/root/.config/mise/config.toml \
    MISE_TRUSTED_CONFIG_PATHS=/recoil/doc/site/mise.toml:/recoil/doc/site/mise.ci.toml:/root/.config/mise/config.toml

ENTRYPOINT ["mise", "run"]
