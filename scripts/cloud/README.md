# Cloud benchmark (AWS)

## Why `Run-Benchmark-V2-Aws.ps1` was "not recognized"

`scripts\cloud` previously had only `aws_runs_*` output folders; the launcher script was not in the repo. It is now **`Run-Benchmark-V2-Aws.ps1`** in this directory.

## Prerequisites

1. **AWS CLI** configured (`aws sts get-caller-identity`).
2. **EC2 instance profile** (name passed as `-IamInstanceProfileName`) with:
   - `AmazonSSMManagedInstanceCore` (SSM)
   - `s3:PutObject` (and `ListBucket` if needed) on your artifact bucket
3. **GHCR images must be publicly pullable** (anonymous `docker pull`) from the internet.
   - Single-path reproducible mode (`-UsePublishedImages` only); no registry auth on EC2.
   - Before launch, the script runs a local `docker pull` for `-InfraImage` / `-SwarmImage` when `docker` is on PATH (use `-SkipLocalPublicImageCheck` if you have no Docker locally).

## Example

From this directory:

```powershell
# List profiles (pick one name from the output — paste it as-is, no angle brackets):
aws iam list-instance-profiles --query "InstanceProfiles[*].InstanceProfileName" --output text

.\Run-Benchmark-V2-Aws.ps1 `
  -ArtifactBucket arcane-benchmark-artifacts-329757307135-us-east-1 `
  -IamInstanceProfileName arcane-benchmark-ec2-profile `
  -Region us-east-1 `
  -InfraImage ghcr.io/brainy-bots/arcane-benchmark-infra:v1.0.0 `
  -SwarmImage ghcr.io/brainy-bots/arcane-benchmark-swarm:v1.0.0
```

**PowerShell:** Do not type placeholders like `&lt;name-from-list&gt;` or `&lt;name&gt;` — `<` is a special character. Replace `arcane-benchmark-ec2-profile` with your real profile name (quote it if it has spaces).

Use your **real** instance profile name (the script rejects the literal placeholder `YourInstanceProfileName`).

Optional: `-TerminateOnExit` to stop the instance when the run finishes, `-RepoUrl` / `-Branch` if not using defaults, `-BenchmarkPwshArgs '-MaxPlayers 2000'` for extra `Run-Benchmark-V2.ps1` parameters.

Results sync to `s3://<bucket>/<ArtifactPrefix>/<runId>/` (default prefix `benchmark-v2-aws`).
