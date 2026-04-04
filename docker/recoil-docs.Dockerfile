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

COPY go.mod go.sum hugo.toml ./
RUN MISE_ENV=ci mise exec -- hugo mod get

ENTRYPOINT ["mise", "run"]
