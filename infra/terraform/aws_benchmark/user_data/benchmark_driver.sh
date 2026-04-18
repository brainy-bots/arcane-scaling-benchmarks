#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl git gnupg unzip pkg-config libssl-dev build-essential
curl -sSf https://install.spacetimedb.com | sh -s -- -y
export PATH="/root/.local/bin:$PATH"
curl -LO https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell_7.4.6-1.deb_amd64.deb
dpkg -i powershell_7.4.6-1.deb_amd64.deb || apt-get install -f -y
rm -f powershell_7.4.6-1.deb_amd64.deb
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip
