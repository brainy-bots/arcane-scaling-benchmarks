# Benchmark Metrics Specification

How the benchmark controller computes the numbers that appear in `manifest.json`
and the README headline.

---

## Data pipeline

```
Driver process (arcane_swarm)
  ├─ Cumulative atomic counters: ok, err, latency_sum_us, latency_samples, max_latency_us, bytes
  └─ Every 5 s → DriverMessage::MetricsReport over WebSocket
                        │
Orchestrator (arcane-swarm-orchestrator)
  ├─ DriverEntry.latest_metrics updated on each MetricsReport
  └─ TelemetrySnapshot (SSE, ~2 Hz)
       ├─ clusters: { cluster_id → ClusterWireStats }
       └─ driver_metrics: { driver_id → DriverMetricsWire }
                        │
Controller (benchmark-controller)
  └─ PhaseMetricsAccumulator
       ├─ Subscribes to TelemetrySnapshot broadcast
       ├─ Captures baseline on first snapshot with driver_metrics
       ├─ Per phase: latest − baseline = delta
       └─ Output: ClusterPhaseMetrics, DriverPhaseMetrics, HeadlineSummary
```

## Per-phase cluster metrics (`ClusterPhaseMetrics`)

Computed from all `TelemetrySnapshot`s received during the phase.

| Field | Formula |
|---|---|
| `total_entities` | `Σ entities_current / snapshot_count` (time-averaged across snapshots) |
| `cluster_count` | `Σ cluster_count / snapshot_count` (time-averaged) |
| `worst_tick_us` | `max(last_tick_us)` across all clusters, all snapshots in the phase |
| `mean_tick_us` | `Σ last_tick_us / tick_count` (one sample per cluster per snapshot) |
| `total_bytes_in` | `Σ bytes_in` across all clusters, all snapshots |
| `total_bytes_out` | `Σ bytes_out` across all clusters, all snapshots |
| `snapshot_count` | number of snapshots ingested during this phase |

## Per-phase driver metrics (`DriverPhaseMetrics`)

Computed as **delta = latest − baseline** for each driver. The baseline is the
first snapshot that contains `driver_metrics`; the latest is the last snapshot
before `phase_summary()` is called.

| Field | Formula |
|---|---|
| `driver_count` | number of drivers reporting in latest snapshot |
| `total_ok` | `Σ (latest.ok − baseline.ok)` across all drivers |
| `total_err` | `Σ (latest.err − baseline.err)` across all drivers |
| `latency_sum_us` | `Σ (latest.latency_sum_us − baseline.latency_sum_us)` |
| `latency_samples` | `Σ (latest.latency_samples − baseline.latency_samples)` |
| `mean_latency_ms` | `latency_sum_us / latency_samples / 1000` |
| `error_rate` | `total_err / (total_ok + total_err)` |

All subtractions use `saturating_sub` to handle driver restarts gracefully.

## Headline summary (`HeadlineSummary`)

Computed from the **top passing tier** — the highest-CCU phase that ended with
`PhaseOutcome::Pass`. If the top tier fails, the headline comes from the
highest tier that passed before it.

### Per-driver latency vector

For each driver in the top passing tier:

```
avg_latency_ms = (latest.latency_sum_us − baseline.latency_sum_us)
               / (latest.latency_samples − baseline.latency_samples)
               / 1000.0
```

This produces one value per driver. The vector is sorted ascending.

### Headline fields

| README text | Field | Formula |
|---|---|---|
| "13,500 CCU" | `top_tier_ccu` | `phase.target_players` from the plan |
| "12 independent drivers" | `driver_count` | length of per-driver latency vector |
| "10.39 ms mean" | `mean_latency_ms` | arithmetic mean of per-driver averages |
| "median 10.24 ms" | `median_latency_ms` | median of per-driver averages (standard even/odd formula) |
| "range 8.63 – 13.15 ms" | `min/max_latency_ms` | first/last element of sorted vector |
| "~24,000,000 round-trips" | `total_round_trips` | `total_ok + total_err` from `DriverPhaseMetrics` |
| "0 errors" | `total_errors` | `total_err` from `DriverPhaseMetrics` |
| "0.000%" | `error_rate_pct` | `total_err / (total_ok + total_err) × 100` |

### What "mean server-side latency" measures

Each driver records the elapsed time from **sending an action** to **receiving
the corresponding broadcast acknowledgement** — the full round-trip through
the cluster pipeline:

```
driver sends action → orchestrator → cluster processes tick → broadcast →
orchestrator → driver receives ack
```

This is **server-side latency** because both endpoints (driver and cluster)
are in the same VPC. It is NOT cluster tick time (`last_tick_us`), which only
measures the tick-processing portion.

## Warmup gate

Before the measurement window (hold timer) starts, the controller waits for
entities to reach 100% of `target_players`. This ensures the system is fully
loaded before any measurements are taken.

- The controller polls `TelemetrySnapshot` for `Σ entities_current >= target_players`
- Timeout: `warmup_timeout_seconds` per phase (default 120s)
- If entities never reach the target → phase fails immediately
- After warmup completes, the metrics accumulator is reset — ramp-up data
  does not contaminate the measurement window

## Validity gates

### Per-snapshot gates (evaluated live during hold, ~2 Hz)

| Axis | Source | Breach logic |
|---|---|---|
| `max_p99_latency_ms` | `max(cluster.last_tick_us) / 1000` | Fails if max tick across clusters exceeds threshold |
| `min_entities` | `min(cluster.entities_current)` | Fails if any single cluster drops below threshold |
| `min_total_entities` | `Σ cluster.entities_current` | Fails if sum across clusters drops below threshold. Auto-injected at 98% of `target_players` when not set (warmup guarantees 100% at hold start) |
| `max_error_rate` | `Σ driver.err / Σ (driver.ok + driver.err)` | Fails if cumulative error rate exceeds threshold |

Per-snapshot gates use a **breach window** (default 3 consecutive breaches).
Intermittent spikes don't fail the phase — only sustained breaches do.

### Phase-end gates (evaluated once from accumulated metrics)

| Axis | Source | Breach logic |
|---|---|---|
| `max_mean_tick_ms` | `ClusterPhaseMetrics.mean_tick_us / 1000` | Fails if mean tick over the hold window exceeds the tick budget. Auto-injected as `1000 / tick_rate_hz` when not set |
| `min_sample_rate` | `latency_samples / (total_ok + total_err)` | Fails if the ratio of latency samples to round-trips is too low — catches instrumentation bugs that silently discard echo matches |

Phase-end gates have no breach window — a single evaluation at the end of the
hold period determines pass/fail.

## Phase boundary behavior

At each phase boundary, `PhaseMetricsAccumulator::phase_summary()`:

1. Computes cluster and driver deltas from accumulated state
2. Resets all accumulators to zero (`*self = Self::new()`)
3. The next phase starts with a fresh baseline captured from the first
   snapshot that contains `driver_metrics`

This means each phase's metrics reflect only the work done during that phase,
not cumulative across the entire run. The warmup gate's reset ensures the
baseline is captured at steady state, not during ramp-up.

## Edge cases

- **No driver metrics received**: `DriverPhaseMetrics::default()` (all zeros).
  `HeadlineSummary` is `None`.
- **Driver appears mid-phase**: Its baseline is its first appearance; delta is
  computed from that point.
- **Driver disappears mid-phase**: Its latest remains from its last report;
  delta is still computed.
- **Zero latency samples**: Driver is excluded from the per-driver latency
  vector (division by zero guard).
- **Single driver**: Median = mean = min = max = that driver's average.
