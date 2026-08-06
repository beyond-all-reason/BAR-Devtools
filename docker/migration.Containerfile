# The dev environment plus a prebuilt bar-lua-codemod, for running bulk
# migrations in CI (BAR's .github/workflows/bulk_migration.yml).
#
# Kept out of dev.Containerfile deliberately. That image is the distrobox
# contributors live in: it should not rebuild because codemod source changed,
# and a baked binary would be shadowed by their own target/ build anyway. Here
# the binary is the point -- CI has no target/ to build into and no reason to
# spend ~2.5 minutes on cargo every run.
#
# BASE is pinned by the publishing workflow to the dev image built in the same
# run, so the two can never be a version apart.
ARG BASE=ghcr.io/beyond-all-reason/bar-dev:latest

# The base already carries rust and cargo, so it doubles as the build stage.
# target/ is ~260MB against 44KB of source; only the binary crosses over.
FROM ${BASE} AS build
COPY bar-lua-codemod /src
RUN cd /src && cargo build --release

FROM ${BASE}
COPY --from=build /src/target/release/bar-lua-codemod /usr/local/bin/bar-lua-codemod
