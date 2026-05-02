//! Validity gate (#79).
//!
//! Subscribes to the orchestrator's telemetry SSE stream, evaluates per-phase
//! acceptance against the latest cluster /stats summary, and signals
//! `Fail` after `breach_window` consecutive breached evaluations.
//!
//! Pure logic — wire transport (HTTP/SSE) is plumbed in by the controller's
//! main loop; this module operates on already-parsed `TelemetrySnapshot`s.

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

/// The gate. Stateful: tracks consecutive breach count for the active phase.
pub struct ValidityGate {
    config: PhaseGate,
    breach_window: u32,
    consecutive_breaches: u32,
}

impl ValidityGate {
    pub fn new(config: PhaseGate) -> Self {
        Self {
            config,
            breach_window: 3,
            consecutive_breaches: 0,
        }
    }

    pub fn with_breach_window(mut self, n: u32) -> Self {
        self.breach_window = n;
        self
    }

    /// Reset for a new phase.
    pub fn start_phase(&mut self, _config: PhaseGate) {
        unimplemented!("#79: phase reset — see tests/gate.rs")
    }

    /// Feed one snapshot. Implementation lands in #79.
    pub fn evaluate(&mut self, _snap: &TelemetrySnapshot) -> Evaluation {
        let _ = (&self.config, self.breach_window, self.consecutive_breaches);
        unimplemented!("#79: per-snapshot evaluation — see tests/gate.rs")
    }

    pub fn consecutive_breaches(&self) -> u32 {
        self.consecutive_breaches
    }
}
