# Benchmark Methodology and Interpretation

This document is the detailed technical companion to the repository `README.md`.
It explains exactly what the benchmark measures, how pass/fail is decided, and how
to interpret the headline result without over-claiming.

## Headline result context

The public headline run is:

- 13,500 concurrent players (CCU)
- 60 Hz server tick
- 1,000-byte `user_data` payload
- ~10 ms mean server-side latency

This was measured on the AWS topology documented in the root README.

## What "server-side latency" means

Driver latency is measured as action-to-ack-broadcast elapsed wall-clock time:

1. The driver sends an outbound action tagged with `seq_id`.
2. The driver receives a broadcast frame whose ack list includes that same
   `seq_id`.
3. The latency sample is the elapsed time between those two events.

This includes server ingest, simulation/tick processing, broadcast encoding, and
in-VPC transport. It does not include public internet RTT.

## Workload definition

Each simulated player performs:

- 2 game actions/sec
- 5 reads/sec
- subscription to cluster broadcast stream
- periodic burst behavior (20% cohort every 30s, 10 actions in 500ms window)
- periodic zone events

The run uses full-mesh visibility (no AOI filtering), making replication pressure
intentionally heavy.

## Why 1 KB payload does not imply full-snapshot wire cost

The benchmark uses standard replication optimizations:

- Dead-reckoning delta encoding (entities are sent when movement state changes,
  plus periodic resync ticks)
- Quantized wire representation for position/velocity

So 1 KB is the per-entity payload slot when an entity appears in a delta, not
"60 Hz full-world snapshot per client" bandwidth.

## Tier validity gates

A tier is marked passing only when its gates pass during steady-state evaluation:

- error rate < 1%
- mean latency < 50 ms
- aggregate entities observed reach required target

The controller waits for ramp readiness before steady-state hold evaluation, so
tier passes are based on achieved load, not pre-ramp telemetry.

## What counts as an error

Errors include:

- `seq_id` acknowledgment timeout
- WebSocket disconnect during active phase
- protocol decode violation

Errors do not include intentionally superseded frames in broadcast-lag handling.

## What this benchmark proves

- Arcane sustained the configured workload at 13.5k CCU on the published fleet.
- Driver-reported server-side latency stayed in the low-millisecond band.
- The workflow is reproducible with public scripts and plans.

## What this benchmark does not prove

- Absolute engine ceiling (driver cap may terminate first)
- End-to-end player internet latency
- Long-duration soak behavior
- Shooter-class rigid-body physics performance
- Production cost economics

## Architecture note

Arcane's core premise is affinity clustering by predicted interaction probability.
This benchmark run is a full-mesh visibility stress shape. It validates a
high-pressure replication scenario, but it is not the only operating mode Arcane
supports.

## Artifact map

Benchmark artifacts are written under:

`results/runs/<Environment>/<RunId>/`

Key files:

- `phase_*.json` - per-phase outcomes and aggregates
- `manifest.json` - run-level summary
- `benchmark_repro_summary.json` - machine-readable rollup
- `container-logs/` - captured service logs

