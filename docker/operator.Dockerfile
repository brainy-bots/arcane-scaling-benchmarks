FROM rust:1.95-bookworm AS controller-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      pkg-config libssl-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Build benchmark-controller with its path dependency on arcane-swarm-orchestrator.
COPY crates/benchmark-controller/ crates/benchmark-controller/
COPY arcane_swarm/crates/arcane-swarm-orchestrator/ arcane_swarm/crates/arcane-swarm-orchestrator/

RUN cargo build --release --manifest-path crates/benchmark-controller/Cargo.toml

FROM mcr.microsoft.com/powershell:7.4-debian-12

ARG TERRAFORM_VERSION=1.9.8
ARG AWSCLI_VERSION=2.17.53

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip jq \
    && rm -rf /var/lib/apt/lists/*

# Terraform
RUN curl -fsSLo /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    && unzip /tmp/terraform.zip -d /usr/local/bin \
    && rm -f /tmp/terraform.zip

# AWS CLI v2
RUN curl -fsSLo /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

WORKDIR /workspace

# Copy only what the operator path needs.
COPY infra/ infra/
COPY plans/ plans/
COPY docker/benchmark-publish-module.sh docker/benchmark-publish-module.sh

# Place the controller binary where Run-Benchmark-Aws-Controller.ps1 auto-discovers it.
COPY --from=controller-builder /src/crates/benchmark-controller/target/release/benchmark-controller /workspace/crates/benchmark-controller/target/release/benchmark-controller

COPY docker/operator-entrypoint.sh /usr/local/bin/operator-entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/operator-entrypoint.sh /workspace/docker/benchmark-publish-module.sh \
    && chmod +x /usr/local/bin/operator-entrypoint.sh /workspace/docker/benchmark-publish-module.sh

ENTRYPOINT ["/usr/local/bin/operator-entrypoint.sh"]
