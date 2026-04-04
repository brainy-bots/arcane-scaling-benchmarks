# DistributedComponents (AWS)

Three EC2 instances in the **same VPC subnet** and **one security group**:

| Role | Default type | Workload |
|------|----------------|----------|
| **Redis** | `t3.large` | Docker `redis:7-alpine` on `0.0.0.0:6379` |
| **SpacetimeDB** | `t3.large` | Docker `clockworklabs/spacetime:latest` on `0.0.0.0:3000` |
| **Driver** | `-InstanceType` (e.g. `c7i.2xlarge`) | Clone repo, Rust builds, `spacetime publish` to Spacetime **private IP**, `Run-Benchmark.ps1` with `-RedisHost` / `-SpacetimeHost` set to those private IPs |

Traffic between Redis, SpacetimeDB, and Arcane (on the driver) uses **VPC private networking** (not loopback), so inter-component RTT reflects a real cloud path more than single-host Docker Desktop.

## Usage

Same orchestrator as `SingleInstance`, different environment name:

```powershell
cd scripts/cloud
.\Run-Benchmark-Aws.ps1 `
  -Environment DistributedComponents `
  -ArtifactBucket <bucket> `
  -IamInstanceProfileName <profile> `
  -Region us-east-1 `
  -TerminateOnExit
```

Results land under `results/runs/DistributedComponents/<RunId>/` locally (and the same prefix on S3).

## Teardown

This topology creates **three** instances. **Always use the saved state JSON** for cleanup:

- Pass **`-StatePath`** to `Cleanup-AwsBenchmark.ps1` (from `Setup-AwsBenchmark.ps1` or `-StateOutPath` on `Run-Benchmark-Aws.ps1`).
- **Do not** use the manual **`-InstanceId`** mode from `Cleanup-AwsBenchmark.ps1`; it is only valid for **SingleInstance** and would not terminate Redis, SpacetimeDB, and the driver together.

## Security group

If you omit `-SecurityGroupId`, a temporary group is created and **ingress from the same security group** is added for TCP **6379, 3000, 8081, 8090–8110** (Arcane manager + cluster WS range). If you pass your own group, the setup script **adds** those rules (duplicates are ignored).

**SSM** still needs the instance profile with `AmazonSSMManagedInstanceCore` (no SSH required).

## Limitations (v1)

- **Arcane manager + clusters + swarm** still run on the **driver** only. Redis and SpacetimeDB are the components split onto separate machines. Further splits (e.g. one instance per Arcane cluster) can build on this pattern.
- **Three instances** = higher cost than `SingleInstance`; data nodes use `t3.large` by default to keep cost down.
