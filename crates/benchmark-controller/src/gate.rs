//! Validity gate (#79).
//!
//! Subscribes to the orchestrator's telemetry SSE stream, evaluates per-phase
//! acceptance against the latest cluster `/stats` summary, and signals
//! `Fail` after `breach_window` consecutive breached evaluations.
//!
//! Pure logic — wire transport (HTTP/SSE) is plumbed in by the controller's
//! main loop; this module operates on already-parsed `TelemetrySnapshot`s.
//!
//! Axis sources from `TelemetrySnapshot`:
//! - `max_p99_latency_ms`: derived from per-cluster `last_tick_us / 1000`
//!   (max across clusters). This is a tick-time proxy until driver-reported
//!   latency lands in the snapshot via a dedicated telemetry message.
//! - `min_entities`: min of `entities_current` across clusters. Direct.
//! - `min_total_entities`: sum of `entities_current` across all clusters.
//!   Auto-injected at 80% of `target_players` when not explicitly set.
//! - `max_error_rate`: not yet wired — the snapshot doesn't carry an
//!   error-rate field today. Configured but ignored; lands when the driver
//!   pushes per-tick error counters into the telemetry stream.

use crate::plan::PhaseGate;
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

    /// Feed one snapshot.
    pub fn evaluate(&mut self, snap: &TelemetrySnapshot) -> Evaluation {
        // No configured axis = phase auto-passes.
        if self.config.max_p99_latency_ms.is_none()
            && self.config.min_entities.is_none()
            && self.config.max_error_rate.is_none()
            && self.config.min_total_entities.is_none()
        {
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

    /// True iff a prior phase has been marked Fail. Latches for the rest
    /// of the run; the scheduler queries this to short-circuit subsequent
    /// phases.
    pub fn any_phase_failed(&self) -> bool {
        self.any_phase_failed
    }

    pub fn consecutive_breaches(&self) -> u32 {
        self.consecutive_breaches
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
                eprintln!(
                    "gate: total entity count {total} below minimum {min_total}"
                );
                return true;
            }
        }
        // max_error_rate: currently unused — see module docstring.
        let _ = self.config.max_error_rate;
        false
    }
}
