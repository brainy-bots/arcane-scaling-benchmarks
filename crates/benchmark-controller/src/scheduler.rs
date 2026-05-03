//! Ramp scheduler (#78).
//!
//! Drives the orchestrator through a `TestPlan`'s phase sequence by issuing
//! `SetSpawnDelayMs` (when it changes) and `SetPlayers` commands, then
//! holding for `phase.hold_seconds` (or aborting early if the validity gate
//! signals fail). Emits `Stop` after the last phase or on any abort.

use crate::plan::TestPlan;
use arcane_swarm_orchestrator::protocol::{
    OrchestratorCommand, SetPlayersCommand, SetSpawnDelayMsCommand,
};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
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
        command: OrchestratorCommand,
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
    /// Manual-abort signal. The operator (SIGINT handler, test code) sets
    /// this to true to short-circuit the run; the scheduler emits Stop and
    /// returns `SchedulerOutcome::Manual`.
    pub abort: Arc<AtomicBool>,
    /// Whether to emit `Stop` after a successful Completed run. Defaults to
    /// true (back-compat for direct callers). The phase-by-phase runner in
    /// `run.rs` sets this to false because it wraps each phase in its own
    /// scheduler instance — the inter-phase Stop would tear down all
    /// drivers between phases and the next phase's commands would race
    /// against an empty fleet. Manual abort and gate failures still emit
    /// Stop unconditionally.
    pub emit_terminal_stop_on_completed: bool,
}

impl<C: OrchestratorClient + 'static, G: GateSignal + 'static> RampScheduler<C, G> {
    pub fn new(plan: TestPlan, client: C, gate: G) -> Self {
        Self {
            plan,
            client,
            gate,
            gate_poll_interval: Duration::from_secs(2),
            abort: Arc::new(AtomicBool::new(false)),
            emit_terminal_stop_on_completed: true,
        }
    }

    pub fn with_gate_poll_interval(mut self, d: Duration) -> Self {
        self.gate_poll_interval = d;
        self
    }

    pub fn with_emit_terminal_stop_on_completed(mut self, v: bool) -> Self {
        self.emit_terminal_stop_on_completed = v;
        self
    }

    /// Get a clone of the abort flag so an external SIGINT handler (or test)
    /// can signal manual abort.
    pub fn abort_handle(&self) -> Arc<AtomicBool> {
        self.abort.clone()
    }

    /// Drive the plan from phase 0 through the end. Returns the terminal
    /// outcome — Completed, Aborted (gate fail), or Manual.
    pub async fn run(&self) -> SchedulerOutcome {
        let mut last_spawn_delay: Option<u32> = None;
        for (idx, phase) in self.plan.phases.iter().enumerate() {
            if self.abort.load(Ordering::Relaxed) {
                let _ = self.client.submit(OrchestratorCommand::Stop).await;
                return SchedulerOutcome::Manual;
            }

            // Emit SetSpawnDelayMs only when it changes between phases.
            if last_spawn_delay != Some(phase.spawn_delay_ms) {
                if let Err(e) = self
                    .client
                    .submit(OrchestratorCommand::SetSpawnDelayMs(
                        SetSpawnDelayMsCommand {
                            spawn_delay_ms: phase.spawn_delay_ms,
                        },
                    ))
                    .await
                {
                    let _ = self.client.submit(OrchestratorCommand::Stop).await;
                    return SchedulerOutcome::Aborted {
                        phase_index: idx,
                        reason: format!("SetSpawnDelayMs failed: {}", e),
                    };
                }
                last_spawn_delay = Some(phase.spawn_delay_ms);
            }

            if let Err(e) = self
                .client
                .submit(OrchestratorCommand::SetPlayers(SetPlayersCommand {
                    player_count: phase.target_players,
                }))
                .await
            {
                let _ = self.client.submit(OrchestratorCommand::Stop).await;
                return SchedulerOutcome::Aborted {
                    phase_index: idx,
                    reason: format!("SetPlayers failed: {}", e),
                };
            }

            // Hold: poll gate at gate_poll_interval until hold_seconds elapses.
            let hold = Duration::from_secs(phase.hold_seconds);
            let started = std::time::Instant::now();
            while started.elapsed() < hold {
                if self.abort.load(Ordering::Relaxed) {
                    let _ = self.client.submit(OrchestratorCommand::Stop).await;
                    return SchedulerOutcome::Manual;
                }
                if matches!(self.gate.check().await, GateState::Fail) {
                    let _ = self.client.submit(OrchestratorCommand::Stop).await;
                    return SchedulerOutcome::Aborted {
                        phase_index: idx,
                        reason: "gate failed".into(),
                    };
                }
                let remaining = hold.saturating_sub(started.elapsed());
                let sleep_for = self.gate_poll_interval.min(remaining);
                if sleep_for.is_zero() {
                    break;
                }
                tokio::time::sleep(sleep_for).await;
            }
        }

        if self.emit_terminal_stop_on_completed {
            let _ = self.client.submit(OrchestratorCommand::Stop).await;
        }
        SchedulerOutcome::Completed
    }
}
