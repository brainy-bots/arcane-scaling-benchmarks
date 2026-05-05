#!/bin/bash
# Driver user-data. Installs Docker + AWS CLI v2. Nothing else — the benchmark
# image carries every binary, module, and orchestration script the run needs.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y ca-certificates curl gnupg unzip

# Docker engine (upstream repo, distro-codename pinned).
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io

# Raise host-level file-descriptor ceilings so clean-clone repros do not depend
# on ambient distro defaults. Containers also set --ulimit, but these host
# settings keep the node baseline reproducible across Ubuntu AMI revisions.
cat >/etc/security/limits.d/99-arcane-benchmark-nofile.conf <<'EOF'
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF
cat >/etc/sysctl.d/99-arcane-benchmark-fd.conf <<'EOF'
fs.file-max = 1048576
EOF
sysctl --system >/dev/null

# Ensure the Docker daemon itself is not constrained by default systemd limits.
install -d -m 0755 /etc/systemd/system/docker.service.d
cat >/etc/systemd/system/docker.service.d/99-arcane-benchmark-limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
systemctl daemon-reload
systemctl enable --now docker

# AWS CLI v2 (SSM workload uses it to sync results into S3).
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip
