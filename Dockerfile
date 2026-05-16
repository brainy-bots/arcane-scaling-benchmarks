# Single image for the whole benchmark. Built once in CI, pushed to GHCR, pulled
# and run with different commands on Redis, SpacetimeDB, manager, cluster, and
# load-generator roles. No compilation happens at benchmark runtime — that is
# the whole point.
#
# Roles (pick one via the docker run command):
#   docker run IMG spacetime start                     # SpacetimeDB server role
#   docker run IMG benchmark-publish-module            # Publish WASM module into an already-running SpacetimeDB
#   docker run IMG arcane-manager                      # Arcane manager role
#   docker run IMG benchmark-cluster                   # Arcane node role (physics + game actions)
#   docker run IMG arcane-swarm <args>                 # Load generator role
#   docker run IMG run-benchmark <...>                 # Driver: reads -ConfigFile; scenario is selected by the config
#
# Build locally:
#   docker build -t arcane-benchmark:dev .
#
# The CI workflow (.github/workflows/docker-publish.yml) pushes to
#   ghcr.io/brainy-bots/arcane-benchmark:<tag>
# on any `v*` git tag.

# ──────────────────────────────────────────────────────────────────────────
# Stage 1 — rust builder. Produces the three Arcane-side binaries and both
#           benchmark WASM modules. Never ends up in the final image.
# ──────────────────────────────────────────────────────────────────────────
FROM rust:1.95-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      pkg-config libssl-dev ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN rustup target add wasm32-unknown-unknown

# SpacetimeDB CLI — used for `spacetime build` so the WASM modules are produced
# the same way the server expects to load them (not just raw cargo output).
RUN curl -sSf https://install.spacetimedb.com | sh -s -- -y
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /build

# Copy the three source trees we own. Order is chosen to maximize layer cache
# reuse when only benchmark code changes.
COPY arcane/ arcane/
COPY arcane_swarm/ arcane_swarm/
COPY crates/ crates/

# arcane-manager (HTTP join server) and arcane-node are both in the arcane
# workspace; build them with the features they need.
RUN cargo build --release --manifest-path arcane/Cargo.toml \
      --bin arcane-manager --features manager

# benchmark-cluster is the Arcane cluster binary wired to the BenchmarkSimulation.
# It lives in crates/benchmark-cluster and depends on arcane/ as path deps.
RUN cargo build --release --manifest-path crates/benchmark-cluster/Cargo.toml \
      --bin benchmark-cluster

# arcane-swarm (load generator) lives in its own submodule workspace.
RUN cargo build --release --manifest-path arcane_swarm/Cargo.toml \
      --package arcane-swarm --bin arcane-swarm

# arcane-swarm-orchestrator: standalone orchestrator process. Drivers connect
# to it via WebSocket; controllers submit commands via HTTP POST and consume
# its telemetry SSE.
RUN cargo build --release --manifest-path arcane_swarm/Cargo.toml \
      --package arcane-swarm-orchestrator --bin arcane-swarm-orchestrator

# benchmark-controller: drives the orchestrator from a TOML test plan.
# Operators normally run this from a laptop, but baking it into the image
# lets us also run it on EC2 for cloud-side reproducibility tests.
RUN cargo build --release --manifest-path crates/benchmark-controller/Cargo.toml \
      --bin benchmark-controller

# Benchmark WASM modules for the two SpacetimeDB modes. Built with `spacetime build`
# so the output matches what the SpacetimeDB runtime expects to load.
RUN spacetime build --module-path crates/benchmark-spacetimedb-full
RUN spacetime build --module-path crates/benchmark-spacetimedb-persist

# ──────────────────────────────────────────────────────────────────────────
# Stage 2 — final runtime. Based on clockworklabs/spacetime so the SpacetimeDB
#           server role works out of the box. Our Rust binaries and WASM modules
#           are copied in on top.
# ──────────────────────────────────────────────────────────────────────────
FROM clockworklabs/spacetime:v2.1.0

USER root

# PowerShell is installed for the "run-benchmark" driver role, which invokes
# scripts/Run-Benchmark.ps1 inside the container. All other roles are plain
# bash or direct binaries.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libssl3 curl gnupg \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/microsoft-debian-bookworm-prod bookworm main" > /etc/apt/sources.list.d/microsoft.list \
    && apt-get update && apt-get install -y --no-install-recommends powershell \
    && rm -rf /var/lib/apt/lists/*

# Arcane-side binaries
COPY --from=builder /build/arcane/target/release/arcane-manager                                         /usr/local/bin/arcane-manager
COPY --from=builder /build/crates/benchmark-cluster/target/release/benchmark-cluster                    /usr/local/bin/benchmark-cluster
COPY --from=builder /build/arcane_swarm/target/release/arcane-swarm                                     /usr/local/bin/arcane-swarm
COPY --from=builder /build/arcane_swarm/target/release/arcane-swarm-orchestrator                        /usr/local/bin/arcane-swarm-orchestrator
COPY --from=builder /build/crates/benchmark-controller/target/release/benchmark-controller              /usr/local/bin/benchmark-controller

# WASM modules — stable paths consumed by benchmark-publish-module below.
COPY --from=builder /build/crates/benchmark-spacetimedb-full/target/wasm32-unknown-unknown/release/benchmark_spacetimedb_full.wasm        /opt/modules/benchmark_spacetimedb_full.wasm
COPY --from=builder /build/crates/benchmark-spacetimedb-persist/target/wasm32-unknown-unknown/release/benchmark_spacetimedb_persist.wasm /opt/modules/benchmark_spacetimedb_persist.wasm

# Scripts for the driver roles. The pwsh orchestrators iterate player tiers,
# invoke arcane-swarm (on PATH inside this image), and write CSVs to
# /var/benchmark/out which the caller is expected to mount.
#
# Configs are intentionally NOT baked in. The cloud orchestrator stages the
# selected config to S3 per run and the driver mounts it at
# /opt/benchmark/runtime-configs/<filename> via `docker run -v`. This lets
# researchers add new sibling configs locally and run them without rebuilding
# the image; the only reason to cut a new image is a code change to scripts/
# or any of the Rust binaries baked above.
COPY scripts/ /opt/benchmark/scripts/

# Helpers exposed as role commands.
COPY docker/benchmark-publish-module.sh /usr/local/bin/benchmark-publish-module
COPY docker/run-benchmark.sh            /usr/local/bin/run-benchmark
RUN chmod +x /usr/local/bin/benchmark-publish-module /usr/local/bin/run-benchmark

# The spacetime base image already sets an entrypoint that runs `spacetime`; we
# reset it so the command decides the role cleanly.
ENTRYPOINT []
CMD ["spacetime", "start"]
