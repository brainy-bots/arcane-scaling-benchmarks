//! Per-phase metrics aggregation from TelemetrySnapshot streams.
//!
//! The SSE consumer already broadcasts parsed `TelemetrySnapshot`s. This
//! module subscribes to the same broadcast and accumulates cluster + driver
//! metrics per phase. At phase boundaries the run loop calls `phase_summary()`
//! to snapshot the aggregated metrics and reset for the next phase.

use crate::results::{ClusterPhaseMetrics, DriverPhaseMetrics};
use arcane_swarm_orchestrator::telemetry::TelemetrySnapshot;
use std::collections::HashMap;

/// Cumulative driver metrics at a point in time (keyed by driver id).
#[derive(Clone, Default)]
struct DriverCumulative {
    ok: u64,
    err: u64,
    latency_sum_us: u64,
    latency_samples: u64,
}

/// Accumulates telemetry snapshots during a phase's hold window.
#[derive(Default)]
pub struct PhaseMetricsAccumulator {
    snapshot_count: u64,
    total_entities_sum: u64,
    cluster_count_sum: u64,
    worst_tick_us: u64,
    tick_us_sum: u64,
    tick_us_count: u64,
    total_bytes_in: u64,
    total_bytes_out: u64,
    total_broadcast_lagged_events: u64,
    /// Driver cumulative metrics at phase start (first snapshot that has them).
    driver_baseline: HashMap<String, DriverCumulative>,
    /// Driver cumulative metrics from the latest snapshot.
    driver_latest: HashMap<String, DriverCumulative>,
    baseline_captured: bool,
}

impl PhaseMetricsAccumulator {
    pub fn new() -> Self {
        Self {
            snapshot_count: 0,
            total_entities_sum: 0,
            cluster_count_sum: 0,
            worst_tick_us: 0,
            tick_us_sum: 0,
            tick_us_count: 0,
            total_bytes_in: 0,
            total_bytes_out: 0,
            total_broadcast_lagged_events: 0,
            driver_baseline: HashMap::new(),
            driver_latest: HashMap::new(),
            baseline_captured: false,
        }
    }

    /// Ingest one telemetry snapshot.
    pub fn ingest(&mut self, snap: &TelemetrySnapshot) {
        self.snapshot_count += 1;

        // Cluster metrics
        let mut total_ent: u64 = 0;
        for c in snap.clusters.values() {
            total_ent += c.entities_current;
            self.worst_tick_us = self.worst_tick_us.max(c.last_tick_us);
            self.tick_us_sum += c.last_tick_us;
            self.tick_us_count += 1;
            self.total_bytes_in += c.bytes_in;
            self.total_bytes_out += c.bytes_out;
            self.total_broadcast_lagged_events += c.broadcast_lagged_events;
        }
        self.total_entities_sum += total_ent;
        self.cluster_count_sum += snap.clusters.len() as u64;

        // Driver cumulative metrics
        if !snap.driver_metrics.is_empty() {
            let current: HashMap<String, DriverCumulative> = snap
                .driver_metrics
                .iter()
                .map(|(id, m)| {
                    (
                        id.clone(),
                        DriverCumulative {
                            ok: m.ok,
                            err: m.err,
                            latency_sum_us: m.latency_sum_us,
                            latency_samples: m.latency_samples,
                        },
                    )
                })
                .collect();

            if !self.baseline_captured {
                self.driver_baseline = current.clone();
                self.baseline_captured = true;
            }
            self.driver_latest = current;
        }
    }

    /// Discard accumulated data and reset for a fresh measurement window.
    /// Used after warmup completes — the baseline is recaptured from the
    /// next snapshot so that ramp-up time doesn't contaminate the
    /// measurement period.
    pub fn reset(&mut self) {
        *self = Self::new();
    }

    /// Produce the phase summary and reset the accumulator for the next phase.
    pub fn phase_summary(&mut self) -> (ClusterPhaseMetrics, DriverPhaseMetrics) {
        let cluster = ClusterPhaseMetrics {
            total_entities: self
                .total_entities_sum
                .checked_div(self.snapshot_count)
                .unwrap_or(0),
            cluster_count: self
                .cluster_count_sum
                .checked_div(self.snapshot_count)
                .unwrap_or(0) as usize,
            worst_tick_us: self.worst_tick_us,
            mean_tick_us: self
                .tick_us_sum
                .checked_div(self.tick_us_count)
                .unwrap_or(0),
            total_bytes_in: self.total_bytes_in,
            total_bytes_out: self.total_bytes_out,
            total_broadcast_lagged_events: self.total_broadcast_lagged_events,
            snapshot_count: self.snapshot_count,
        };

        let driver = self.compute_driver_delta();

        // Reset for next phase
        *self = Self::new();

        (cluster, driver)
    }

    /// Per-driver latency at phase end, for headline computation.
    /// Returns (driver_id, avg_latency_ms) for each driver that reported.
    pub fn per_driver_latencies(&self) -> Vec<(String, f64)> {
        let mut result = Vec::new();
        for (id, latest) in &self.driver_latest {
            let baseline = self.driver_baseline.get(id);
            let delta_sum = latest
                .latency_sum_us
                .saturating_sub(baseline.map_or(0, |b| b.latency_sum_us));
            let delta_samples = latest
                .latency_samples
                .saturating_sub(baseline.map_or(0, |b| b.latency_samples));
            if delta_samples > 0 {
                let avg_ms = delta_sum as f64 / delta_samples as f64 / 1000.0;
                result.push((id.clone(), avg_ms));
            }
        }
        result.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
        result
    }

    fn compute_driver_delta(&self) -> DriverPhaseMetrics {
        if self.driver_latest.is_empty() {
            return DriverPhaseMetrics::default();
        }

        let mut total_ok: u64 = 0;
        let mut total_err: u64 = 0;
        let mut total_lat_sum: u64 = 0;
        let mut total_lat_samples: u64 = 0;

        for (id, latest) in &self.driver_latest {
            let baseline = self.driver_baseline.get(id);
            total_ok += latest.ok.saturating_sub(baseline.map_or(0, |b| b.ok));
            total_err += latest.err.saturating_sub(baseline.map_or(0, |b| b.err));
            total_lat_sum += latest
                .latency_sum_us
                .saturating_sub(baseline.map_or(0, |b| b.latency_sum_us));
            total_lat_samples += latest
                .latency_samples
                .saturating_sub(baseline.map_or(0, |b| b.latency_samples));
        }

        let mean_latency_ms = if total_lat_samples > 0 {
            total_lat_sum as f64 / total_lat_samples as f64 / 1000.0
        } else {
            0.0
        };
        let total_calls = total_ok + total_err;
        let error_rate = if total_calls > 0 {
            total_err as f64 / total_calls as f64
        } else {
            0.0
        };

        DriverPhaseMetrics {
            driver_count: self.driver_latest.len(),
            total_ok,
            total_err,
            latency_sum_us: total_lat_sum,
            latency_samples: total_lat_samples,
            mean_latency_ms,
            error_rate,
        }
    }
}
