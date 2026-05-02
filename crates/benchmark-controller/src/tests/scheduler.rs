//! Acceptance tests for #78 (ramp scheduler).
//! The tests are the spec.

use crate::plan::{Phase, PlanMeta, TestPlan};
use crate::scheduler::{
    GateSignal, GateState, OrchestratorClient, RampScheduler, SchedulerOutcome,
};
use arcane_swarm_orchestrator::protocol::OrchestratorCommand;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
use tokio::sync::Mutex;

/// Records every command submitted; replies Ok by default.
#[derive(Default)]
struct MockOrch {
    submitted: Mutex<Vec<OrchestratorCommand>>,
}
impl MockOrch {
    async fn snapshot(&self) -> Vec<OrchestratorCommand> {
        self.submitted.lock().await.clone()
    }
}
impl OrchestratorClient for MockOrch {
    async fn submit(&self, command: OrchestratorCommand) -> Result<(), String> {
        self.submitted.lock().await.push(command);
        Ok(())
    }
}

/// Always-Pass gate.
struct AlwaysPass;
impl GateSignal for AlwaysPass {
    async fn check(&self) -> GateState {
        GateState::Pass
    }
}

/// Returns Pass for the first `pass_n` calls, then Fail forever.
struct FailAfter {
    remaining_passes: AtomicUsize,
}
impl FailAfter {
    fn new(pass_n: usize) -> Self {
        Self {
            remaining_passes: AtomicUsize::new(pass_n),
        }
    }
}
impl GateSignal for FailAfter {
    async fn check(&self) -> GateState {
        if self
            .remaining_passes
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |x| {
                if x > 0 {
                    Some(x - 1)
                } else {
                    Some(0)
                }
            })
            .unwrap_or(0)
            > 0
        {
            GateState::Pass
        } else {
            GateState::Fail
        }
    }
}

fn three_phase_plan() -> TestPlan {
    TestPlan {
        plan: PlanMeta {
            name: "test".into(),
            description: String::new(),
        },
        phases: vec![
            Phase {
                name: "p1".into(),
                target_players: 100,
                spawn_delay_ms: 50,
                hold_seconds: 0,
                gate: None,
            },
            Phase {
                name: "p2".into(),
                target_players: 200,
                spawn_delay_ms: 50, // same as p1 — should NOT re-emit SetSpawnDelayMs
                hold_seconds: 0,
                gate: None,
            },
            Phase {
                name: "p3".into(),
                target_players: 300,
                spawn_delay_ms: 25, // changed — SHOULD emit SetSpawnDelayMs
                hold_seconds: 0,
                gate: None,
            },
        ],
    }
}

#[tokio::test]
async fn three_phase_plan_emits_three_set_players_in_order() {
    let plan = three_phase_plan();
    let orch = MockOrch::default();
    let scheduler = RampScheduler::new(plan, orch, AlwaysPass);

    let outcome = scheduler.run().await;
    assert_eq!(outcome, SchedulerOutcome::Completed);

    let cmds = scheduler.client.snapshot().await;
    let set_players: Vec<u32> = cmds
        .iter()
        .filter_map(|c| match c {
            OrchestratorCommand::SetPlayers(s) => Some(s.player_count),
            _ => None,
        })
        .collect();
    assert_eq!(set_players, vec![100, 200, 300]);
}

#[tokio::test]
async fn set_spawn_delay_only_emitted_when_value_changes() {
    let plan = three_phase_plan();
    let orch = MockOrch::default();
    let scheduler = RampScheduler::new(plan, orch, AlwaysPass);
    let _ = scheduler.run().await;

    let cmds = scheduler.client.snapshot().await;
    let spawn_delays: Vec<u32> = cmds
        .iter()
        .filter_map(|c| match c {
            OrchestratorCommand::SetSpawnDelayMs(s) => Some(s.spawn_delay_ms),
            _ => None,
        })
        .collect();
    // p1: 50 (initial change from None), p2: 50 (no change, skipped), p3: 25 (change)
    assert_eq!(spawn_delays, vec![50, 25]);
}

#[tokio::test]
async fn final_stop_sent_after_last_phase_hold_completes() {
    let plan = three_phase_plan();
    let orch = MockOrch::default();
    let scheduler = RampScheduler::new(plan, orch, AlwaysPass);
    let _ = scheduler.run().await;

    let cmds = scheduler.client.snapshot().await;
    assert!(matches!(cmds.last().unwrap(), OrchestratorCommand::Stop));
}

#[tokio::test]
async fn gate_fail_short_circuits_remaining_phases() {
    let mut plan = three_phase_plan();
    // Give phases a non-zero hold so the gate has a chance to fire.
    for p in plan.phases.iter_mut() {
        p.hold_seconds = 1;
    }
    let orch = MockOrch::default();
    // Pass once (so the first phase enters its hold), then fail forever.
    let gate = FailAfter::new(0);
    let scheduler =
        RampScheduler::new(plan, orch, gate).with_gate_poll_interval(Duration::from_millis(10));
    let outcome = scheduler.run().await;
    assert!(matches!(outcome, SchedulerOutcome::Aborted { .. }));

    let cmds = scheduler.client.snapshot().await;
    // Only the first phase's SetPlayers should be present (not p2 or p3).
    let player_counts: Vec<u32> = cmds
        .iter()
        .filter_map(|c| match c {
            OrchestratorCommand::SetPlayers(s) => Some(s.player_count),
            _ => None,
        })
        .collect();
    assert_eq!(player_counts, vec![100]);
    assert!(cmds.contains(&OrchestratorCommand::Stop));
}

#[tokio::test]
async fn manual_abort_emits_stop_and_exits_cleanly() {
    let mut plan = three_phase_plan();
    plan.phases[0].hold_seconds = 5; // long enough to abort mid-hold

    let orch = MockOrch::default();
    let scheduler = RampScheduler::new(plan, orch, AlwaysPass)
        .with_gate_poll_interval(Duration::from_millis(20));
    let abort = scheduler.abort_handle();

    // Trigger abort after 50ms.
    let aborter = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        abort.store(true, Ordering::Relaxed);
    });

    let started = std::time::Instant::now();
    let outcome = scheduler.run().await;
    let elapsed = started.elapsed();

    aborter.abort();
    assert_eq!(outcome, SchedulerOutcome::Manual);
    assert!(
        elapsed < Duration::from_secs(2),
        "manual abort should exit promptly; took {:?}",
        elapsed
    );
    let cmds = scheduler.client.snapshot().await;
    assert!(cmds.contains(&OrchestratorCommand::Stop));
}

#[tokio::test]
async fn no_phase_zero_hold_still_calls_gate_at_least_zero_times() {
    // Sanity: zero-hold phases skip the gate-poll loop entirely; they should
    // not deadlock the scheduler if the gate is broken.
    struct PanicGate;
    impl GateSignal for PanicGate {
        async fn check(&self) -> GateState {
            panic!("gate must not be called for zero-hold phases");
        }
    }
    let plan = three_phase_plan(); // all hold_seconds = 0
    let orch = MockOrch::default();
    let scheduler = RampScheduler::new(plan, orch, PanicGate);
    let outcome = scheduler.run().await;
    assert_eq!(outcome, SchedulerOutcome::Completed);
}
