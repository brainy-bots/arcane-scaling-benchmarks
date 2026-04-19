# Canonical benchmark parameters

These parameters are **fixed** across all ceiling/scaling experiments so that SpacetimeDB-only and Arcane+SpacetimeDB results are comparable.

| Parameter | Value | Notes |
|-----------|--------|------|
| **tick_rate_hz** | 10 | Position updates per second per player |
| **aps** | 2 | Actions per second per player |
| **duration_s** | 30 | Run duration (warmup is additional in swarm) |
| **mode** | spread | Movement spread |
| **visibility** | everyone_sees_everyone | All clients receive all entity positions |
| **demo_entities** | 0 | No NPCs; players only |
| **server_physics** | true | (SpacetimeDB-only) Physics in module |
| **read_rate_hz** | 5 | (Arcane+Spacetime) World-state read rate per player |
| **spacetimedb_persist_hz** | 1 | (Arcane+Spacetime) Batch persist to SpacetimeDB per second |
| **spacetimedb_persist_batch_size** | 0 recommended | 0 = one request per persist window; 500 = cap (worse ceilings in our runs) |
| **redis_enabled** | true | (Arcane+Spacetime) Replication when num_servers > 1 |
| **burst_enabled** | true (default) | Deterministic worst-case burst profile is part of baseline |
| **pass_criteria** | err_rate < 1%, lat_avg_ms < 200 | Pass/fail per run |

Effective values for each run are also recorded in **`results/runs/<Environment>/<timestamp>/benchmark_run_manifest.json`** (see `results/README.md`) so CSV ceilings can be compared with exact thresholds and workload settings.

`scripts/Run-Benchmark.ps1` takes `-ConfigFile <path-to-json>` as its only required parameter; the config carries every workload parameter and its `BenchmarkMode` field selects the scenario.

## Error taxonomy used by `err_rate`

`err_rate` uses `total_errs / total_calls`, where `total_errs` is the sum of these categories:
- `timeout`
- `not_delivered`
- `http_status`
- `transport`
- `connection_drop`

`arcane-swarm` emits these per-category counts as `err_json=...` in each `FINAL:` line so benchmark artifacts preserve the exact error mix, not only a single aggregate number.

## Deterministic burst profile (default)

When enabled, the profile is fully deterministic and reproducible:
- `burst_period_secs` (default 30)
- `burst_cohort_percent` (default 20)
- `burst_actions_per_player` (default 10)
- `burst_window_ms` (default 500)
- `zone_event_period_secs` (default 30)
- `zone_event_window_ms` (default 500)

## Inter-node latency and published numbers

There is **no** in-repo, cross-platform Docker recipe for artificial WAN-like delay that works for the typical **Windows + Docker Desktop** developer machine. Local runs remain valid for **workload and correctness** of the harness; **published** ceilings that must reflect **real multi-host RTT** should come from **cloud or multi-machine** runs (topology described in the run manifest and README).

## Multi-host Arcane (`Run-Benchmark.ps1` with an Arcane config)

| Parameter | Default | Role |
|-----------|---------|------|
| **ArcaneManagerHost** | `127.0.0.1` | HTTP host for `arcane-manager` (swarm `--arcane-manager`). |
| **ArcaneManagerPort** | `8081` | Manager HTTP port. |
| **ArcaneClusterHosts** | _(empty)_ | Per-cluster websocket host; index `i` = cluster `i`. Empty = all `127.0.0.1` (current single-machine behavior). |
| **ArcaneClusterBasePort** | `8090` | First cluster WS port; cluster `i` uses `BasePort + i * Stride`. |
| **ArcaneClusterPortStride** | `1` | Use **`0`** when each cluster runs on its **own** machine and every process listens on the **same** port number (e.g. 8090 on each host). |
| **ArcaneExternalProcesses** | `$false` | If set, the script **does not** start `arcane-manager` / `arcane-cluster` locally; it only waits for TCP and runs **swarm**. Non-loopback manager or cluster hosts **require** this switch. |

`MANAGER_CLUSTERS` for locally spawned processes is built as `clusterId:host:port` using the hosts/ports above. For **external** mode, start Arcane elsewhere with a matching layout; the harness still checks that manager and cluster sockets are open before driving swarm.

**Config file:** the same names are allowed in `-ConfigFile` JSON (`ArcaneClusterHosts` as a JSON array of strings).
