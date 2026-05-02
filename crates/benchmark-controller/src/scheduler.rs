//! Ramp scheduler (#78).
//!
//! Drives the orchestrator through a `TestPlan`'s phase sequence by issuing
//! `SetSpawnDelayMs` (when it changes) and `SetPlayers` commands, then
//! holding for `phase.hold_seconds` (or aborting early if the validity gate
//! signals fail). Emits `Stop` after the last phase.

use crate::plan::TestPlan;
use std::time::Duration;

/// Reasons a scheduler run terminated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SchedulerOutcome {
    /// All phases completed.
    Completed,
    /// Validity gate signaled fail mid-phase.
    Aborted { phase_index: usize, reason: String },
    /// Manual abort from the operator (SIGINT, etc.).
    Manual,
}

/// Trait abstraction over the orchestrator's command-submission surface.
/// Production: WebSocket client to orchestrator. Tests: a `MockOrchestrator`
/// that records every submit.
pub trait OrchestratorClient: Send + Sync {
    fn submit(
        &self,
        command: arcane_swarm_orchestrator::protocol::OrchestratorCommand,
    ) -> impl std::future::Future<Output = Result<(), String>> + Send;
}

/// Trait abstraction over the validity-gate signal. Production: subscribes
/// to orchestrator SSE; tests: a scripted gate that returns Pass/Fail on cue.
pub trait GateSignal: Send + Sync {
    fn check(&self) -> impl std::future::Future<Output = GateState> + Send;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateState {
    /// No breach yet.
    Pass,
    /// Breach window exhausted; current phase failed.
    Fail,
}

/// The scheduler.
pub struct RampScheduler<C: OrchestratorClient + 'static, G: GateSignal + 'static> {
    pub plan: TestPlan,
    pub client: C,
    pub gate: G,
    /// Wall-clock check interval for the gate during a hold.
    pub gate_poll_interval: Duration,
}

impl<C: OrchestratorClient + 'static, G: GateSignal + 'static> RampScheduler<C, G> {
    pub fn new(plan: TestPlan, client: C, gate: G) -> Self {
        Self {
            plan,
            client,
            gate,
            gate_poll_interval: Duration::from_secs(2),
        }
    }

    /// Drive the plan from phase 0 to the end. Implementation lands in #78.
    pub async fn run(&self) -> SchedulerOutcome {
        unimplemented!("#78: scheduler run loop — see tests/scheduler.rs")
    }
}
