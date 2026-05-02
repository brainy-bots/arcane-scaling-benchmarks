//! Test-plan / phase config schema (#77).
//!
//! Loaded from a TOML file at controller startup. The scheduler walks each
//! phase in order; the validity gate evaluates per-phase acceptance.

use serde::{Deserialize, Serialize};

/// Top-level plan: identification + ordered phases.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TestPlan {
    pub plan: PlanMeta,
    pub phases: Vec<Phase>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlanMeta {
    pub name: String,
    #[serde(default)]
    pub description: String,
}

/// One phase: target player count, ramp pacing, hold duration, optional gate.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Phase {
    pub name: String,
    pub target_players: u32,
    pub spawn_delay_ms: u32,
    pub hold_seconds: u64,
    /// Optional per-phase acceptance gate. Phases with no gate auto-pass.
    #[serde(default)]
    pub gate: Option<PhaseGate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct PhaseGate {
    /// Per-phase maximum p99 latency in milliseconds.
    #[serde(default)]
    pub max_p99_latency_ms: Option<u32>,
    /// Per-phase maximum error rate (0.0 – 1.0). 0.05 = 5%.
    #[serde(default)]
    pub max_error_rate: Option<f64>,
    /// Minimum entities the cluster should be reporting; phase fails if it
    /// drops below this for the breach window.
    #[serde(default)]
    pub min_entities: Option<u64>,
}

/// Parse a TOML test plan from a string. Implementation lands in #77.
pub fn parse(_toml_text: &str) -> Result<TestPlan, String> {
    unimplemented!("#77: parse TOML test plan — see tests/plan.rs")
}
