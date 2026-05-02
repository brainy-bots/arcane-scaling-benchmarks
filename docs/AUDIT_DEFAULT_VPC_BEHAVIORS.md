# Default-VPC Behaviors Audit

**Issue:** #70 — "Terraform: audit `aws_vpc.bench` for default-VPC behaviors not carried over"
**Date:** 2026-05-02
**Auditor:** `/arcane-worker`

## Scope 1: DNS settings on `aws_vpc.bench`

**Status: ✅ Already applied (PR #71, now on `main`)**

The following settings are present on `aws_vpc.bench` in `infra/terraform/aws_benchmark/networking.tf`:

```hcl
enable_dns_support   = true  # Preserve default VPC behavior (required for DNS resolution)
enable_dns_hostnames = true  # Preserve default VPC behavior (enables EC2 public DNS hostnames)
```

Both carry one-line comments explaining they preserve default-VPC behavior. No additional Terraform changes needed.

## Scope 2: Audit for EC2 public DNS hostname references

**Result: No references found — the `enable_dns_hostnames = true` change is purely defensive.**

Searched the entire repository for:

| Pattern | Files searched | Hits |
|---|---|---|
| `compute.amazonaws.com` | All files | 0 |
| `compute-1.amazonaws.com` | All files | 0 |
| `public_dns` / `PublicDnsName` / `publicDns` | All files | 0 |
| `aws_instance.*.public_dns` | Terraform files | 0 |
| `aws_instance.*.public_ip` | Terraform files | 0 |
| Hostname-from-instance-ID construction | PowerShell, Bash, Rust | 0 |

**Details:**

- **Terraform outputs** (`outputs.tf`): Outputs only reference instance IDs (`.id`), never `.public_dns`, `.public_ip`, or `.private_dns`.
- **PowerShell scripts** (`RemoteBenchmark.ps1`, `Run-Benchmark-Aws.ps1`, etc.): Commands use SSM (by instance ID) and private IPs (`Get-Ec2PrivateIp`). No code path constructs or relies on EC2 public DNS hostnames.
- **Bash scripts** (user-data `benchmark_driver.sh`, `docker_only.sh`): Only install Docker + AWS CLI. No hostname manipulation.
- **Rust, Dockerfiles, config files**: No public DNS hostname strings found.

The benchmark stack communicates entirely via private IPs and SSM. No code path depends on EC2 public DNS hostnames.

## Scope 3: Audit for other default-VPC behaviors

| Behavior | Status | Evidence |
|---|---|---|
| **Internet egress via default IGW** | ✅ Handled (#69) | `aws_internet_gateway.bench` + `aws_route_table.bench` with `0.0.0.0/0` route in `networking.tf` |
| **Subnet auto-assigns public IPs** | ✅ Handled (#69) | `map_public_ip_on_launch = true` on `aws_subnet.bench` in `networking.tf` |
| **DNS resolution (AmazonProvidedDNS)** | ✅ Verified — no custom DHCP options | No `aws_vpc_dhcp_options` resource exists; VPC inherits AmazonProvidedDNS (same as default VPCs) |
| **DNS hostnames** | ✅ Handled (#71) | `enable_dns_hostnames = true` on `aws_vpc.bench` |
| **DNS support** | ✅ Handled (#71) | `enable_dns_support = true` on `aws_vpc.bench` |
| **Security group outbound (all traffic)** | ✅ Explicit | `egress { cidr_blocks = ["0.0.0.0/0"] }` in `security_groups.tf` |
| **Instance metadata (IMDSv2)** | ✅ Explicit | `metadata_options { http_tokens = "required" }` on every `aws_instance` in `ec2_spacetime.tf` and `ec2_arcane.tf` |
| **VPC endpoints / NAT gateways / VPN** | ✅ Not needed | No VPC endpoints, NAT gateways, or VPN connections exist. Benchmark nodes reach the internet via the IGW and route table. |

No other gaps were identified.

## Out of scope

Non-VPC AWS defaults (account-level settings, AMIs, regions) — as specified in the issue.

## Summary

All three scopes are clean. The `enable_dns_support` and `enable_dns_hostnames` settings have been on `aws_vpc.bench` since PR #71, and this audit confirms they are purely defensive — no code path depends on them. The custom VPC created by `networking.tf` fully replicates the default-VPC behaviors the stack previously inherited.

Closes #70.
