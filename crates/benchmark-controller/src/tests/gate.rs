//! Acceptance tests for #79 (validity gate).
//! The tests are the spec.

use crate::gate::{Evaluation, ValidityGate};
use crate::plan::PhaseGate;
use crate::results::{ClusterPhaseMetrics, DriverPhaseMetrics};
use arcane_swarm_orchestrator::protocol::DriverErrorBreakdown;
use arcane_swarm_orchestrator::telemetry::{
    ClusterWireStats, DriverMetricsWire, TelemetrySnapshot,
};
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
        driver_metrics: HashMap::new(),
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
        driver_metrics: HashMap::new(),
    }
}

#[test]
fn phase_with_all_gates_passing_outcome_pass() {
    let mut gate = ValidityGate::new(PhaseGate {
        max_p99_latency_ms: Some(100),
        min_entities: Some(500),
        ..PhaseGate::default()
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
        ..PhaseGate::default()
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
        ..PhaseGate::default()
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

fn snap_multi_cluster(entities: &[u64]) -> TelemetrySnapshot {
    let mut clusters = HashMap::new();
    for (i, &e) in entities.iter().enumerate() {
        clusters.insert(
            format!("cluster-{}", (b'a' + i as u8) as char),
            ClusterWireStats {
                bytes_in: 0,
                bytes_out: 0,
                last_tick_us: 33_000,
                broadcast_lagged_events: 0,
                entities_current: e,
            },
        );
    }
    TelemetrySnapshot {
        snapshot_at_unix_ms: 0,
        fleet: Vec::new(),
        recent_commands: Vec::new(),
        clusters,
        driver_metrics: HashMap::new(),
    }
}

#[test]
fn min_total_entities_passes_when_sum_exceeds_threshold() {
    let mut gate = ValidityGate::new(PhaseGate {
        min_total_entities: Some(10_000),
        ..PhaseGate::default()
    });
    // 3 clusters × 4500 = 13500, above 10000
    let snap = snap_multi_cluster(&[4500, 4500, 4500]);
    assert_eq!(gate.evaluate(&snap), Evaluation::Pass);
}

#[test]
fn min_total_entities_breach_on_fd_exhaustion() {
    // Simulates fd exhaustion: 3 clusters each capped at ~1100 entities
    // instead of the expected ~4500. Total 3300 << 10800 (80% of 13500).
    let mut gate = ValidityGate::new(PhaseGate {
        min_total_entities: Some(10_800),
        ..PhaseGate::default()
    })
    .with_breach_window(3);

    let bad = snap_multi_cluster(&[1100, 1100, 1100]);
    assert_eq!(gate.evaluate(&bad), Evaluation::Pending);
    assert_eq!(gate.evaluate(&bad), Evaluation::Pending);
    assert_eq!(gate.evaluate(&bad), Evaluation::Fail);
    assert!(gate.any_phase_failed());
}

#[test]
fn min_total_entities_intermittent_recovery() {
    let mut gate = ValidityGate::new(PhaseGate {
        min_total_entities: Some(10_000),
        ..PhaseGate::default()
    });
    let bad = snap_multi_cluster(&[1100, 1100, 1100]);
    let good = snap_multi_cluster(&[4500, 4500, 4500]);

    assert_eq!(gate.evaluate(&bad), Evaluation::Pending);
    assert_eq!(gate.evaluate(&bad), Evaluation::Pending);
    // Recovery before breach window completes
    assert_eq!(gate.evaluate(&good), Evaluation::Pass);
    assert_eq!(gate.consecutive_breaches(), 0);
}

#[test]
fn min_total_entities_not_configured_auto_passes() {
    let mut gate = ValidityGate::new(PhaseGate::default());
    // Even with very low entities, no axes = auto-pass
    let snap = snap_multi_cluster(&[1, 1, 1]);
    assert_eq!(gate.evaluate(&snap), Evaluation::Pass);
}

// --- max_error_rate (per-snapshot gate) ---

fn snap_with_driver_errors(ok: u64, err: u64) -> TelemetrySnapshot {
    let mut dm = HashMap::new();
    dm.insert(
        "d1".to_string(),
        DriverMetricsWire {
            ok,
            err,
            latency_sum_us: 0,
            latency_samples: 0,
            max_latency_us: 0,
            bytes: 0,
            errors: DriverErrorBreakdown::default(),
        },
    );
    TelemetrySnapshot {
        snapshot_at_unix_ms: 0,
        fleet: Vec::new(),
        recent_commands: Vec::new(),
        clusters: HashMap::new(),
        driver_metrics: dm,
    }
}

#[test]
fn max_error_rate_passes_when_under_threshold() {
    let mut gate = ValidityGate::new(PhaseGate {
        max_error_rate: Some(0.05),
        ..PhaseGate::default()
    });
    // 1% error rate, well under 5%
    let snap = snap_with_driver_errors(990, 10);
    assert_eq!(gate.evaluate(&snap), Evaluation::Pass);
}

#[test]
fn max_error_rate_breaches_when_over_threshold() {
    let mut gate = ValidityGate::new(PhaseGate {
        max_error_rate: Some(0.05),
        ..PhaseGate::default()
    })
    .with_breach_window(1);
    // 10% error rate, over 5%
    let snap = snap_with_driver_errors(900, 100);
    assert_eq!(gate.evaluate(&snap), Evaluation::Fail);
}

#[test]
fn max_error_rate_zero_traffic_does_not_breach() {
    let mut gate = ValidityGate::new(PhaseGate {
        max_error_rate: Some(0.05),
        ..PhaseGate::default()
    });
    let snap = snap_with_driver_errors(0, 0);
    assert_eq!(gate.evaluate(&snap), Evaluation::Pass);
}

// --- Phase-end gates ---

fn cluster_metrics(mean_tick_us: u64) -> ClusterPhaseMetrics {
    ClusterPhaseMetrics {
        total_entities: 13500,
        cluster_count: 9,
        worst_tick_us: mean_tick_us + 5000,
        mean_tick_us,
        total_bytes_in: 0,
        total_bytes_out: 0,
        total_broadcast_lagged_events: 0,
        snapshot_count: 60,
    }
}

fn cluster_metrics_with_lag(mean_tick_us: u64, lagged: u64) -> ClusterPhaseMetrics {
    ClusterPhaseMetrics {
        total_broadcast_lagged_events: lagged,
        ..cluster_metrics(mean_tick_us)
    }
}

fn driver_metrics(ok: u64, err: u64, samples: u64) -> DriverPhaseMetrics {
    let total = ok + err;
    DriverPhaseMetrics {
        driver_count: 12,
        total_ok: ok,
        total_err: err,
        latency_sum_us: samples * 10_000,
        latency_samples: samples,
        mean_latency_ms: 10.0,
        error_rate: if total > 0 {
            err as f64 / total as f64
        } else {
            0.0
        },
    }
}

fn driver_metrics_with_latency(ok: u64, samples: u64, mean_latency_ms: f64) -> DriverPhaseMetrics {
    DriverPhaseMetrics {
        mean_latency_ms,
        ..driver_metrics(ok, 0, samples)
    }
}

#[test]
fn phase_end_tick_budget_passes_at_60hz() {
    let gate = ValidityGate::new(PhaseGate {
        max_mean_tick_ms: Some(16.67),
        ..PhaseGate::default()
    });
    // 10ms mean tick — well within 16.67ms budget
    let result = gate.evaluate_phase_end(&cluster_metrics(10_000), &driver_metrics(1000, 0, 50));
    assert!(result.passed);
    assert!(result.breach_axes.is_empty());
}

#[test]
fn phase_end_tick_budget_fails_when_overrun() {
    let gate = ValidityGate::new(PhaseGate {
        max_mean_tick_ms: Some(16.67),
        ..PhaseGate::default()
    });
    // 50ms mean tick — way over 16.67ms
    let result = gate.evaluate_phase_end(&cluster_metrics(50_000), &driver_metrics(1000, 0, 50));
    assert!(!result.passed);
    assert_eq!(result.breach_axes.len(), 1);
    assert!(result.breach_axes[0].contains("max_mean_tick_ms"));
}

#[test]
fn phase_end_sample_rate_passes_at_5pct() {
    let gate = ValidityGate::new(PhaseGate {
        min_sample_rate: Some(0.02),
        ..PhaseGate::default()
    });
    // 50 samples / 1000 round-trips = 5%, above 2%
    let result = gate.evaluate_phase_end(&cluster_metrics(10_000), &driver_metrics(1000, 0, 50));
    assert!(result.passed);
}

#[test]
fn phase_end_sample_rate_fails_when_too_low() {
    let gate = ValidityGate::new(PhaseGate {
        min_sample_rate: Some(0.02),
        ..PhaseGate::default()
    });
    // 5 samples / 1000 round-trips = 0.5%, below 2%
    let result = gate.evaluate_phase_end(&cluster_metrics(10_000), &driver_metrics(1000, 0, 5));
    assert!(!result.passed);
    assert_eq!(result.breach_axes.len(), 1);
    assert!(result.breach_axes[0].contains("min_sample_rate"));
}

#[test]
fn phase_end_sample_rate_fails_on_zero_round_trips() {
    let gate = ValidityGate::new(PhaseGate {
        min_sample_rate: Some(0.02),
        ..PhaseGate::default()
    });
    let result = gate.evaluate_phase_end(&cluster_metrics(10_000), &driver_metrics(0, 0, 0));
    assert!(!result.passed);
    assert!(result.breach_axes[0].contains("zero round-trips"));
}

#[test]
fn phase_end_multiple_axes_can_fail_together() {
    let gate = ValidityGate::new(PhaseGate {
        max_mean_tick_ms: Some(16.67),
        min_sample_rate: Some(0.02),
        ..PhaseGate::default()
    });
    // Tick overrun AND low sample rate
    let result = gate.evaluate_phase_end(&cluster_metrics(50_000), &driver_metrics(1000, 0, 5));
    assert!(!result.passed);
    assert_eq!(result.breach_axes.len(), 2);
}

#[test]
fn phase_end_no_axes_configured_passes() {
    let gate = ValidityGate::new(PhaseGate::default());
    let result = gate.evaluate_phase_end(&cluster_metrics(50_000), &driver_metrics(1000, 0, 5));
    assert!(result.passed);
}

// --- max_mean_latency_ms (phase-end gate) ---

#[test]
fn phase_end_latency_passes_under_budget() {
    let gate = ValidityGate::new(PhaseGate {
        max_mean_latency_ms: Some(200.0),
        ..PhaseGate::default()
    });
    let result = gate.evaluate_phase_end(
        &cluster_metrics(10_000),
        &driver_metrics_with_latency(1000, 50, 150.0),
    );
    assert!(result.passed);
}

#[test]
fn phase_end_latency_fails_over_budget() {
    let gate = ValidityGate::new(PhaseGate {
        max_mean_latency_ms: Some(200.0),
        ..PhaseGate::default()
    });
    // 9455ms mean latency — the exact scenario from the tier-3250 run
    let result = gate.evaluate_phase_end(
        &cluster_metrics(10_000),
        &driver_metrics_with_latency(1000, 50, 9455.0),
    );
    assert!(!result.passed);
    assert_eq!(result.breach_axes.len(), 1);
    assert!(result.breach_axes[0].contains("max_mean_latency_ms"));
}

// --- max_broadcast_lag_events (phase-end gate) ---

#[test]
fn phase_end_broadcast_lag_passes_at_zero() {
    let gate = ValidityGate::new(PhaseGate {
        max_broadcast_lag_events: Some(0),
        ..PhaseGate::default()
    });
    let result = gate.evaluate_phase_end(&cluster_metrics(10_000), &driver_metrics(1000, 0, 50));
    assert!(result.passed);
}

#[test]
fn phase_end_broadcast_lag_fails_when_frames_dropped() {
    let gate = ValidityGate::new(PhaseGate {
        max_broadcast_lag_events: Some(0),
        ..PhaseGate::default()
    });
    let result = gate.evaluate_phase_end(
        &cluster_metrics_with_lag(10_000, 500),
        &driver_metrics(1000, 0, 50),
    );
    assert!(!result.passed);
    assert_eq!(result.breach_axes.len(), 1);
    assert!(result.breach_axes[0].contains("max_broadcast_lag_events"));
}

#[test]
fn phase_end_broadcast_lag_tolerant_threshold() {
    let gate = ValidityGate::new(PhaseGate {
        max_broadcast_lag_events: Some(100),
        ..PhaseGate::default()
    });
    // 50 lag events, under threshold of 100
    let result = gate.evaluate_phase_end(
        &cluster_metrics_with_lag(10_000, 50),
        &driver_metrics(1000, 0, 50),
    );
    assert!(result.passed);
}

#[test]
fn phase_end_latency_and_lag_fail_together() {
    let gate = ValidityGate::new(PhaseGate {
        max_mean_latency_ms: Some(200.0),
        max_broadcast_lag_events: Some(0),
        ..PhaseGate::default()
    });
    let result = gate.evaluate_phase_end(
        &cluster_metrics_with_lag(10_000, 1000),
        &driver_metrics_with_latency(1000, 50, 9000.0),
    );
    assert!(!result.passed);
    assert_eq!(result.breach_axes.len(), 2);
}
