# Cloud benchmark (AWS)

## Scripts

| Script | Purpose |
|--------|---------|
| **`Run-Benchmark-Aws.ps1`** | Full run: provision → SSM (clone, deps, build, `Run-Benchmark.ps1`) → S3 sync → optional terminate. |
| **`Setup-AwsBenchmark.ps1`** | Provision only; writes a **state JSON** for later cleanup or manual SSM. |
| **`Cleanup-AwsBenchmark.ps1`** | Tear down using **`-StatePath`** or explicit **`-InstanceId`** / **`-Region`**. |

**Topology** is selected with **`-Environment`** (default `SingleInstance`). Each value maps to `environments/<Name>/`; see [environments/README.md](environments/README.md) to add another (e.g. multi-host).

## Prerequisites

1. **AWS CLI** configured (`aws sts get-caller-identity`).
2. **EC2 instance profile** (`-IamInstanceProfileName`) with `AmazonSSMManagedInstanceCore` and `s3:PutObject` (and list if required) on your artifact bucket.
3. **Private git submodules:** if `arcane` / `arcane_swarm` / etc. are private, set **`ARCANE_BENCHMARK_GITHUB_TOKEN`** (PAT or `gh auth token`) in your environment before running, or pass **`-GithubToken`**. The instance uses it only to `git submodule update` over HTTPS, then builds.

## Examples

Full run (terminate instance when finished):

```powershell
.\Run-Benchmark-Aws.ps1 `
  -ArtifactBucket your-bucket-name `
  -IamInstanceProfileName your-profile-name `
  -Region us-east-1 `
  -TerminateOnExit
```

Provision only, then clean up later:

```powershell
.\Setup-AwsBenchmark.ps1 `
  -ArtifactBucket your-bucket-name `
  -IamInstanceProfileName your-profile-name

# ... state file path printed; when finished:
.\Cleanup-AwsBenchmark.ps1 -StatePath '.\.benchmark-aws-state-YYYYMMDD_HHMMSS.json'
```

Optional: `-Environment SingleInstance`, `-BenchmarkPwshArgs '-SpacetimeMaxPlayers 1000'`, `-RepoUrl`, `-Branch`, `-StateOutPath` on **`Run-Benchmark-Aws.ps1`** to save the same JSON shape as setup for auditing.

Results sync to `s3://<bucket>/<ArtifactPrefix>/<Environment>/<runId>/` (default prefix `benchmark-aws`; `Environment` is e.g. `SingleInstance`). Same tree as on disk under `results/runs/<Environment>/<runId>/` (`spacetimedb_only/`, `arcane_plus_spacetimedb/`).
