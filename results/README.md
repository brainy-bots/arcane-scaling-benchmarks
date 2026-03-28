# Benchmark results (generated)

This directory holds **run outputs** from [`scripts/Run-Benchmark.ps1`](../scripts/Run-Benchmark.ps1). Contents are gitignored except this file.

## Layout

Each run is a folder:

```text
results/runs/<Environment>/<yyyyMMdd_HHmmss>/
  spacetimedb_only/
    benchmark_scenarios_results.csv
    stderr/*.log
  arcane_plus_spacetimedb/
    benchmark_scenarios_results.csv
    stderr/*.log
```

**`<Environment>`** groups runs by topology or machine: default **`Local`** for workstation runs; AWS SingleInstance uses **`SingleInstance`** (matches `scripts/cloud/environments/`). Override with **`-Environment`** on `Run-Benchmark.ps1` when using the default output path; characters unsafe for paths are replaced with `_`.

- **CSV (`benchmark_scenarios_results.csv`):** UTF-8 CSV from PowerShell `Export-Csv`. Columns: **`backend`** (`spacetimedb_only` | `arcane_plus_spacetimedb`), **`num_servers`** (cluster count; `0` for Spacetime-only), **`ceiling_players`** (largest passing player count for that row, or empty if none). One row per backend/cluster configuration in that phase.
- **stderr:** captured stdout/stderr from swarm, Arcane manager/clusters, and related processes for that phase.

## Overrides

- Pass **`-OutDir`** to `Run-Benchmark.ps1` to use a different root (the same `spacetimedb_only/` and `arcane_plus_spacetimedb/` children are still created). **`Environment` is ignored** when `-OutDir` is set.
- **AWS:** same path inside the cloned repo on EC2 (`results/runs/SingleInstance/<runId>/`), synced to **`s3://<bucket>/<prefix>/SingleInstance/<runId>/`**.
