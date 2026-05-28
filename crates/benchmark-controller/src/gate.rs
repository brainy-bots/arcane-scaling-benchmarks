//! Validity gate (#79).
//!
//! Evaluates per-phase acceptance against the latest telemetry snapshot and
//! signals `Fail` after `breach_window` consecutive breached evaluations.
//!
//! Two gate categories:
//!
//! **Per-snapshot gates** (evaluated live during hold):
//! - `max_p99_latency_ms`: max of per-cluster `last_tick_us / 1000`.
//! - `min_entities`: min of `entities_current` across clusters.
//! - `min_total_entities`: sum of `entities_current` across all clusters.
//! - `max_error_rate`: driver error rate from the snapshot.
//!
//! **Phase-end gates** (evaluated once from accumulated metrics):
//! - `max_mean_tick_ms`: mean tick time over the hold window.
//! - `min_sample_rate`: `latency_samples / total_round_trips`.
//! - `max_mean_latency_ms`: driver mean round-trip latency over the hold window.
//! - `max_broadcast_lag_events`: total broadcast lag events across clusters.

use crate::plan::PhaseGate;
use crate::results::{ClusterPhaseMetrics, DriverPhaseMetrics};
use arcane_swarm_orchestrator::telemetry::TelemetrySnapshot;

/// Outcome of evaluating one snapshot against the active phase's gate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Evaluation {
    /// Below breach window — no decision yet.
    Pending,
    /// Latest snapshot satisfies all configured axes.
    Pass,
    /// `breach_window` consecutive failures — phase should be aborted.
    Fail,
}

/// Result of a phase-end validation check.
#[derive(Debug, Clone, PartialEq)]
pub struct PhaseEndResult {
    pub passed: bool,
    pub breach_axes: Vec<String>,
}

/// The gate. Stateful: tracks consecutive breach count for the active phase
/// plus a latched `any_phase_failed` flag used by the scheduler to refuse
/// subsequent phases after a fail.
pub struct ValidityGate {
    config: PhaseGate,
    breach_window: u32,
    consecutive_breaches: u32,
    any_phase_failed: bool,
}

impl ValidityGate {
    pub fn new(config: PhaseGate) -> Self {
        Self {
            config,
            breach_window: 3,
            consecutive_breaches: 0,
            any_phase_failed: false,
        }
    }

    pub fn with_breach_window(mut self, n: u32) -> Self {
        self.breach_window = n;
        self
    }

    /// Reset breach counter and load a new phase's config. Does NOT clear
    /// the `any_phase_failed` latch — that's a run-level signal.
    pub fn start_phase(&mut self, config: PhaseGate) {
        self.config = config;
        self.consecutive_breaches = 0;
    }

    pub fn set_breach_window(&mut self, n: u32) {
        self.breach_window = n;
    }

    /// Feed one snapshot.
    pub fn evaluate(&mut self, snap: &TelemetrySnapshot) -> Evaluation {
        if !self.has_any_snapshot_axis() {
            return Evaluation::Pass;
        }

        let breached = self.is_breached(snap);
        if breached {
            self.consecutive_breaches = self.consecutive_breaches.saturating_add(1);
            if self.consecutive_breaches >= self.breach_window {
                self.any_phase_failed = true;
                return Evaluation::Fail;
            }
            Evaluation::Pending
        } else {
            self.consecutive_breaches = 0;
            Evaluation::Pass
        }
    }

    /// Evaluate phase-end gates against accumulated metrics. Returns which
    /// axes (if any) were breached.
    pub fn evaluate_phase_end(
        &self,
        cluster: &ClusterPhaseMetrics,
        driver: &DriverPhaseMetrics,
    ) -> PhaseEndResult {
        let mut breach_axes = Vec::new();

        if let Some(max_mean_tick_ms) = self.config.max_mean_tick_ms {
            let mean_tick_ms = cluster.mean_tick_us as f64 / 1000.0;
            if mean_tick_ms > max_mean_tick_ms {
                breach_axes.push(format!(
                    "max_mean_tick_ms: {:.2} ms > {:.2} ms budget",
                    mean_tick_ms, max_mean_tick_ms
                ));
            }
        }

        if let Some(min_sample_rate) = self.config.min_sample_rate {
            let total_round_trips = driver.total_ok + driver.total_err;
            if total_round_trips > 0 {
                let sample_rate = driver.latency_samples as f64 / total_round_trips as f64;
                if sample_rate < min_sample_rate {
                    breach_axes.push(format!(
                        "min_sample_rate: {:.4} < {:.4} ({} samples / {} round-trips)",
                        sample_rate, min_sample_rate, driver.latency_samples, total_round_trips
                    ));
                }
            } else {
                breach_axes.push(
                    "min_sample_rate: zero round-trips — no data to evaluate".to_string(),
                );
            }
        }

        if let Some(max_lat) = self.config.max_mean_latency_ms {
            if driver.mean_latency_ms > max_lat {
                breach_axes.push(format!(
                    "max_mean_latency_ms: {:.2} ms > {:.2} ms budget",
                    driver.mean_latency_ms, max_lat
                ));
            }
        }

        if let Some(max_lag) = self.config.max_broadcast_lag_events {
            if cluster.total_broadcast_lagged_events > max_lag {
                breach_axes.push(format!(
                    "max_broadcast_lag_events: {} > {} allowed",
                    cluster.total_broadcast_lagged_events, max_lag
                ));
            }
        }

        PhaseEndResult {
            passed: breach_axes.is_empty(),
            breach_axes,
        }
    }

    /// True iff a prior phase has been marked Fail. Latches for the rest
    /// of the run; the scheduler queries this to short-circuit subsequent
    /// phases.
    pub fn any_phase_failed(&self) -> bool {
        self.any_phase_failed
    }

    pub fn mark_phase_failed(&mut self) {
        self.any_phase_failed = true;
    }

    pub fn consecutive_breaches(&self) -> u32 {
        self.consecutive_breaches
    }

    fn has_any_snapshot_axis(&self) -> bool {
        self.config.max_p99_latency_ms.is_some()
            || self.config.min_entities.is_some()
            || self.config.max_error_rate.is_some()
            || self.config.min_total_entities.is_some()
    }

    fn is_breached(&self, snap: &TelemetrySnapshot) -> bool {
        if let Some(max_ms) = self.config.max_p99_latency_ms {
            let max_tick_us = snap
                .clusters
                .values()
                .map(|c| c.last_tick_us)
                .max()
                .unwrap_or(0);
            if max_tick_us / 1000 > max_ms as u64 {
                return true;
            }
        }
        if let Some(min_entities) = self.config.min_entities {
            let min_seen = snap
                .clusters
                .values()
                .map(|c| c.entities_current)
                .min()
                .unwrap_or(u64::MAX);
            if snap.clusters.is_empty() || min_seen < min_entities {
                return true;
            }
        }
        if let Some(min_total) = self.config.min_total_entities {
            let total: u64 = snap.clusters.values().map(|c| c.entities_current).sum();
            if snap.clusters.is_empty() || total < min_total {
                return true;
            }
        }
        if let Some(max_err_rate) = self.config.max_error_rate {
            let total_ok: u64 = snap.driver_metrics.values().map(|m| m.ok).sum();
            let total_err: u64 = snap.driver_metrics.values().map(|m| m.err).sum();
            let total = total_ok + total_err;
            if total > 0 {
                let rate = total_err as f64 / total as f64;
                if rate > max_err_rate {
                    return true;
                }
            }
        }
        false
    }
}
