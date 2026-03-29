# Cloud benchmark (AWS)

## Scripts

| Script | Purpose |
|--------|---------|
| **`Run-Benchmark-Aws.ps1`** | Full run: provision → SSM (clone, deps, build, `Run-Benchmark.ps1`) → stage to S3 → **download to your machine** (default: `results/runs/<Environment>/<runId>/`) → optional terminate. |
| **`Sync-AwsBenchmarkResultsFromS3.ps1`** | **Pull-only:** copy an existing run from S3 into `results/runs/...` when the orchestrator did not download (skipped step, crash, or old tooling). |
| **`Setup-AwsBenchmark.ps1`** | Provision only; writes a **state JSON** for later cleanup or manual SSM. |
| **`Cleanup-AwsBenchmark.ps1`** | Tear down using **`-StatePath`** or explicit **`-InstanceId`** / **`-Region`**. |

**Topology** is selected with **`-Environment`** (default `SingleInstance`). Each value maps to `environments/<Name>/`; see [environments/README.md](environments/README.md) to add another (e.g. multi-host).

## Prerequisites

1. **AWS CLI** configured (`aws sts get-caller-identity`).
2. **EC2 instance profile** (`-IamInstanceProfileName`) with `AmazonSSMManagedInstanceCore` and `s3:PutObject` (and list if required) on your artifact bucket.
3. **Your IAM user/role** (the one running the script) needs **`s3:GetObject`** (and usually `s3:ListBucket`) on the same bucket so results can be **synced to your PC** after the run. The bucket is only a hop from the instance; the copy you wait for is **local** unless you use **`-SkipLocalResultsDownload`**.
4. **Private git submodules:** if `arcane` / `arcane_swarm` / etc. are private, set **`ARCANE_BENCHMARK_GITHUB_TOKEN`** (PAT or `gh auth token`) in your environment before running, or pass **`-GithubToken`**. The instance uses it only to `git submodule update` over HTTPS, then builds.

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

Optional: `-Environment SingleInstance`, `-BenchmarkPwshArgs '-SpacetimeMaxPlayers 1000'`, `-RepoUrl`, `-Branch`, `-StateOutPath`, **`-LocalResultsDir`**, **`-SkipLocalResultsDownload`** on **`Run-Benchmark-Aws.ps1`**.

**Where your results end up:** By default, under the **benchmark repo** at `results/runs/<Environment>/<runId>/` (same tree as local `Run-Benchmark.ps1`: `spacetimedb_only/`, `arcane_plus_spacetimedb/`, CSVs, `stderr/`). The instance also uploads to `s3://<bucket>/<ArtifactPrefix>/<Environment>/<runId>/` so artifacts survive termination; that S3 path is a staging area, not the primary place to read them.

**Pull results later** (orchestrator skipped download, or you only have S3):

```powershell
cd scripts/cloud
.\Sync-AwsBenchmarkResultsFromS3.ps1 `
  -ArtifactBucket your-bucket-name `
  -RunId 20260328_185206 `
  -Region us-east-1

# Or pass the full prefix:
.\Sync-AwsBenchmarkResultsFromS3.ps1 `
  -S3Uri 's3://your-bucket-name/benchmark-aws/SingleInstance/20260328_185206/' `
  -Region us-east-1
```

Optional: **`-LocalResultsDir`** to override the default under `results/runs/...`, **`-ArtifactPrefix`**, **`-Environment`** if your run used non-defaults.
