# Benchmark results (generated)

This directory holds **run outputs** from [`scripts/Run-Benchmark.ps1`](../scripts/Run-Benchmark.ps1). Contents are gitignored except this file.

## Layout

Each run is a folder:

```text
results/runs/<Environment>/<yyyyMMdd_HHmmss>/
  benchmark_run_manifest.json   # effective parameters, pass criteria, binary SHA-256, host/git — compare runs with this
  spacetimedb_only/
    benchmark_scenarios_results.csv
    stderr/*.log
  arcane_plus_spacetimedb/
    benchmark_scenarios_results.csv
    stderr/*.log
```

**`<Environment>`** groups runs by topology or machine: default **`Local`** for workstation runs; AWS topologies use **`AwsSpacetimeOnly`** or **`AwsArcanePerHost`** (matches `infra/aws/topologies/`). Override with **`-Environment`** on `Run-Benchmark.ps1` when using the default output path; characters unsafe for paths are replaced with `_`.

- **Manifest (`benchmark_run_manifest.json`):** Written in a `finally` block (even if the run throws). **`invocation`** holds **`host_powershell_line`** (when PowerShell populates `$MyInvocation.Line`; often empty under `pwsh -File`) and **`repro_command_pwsh_no_profile`**, a single copy-paste line with `pwsh -NoProfile -File "<Run-Benchmark.ps1>"` plus **all effective parameters** (resolved `-OutDir`, exe paths, invariant-culture doubles) so you can rerun the same experiment. **`script_path`** is the absolute script file. **`swarm_client`** spells out arcane-swarm behavior: tick rate, **actions per second**, **read/refresh rate** (`--read-rate`), movement **mode**, fixed harness sleeps (2 s after `SET_PLAYERS`, steady-state duration per tier, gap between tiers), **`--run-forever` / `--duration`**, and per-backend flags (**`--server-physics`** for Spacetime-only vs **`--arcane-manager`** URL for Arcane). Also: sweep parameters, pass thresholds, connectivity, **`arcane_topology`** (schema **4**+: manager host/port, optional per-cluster hosts, external-process mode), Arcane persist settings, **binary SHA-256**, `git` HEAD for the benchmark repo and **`arcane_swarm`** submodule when available, host metadata, and `run_succeeded` / `run_error`. `schema_version` documents manifest shape. Use this file to compare CSV numbers across machines or dates.
- **CSV (`benchmark_scenarios_results.csv`):** UTF-8 CSV from PowerShell `Export-Csv`. Columns: **`backend`** (`spacetimedb_only` | `arcane_plus_spacetimedb`), **`num_servers`** (cluster count; `0` for Spacetime-only), **`ceiling_players`** (largest passing player count for that row, or empty if none). One row per backend/cluster configuration in that phase.
- **stderr:** captured stdout/stderr from swarm, Arcane manager/clusters, and related processes for that phase.

## Overrides

- Pass **`-OutDir`** to `Run-Benchmark.ps1` to use a different root (the same `spacetimedb_only/` and `arcane_plus_spacetimedb/` children are still created). **`Environment` is ignored** when `-OutDir` is set.
- **AWS:** same path inside the cloned repo on EC2 (`results/runs/<Environment>/<runId>/`), synced to **`s3://<bucket>/<prefix>/<Environment>/<runId>/`** (e.g. **`AwsSpacetimeOnly`** or **`AwsArcanePerHost`** — match **`-Environment`** when using `Sync-AwsBenchmarkResultsFromS3.ps1`).
