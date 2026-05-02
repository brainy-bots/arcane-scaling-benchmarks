//! Acceptance tests for #79 (validity gate).
//! The tests are the spec.

#[test]
#[ignore]
fn phase_with_all_gates_passing_outcome_pass() {
    // Acceptance: Phase with all gates passing → outcome `Pass`.
    todo!()
}

#[test]
#[ignore]
fn latency_breach_three_consecutive_outcome_fail_within_6s() {
    // Acceptance: Phase with latency exceeding gate for 3 consecutive events
    // → outcome `Fail` within ~6 s of breach (3 × 2 s evaluation cadence).
    todo!()
}

#[test]
#[ignore]
fn intermittent_breaches_do_not_fail_phase() {
    // Acceptance: Intermittent (non-consecutive) breaches do not fail the phase.
    todo!()
}

#[test]
#[ignore]
fn fail_phase_short_circuits_subsequent_phases() {
    // Acceptance: Phase marked `Fail` short-circuits subsequent phases.
    todo!()
}

#[test]
#[ignore]
fn missing_gate_config_phase_auto_passes() {
    // Acceptance: Missing gate config = phase auto-passes (no evaluation).
    todo!()
}
