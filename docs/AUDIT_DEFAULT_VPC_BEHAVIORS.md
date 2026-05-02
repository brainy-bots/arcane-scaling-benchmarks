# Default VPC Behaviors Audit (#70)

## Scope

After PR #69 replaced `data "aws_vpc" "default"` with `aws_vpc.bench` (a
stack-owned custom VPC), this audit verified that all default-VPC behaviors
the benchmark stack silently relied on are explicitly carried over.

## Scope 1: DNS settings (handled by #71)

PR #71 (`2bf152a`) added `enable_dns_support = true` and
`enable_dns_hostnames = true` to `aws_vpc.bench` in `networking.tf`, each
with a comment documenting the purpose. No additional Terraform changes
were needed on main.

## Scope 2: EC2 public DNS hostname references

**Result: None found.**

Searched across all Terraform (.tf), PowerShell (.ps1), bash (.sh), Rust,
Docker, and config files:

| Pattern | Results |
|---|---|
| `compute.amazonaws.com` | Not found |
| `compute-1.amazonaws.com` | Not found |
| `public_dns` / `PublicDnsName` | Not found |
| `aws_instance.*.public_dns` in outputs | Not found (outputs use `.id` only) |
| Hostname construction from instance IDs | Not found (uses `Get-Ec2PrivateIp` for private IPs) |

The benchmark stack communicates entirely via **private IPs and SSM**.
No code path constructs or relies on EC2 public DNS hostnames. The
`enable_dns_hostnames = true` change is **purely defensive** — it
matches the old default-VPC contract in case anything downstream
(scripts outside this repo) references public DNS names.

## Scope 3: Other default-VPC behaviors

| Behavior | Status | Evidence |
|---|---|---|
| Internet egress via default IGW | ✅ Handled (#69) | `aws_internet_gateway.bench` + `aws_route_table.bench` with `0.0.0.0/0` route |
| Subnet auto-assigns public IPs | ✅ Handled (#69) | `map_public_ip_on_launch = true` on `aws_subnet.bench` |
| DNS resolution (AmazonProvidedDNS) | ✅ Verified | No custom `aws_vpc_dhcp_options` resource; VPC uses default AmazonProvidedDNS |
| DNS hostnames | ✅ Handled (#71) | `enable_dns_hostnames = true` on `aws_vpc.bench` |
| DNS support | ✅ Handled (#71) | `enable_dns_support = true` on `aws_vpc.bench` |
| Security group outbound | ✅ Handled | `egress { cidr_blocks = ["0.0.0.0/0"] }` on `aws_security_group.bench` |
| Instance metadata (IMDSv2) | ✅ Explicit | `metadata_options { http_tokens = "required" }` on every `aws_instance` resource |
| DHCP options set | ✅ No action | Custom VPCs default to AmazonProvidedDNS (same as default VPCs) |

## Conclusion

No additional gaps were identified. The DNS settings from #71, together
with the networking resources from #69, fully cover all default-VPC
behaviors the benchmark stack relies on. The audit confirms the stack
is self-contained and reproducible on empty AWS accounts.
