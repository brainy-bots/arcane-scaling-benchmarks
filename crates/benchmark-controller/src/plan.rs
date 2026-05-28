//! Test-plan / phase config schema (#77).
//!
//! Loaded from a TOML file at controller startup. The scheduler walks each
//! phase in order; the validity gate evaluates per-phase acceptance.

use serde::{Deserialize, Serialize};

/// Top-level plan: identification + ordered phases.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TestPlan {
    pub plan: PlanMeta,
    pub phases: Vec<Phase>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PlanMeta {
    pub name: String,
    #[serde(default)]
    pub description: String,
    /// Cluster tick rate in Hz. Defaults to 60. Used to derive the tick
    /// budget: any phase whose mean tick exceeds `1000 / tick_rate_hz` ms
    /// is physically unable to maintain the target rate.
    #[serde(default = "default_tick_rate_hz")]
    pub tick_rate_hz: u32,
}

fn default_tick_rate_hz() -> u32 {
    60
}

/// One phase: target player count, ramp pacing, hold duration, optional gate.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Phase {
    pub name: String,
    pub target_players: u32,
    pub spawn_delay_ms: u32,
    pub hold_seconds: u64,
    /// Maximum seconds to wait for entities to reach `target_players`
    /// before the hold timer starts. If entities don't reach the target
    /// within this window, the phase fails immediately. Defaults to 120.
    #[serde(default = "default_warmup_timeout")]
    pub warmup_timeout_seconds: u64,
    /// Optional per-phase acceptance gate. Phases with no gate auto-pass.
    #[serde(default)]
    pub gate: Option<PhaseGate>,
}

fn default_warmup_timeout() -> u64 {
    120
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(deny_unknown_fields)]
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
    /// Minimum total entities across ALL clusters. Phase fails if the sum
    /// of `entities_current` across clusters stays below this for the breach
    /// window. Auto-injected by the controller at 98% of `target_players`
    /// when not explicitly set — catches mid-hold entity drops (fd exhaustion,
    /// silent disconnects) where latency stays low but the system isn't
    /// actually loaded. The warmup gate guarantees 100% at hold start.
    #[serde(default)]
    pub min_total_entities: Option<u64>,
    /// Phase-end gate: maximum mean tick time in milliseconds over the hold
    /// window. Derived from `plan.tick_rate_hz` when set to `"auto"` in
    /// TOML — the controller computes `1000.0 / tick_rate_hz`. Set
    /// explicitly to override.
    #[serde(default)]
    pub max_mean_tick_ms: Option<f64>,
    /// Phase-end gate: minimum ratio of `latency_samples / total_round_trips`.
    /// If the sample rate drops below this, the latency measurement is
    /// statistically unreliable (e.g. the DeltaCache was silently discarding
    /// echo matches). 0.02 = 2%.
    #[serde(default)]
    pub min_sample_rate: Option<f64>,
    /// Phase-end gate: maximum mean driver round-trip latency in milliseconds
    /// over the hold window. Catches bandwidth saturation that the tick-time
    /// gate misses — the cluster can tick fast while frames pile up in TCP
    /// buffers.
    #[serde(default)]
    pub max_mean_latency_ms: Option<f64>,
    /// Phase-end gate: maximum total broadcast lag events across all clusters
    /// during the hold window. Any non-zero value means the broadcast channel
    /// dropped frames (subscribers couldn't keep up). Set to 0 for strictest
    /// enforcement.
    #[serde(default)]
    pub max_broadcast_lag_events: Option<u64>,
}

/// Parse a TOML test plan. Unknown top-level or per-section keys are
/// rejected so configuration typos surface immediately rather than being
/// silently ignored.
pub fn parse(toml_text: &str) -> Result<TestPlan, String> {
    toml::from_str::<TestPlan>(toml_text).map_err(|e| e.to_string())
}

/// Serialize a plan back to TOML. Used for round-trip stability tests and
/// for stamping the resolved plan into the run manifest.
pub fn serialize(plan: &TestPlan) -> Result<String, String> {
    toml::to_string(plan).map_err(|e| e.to_string())
}
