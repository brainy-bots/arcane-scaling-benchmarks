//! Acceptance tests for #79 (validity gate).
//! The tests are the spec.

use crate::gate::{Evaluation, ValidityGate};
use crate::plan::PhaseGate;
use arcane_swarm_orchestrator::telemetry::{ClusterWireStats, TelemetrySnapshot};
use std::collections::HashMap;

fn snap_with_tick_us(last_tick_us: u64) -> TelemetrySnapshot {
    let mut clusters = HashMap::new();
    clusters.insert(
        "cluster-a".to_string(),
        ClusterWireStats {
            bytes_in: 0,
            bytes_out: 0,
            last_tick_us,
            broadcast_lagged_events: 0,
            entities_current: 1000,
        },
    );
    TelemetrySnapshot {
        snapshot_at_unix_ms: 0,
        fleet: Vec::new(),
        recent_commands: Vec::new(),
        clusters,
    }
}

fn snap_with_entities(entities_current: u64) -> TelemetrySnapshot {
    let mut clusters = HashMap::new();
    clusters.insert(
        "cluster-a".to_string(),
        ClusterWireStats {
            bytes_in: 0,
            bytes_out: 0,
            last_tick_us: 33_000,
            broadcast_lagged_events: 0,
            entities_current,
        },
    );
    TelemetrySnapshot {
        snapshot_at_unix_ms: 0,
        fleet: Vec::new(),
        recent_commands: Vec::new(),
        clusters,
    }
}

#[test]
fn phase_with_all_gates_passing_outcome_pass() {
    let mut gate = ValidityGate::new(PhaseGate {
        max_p99_latency_ms: Some(100),
        max_error_rate: None,
        min_entities: Some(500),
    });
    // last_tick_us = 33_000us = 33ms, well under 100ms
    // entities_current = 1000, well over 500
    let snap = snap_with_tick_us(33_000);
    assert_eq!(gate.evaluate(&snap), Evaluation::Pass);
}

#[test]
fn latency_breach_three_consecutive_outcome_fail_within_breach_window() {
    let mut gate = ValidityGate::new(PhaseGate {
        max_p99_latency_ms: Some(100),
        max_error_rate: None,
        min_entities: None,
    });
    // 200_000us = 200ms, exceeds 100ms
    let bad = snap_with_tick_us(200_000);

    assert_eq!(gate.evaluate(&bad), Evaluation::Pending); // 1
    assert_eq!(gate.evaluate(&bad), Evaluation::Pending); // 2
    assert_eq!(gate.evaluate(&bad), Evaluation::Fail); // 3 → fail
    assert!(gate.any_phase_failed());
}

#[test]
fn intermittent_breaches_do_not_fail_phase() {
    let mut gate = ValidityGate::new(PhaseGate {
        max_p99_latency_ms: Some(100),
        max_error_rate: None,
        min_entities: None,
    });
    let bad = snap_with_tick_us(200_000);
    let good = snap_with_tick_us(33_000);

    for _ in 0..10 {
        assert_eq!(gate.evaluate(&bad), Evaluation::Pending);
        assert_eq!(gate.evaluate(&good), Evaluation::Pass);
        // good resets the counter — never fails
    }
    assert!(!gate.any_phase_failed());
}

#[test]
fn fail_phase_short_circuits_subsequent_phases() {
    // After a phase fails, any_phase_failed remains true even after
    // start_phase resets the per-phase breach counter.
    let mut gate = ValidityGate::new(PhaseGate {
        max_p99_latency_ms: Some(100),
        ..PhaseGate::default()
    });
    let bad = snap_with_tick_us(200_000);
    gate.evaluate(&bad);
    gate.evaluate(&bad);
    gate.evaluate(&bad);
    assert!(gate.any_phase_failed());

    gate.start_phase(PhaseGate {
        max_p99_latency_ms: Some(100),
        ..PhaseGate::default()
    });
    assert_eq!(gate.consecutive_breaches(), 0);
    assert!(
        gate.any_phase_failed(),
        "any_phase_failed must remain latched across start_phase"
    );
}

#[test]
fn missing_gate_config_phase_auto_passes() {
    let mut gate = ValidityGate::new(PhaseGate::default()); // no axes set
    let snap = snap_with_tick_us(999_999_999); // would normally breach
    assert_eq!(gate.evaluate(&snap), Evaluation::Pass);
    assert!(!gate.any_phase_failed());
}

#[test]
fn min_entities_breach_counts_too() {
    let mut gate = ValidityGate::new(PhaseGate {
        min_entities: Some(1000),
        ..PhaseGate::default()
    })
    .with_breach_window(2);

    let bad = snap_with_entities(500);
    assert_eq!(gate.evaluate(&bad), Evaluation::Pending);
    assert_eq!(gate.evaluate(&bad), Evaluation::Fail);
}

#[test]
fn breach_window_can_be_overridden() {
    let mut gate = ValidityGate::new(PhaseGate {
        max_p99_latency_ms: Some(100),
        ..PhaseGate::default()
    })
    .with_breach_window(1);
    let bad = snap_with_tick_us(200_000);
    assert_eq!(gate.evaluate(&bad), Evaluation::Fail); // 1 breach is enough
}
