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

**Result: Two references found** in `infra/terraform/aws_benchmark/outputs.tf`:

- `ManagerPublicDns` — `aws_instance.arph_manager[0].public_dns`
- `OrchestratorPublicDns` — `aws_instance.arph_manager[0].public_dns`

These outputs are consumed by the benchmark state JSON and used by
`Run-Benchmark-Aws-Controller.ps1` to connect from the operator's
laptop to the manager/orchestrator EC2 instance. Internal cluster
traffic still uses private IPs and SSM.

This makes `enable_dns_hostnames = true` **load-bearing** — without it,
the `.public_dns` attribute resolves to an empty string and the
operator cannot reach the orchestrator endpoint from outside the VPC.

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
