//! Acceptance tests for #78 (ramp scheduler).
//! The tests are the spec.

#[test]
#[ignore]
fn three_phase_plan_emits_three_set_players_in_order() {
    // Acceptance: Plan with 3 phases produces 3 `SetPlayers` calls in the
    // right order, each at ~the right wall-clock offset.
    todo!()
}

#[test]
#[ignore]
fn set_spawn_delay_only_emitted_when_value_changes() {
    // Acceptance: `SetSpawnDelayMs` is only emitted when the value changes
    // between phases.
    todo!()
}

#[test]
#[ignore]
fn final_stop_sent_after_last_phase_hold_completes() {
    // Acceptance: Final `Stop` is sent after the last phase's hold completes.
    todo!()
}

#[test]
#[ignore]
fn gate_fail_short_circuits_remaining_phases() {
    // Acceptance: A validity-gate `Fail` mid-phase causes the scheduler to
    // short-circuit the remaining phases and emit `Stop` immediately.
    todo!()
}

#[test]
#[ignore]
fn manual_abort_emits_stop_and_exits_cleanly() {
    // Acceptance: Manual abort (e.g. SIGINT) emits `Stop` and exits cleanly.
    todo!()
}
