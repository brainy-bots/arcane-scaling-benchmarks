//! Unit tests for PhaseMetricsAccumulator.

use crate::phase_metrics::PhaseMetricsAccumulator;
use arcane_swarm_orchestrator::protocol::DriverErrorBreakdown;
use arcane_swarm_orchestrator::telemetry::{
    ClusterWireStats, DriverMetricsWire, TelemetrySnapshot,
};
use std::collections::HashMap;

fn empty_snap() -> TelemetrySnapshot {
    TelemetrySnapshot {
        snapshot_at_unix_ms: 0,
        fleet: Vec::new(),
        recent_commands: Vec::new(),
        clusters: HashMap::new(),
        driver_metrics: HashMap::new(),
    }
}

fn snap_with_clusters(clusters: Vec<(&str, u64, u64)>) -> TelemetrySnapshot {
    let mut cs = HashMap::new();
    for (id, entities, tick_us) in clusters {
        cs.insert(
            id.to_string(),
            ClusterWireStats {
                bytes_in: 1000,
                bytes_out: 2000,
                last_tick_us: tick_us,
                broadcast_lagged_events: 0,
                entities_current: entities,
            },
        );
    }
    TelemetrySnapshot {
        snapshot_at_unix_ms: 0,
        fleet: Vec::new(),
        recent_commands: Vec::new(),
        clusters: cs,
        driver_metrics: HashMap::new(),
    }
}

fn snap_with_drivers(drivers: Vec<(&str, u64, u64, u64, u64)>) -> TelemetrySnapshot {
    let mut dm = HashMap::new();
    for (id, ok, err, lat_sum, lat_samples) in drivers {
        dm.insert(
            id.to_string(),
            DriverMetricsWire {
                ok,
                err,
                latency_sum_us: lat_sum,
                latency_samples: lat_samples,
                max_latency_us: 0,
                bytes: 0,
                errors: DriverErrorBreakdown::default(),
            },
        );
    }
    TelemetrySnapshot {
        snapshot_at_unix_ms: 0,
        fleet: Vec::new(),
        recent_commands: Vec::new(),
        clusters: HashMap::new(),
        driver_metrics: dm,
    }
}

#[test]
fn empty_accumulator_returns_zero_defaults() {
    let mut acc = PhaseMetricsAccumulator::new();
    let (cluster, driver) = acc.phase_summary();
    assert_eq!(cluster.snapshot_count, 0);
    assert_eq!(cluster.total_entities, 0);
    assert_eq!(driver.driver_count, 0);
    assert_eq!(driver.total_ok, 0);
}

#[test]
fn cluster_metrics_averaged_across_snapshots() {
    let mut acc = PhaseMetricsAccumulator::new();
    // 2 snapshots: first has 1000 entities, second has 3000
    acc.ingest(&snap_with_clusters(vec![("c1", 1000, 10_000)]));
    acc.ingest(&snap_with_clusters(vec![("c1", 3000, 20_000)]));
    let (cluster, _) = acc.phase_summary();
    assert_eq!(cluster.snapshot_count, 2);
    // average entities: (1000 + 3000) / 2 = 2000
    assert_eq!(cluster.total_entities, 2000);
    assert_eq!(cluster.worst_tick_us, 20_000);
    // mean tick: (10000 + 20000) / 2 = 15000
    assert_eq!(cluster.mean_tick_us, 15_000);
    assert_eq!(cluster.total_bytes_in, 2000);
    assert_eq!(cluster.total_bytes_out, 4000);
}

#[test]
fn driver_delta_computation() {
    let mut acc = PhaseMetricsAccumulator::new();
    // Baseline: driver has 100 ok, 0 err
    acc.ingest(&snap_with_drivers(vec![("d1", 100, 0, 1_000_000, 100)]));
    // Latest: driver has 600 ok, 5 err
    acc.ingest(&snap_with_drivers(vec![("d1", 600, 5, 6_000_000, 600)]));
    let (_, driver) = acc.phase_summary();
    assert_eq!(driver.driver_count, 1);
    assert_eq!(driver.total_ok, 500); // 600 - 100
    assert_eq!(driver.total_err, 5); // 5 - 0
    assert_eq!(driver.latency_sum_us, 5_000_000); // 6M - 1M
    assert_eq!(driver.latency_samples, 500); // 600 - 100
                                             // mean latency: 5_000_000 / 500 / 1000 = 10.0 ms
    assert!((driver.mean_latency_ms - 10.0).abs() < 0.001);
}

#[test]
fn multi_driver_delta() {
    let mut acc = PhaseMetricsAccumulator::new();
    // Baseline
    acc.ingest(&snap_with_drivers(vec![
        ("d1", 0, 0, 0, 0),
        ("d2", 0, 0, 0, 0),
        ("d3", 0, 0, 0, 0),
    ]));
    // Latest
    acc.ingest(&snap_with_drivers(vec![
        ("d1", 1000, 0, 10_000_000, 1000),
        ("d2", 1000, 10, 12_000_000, 1000),
        ("d3", 1000, 0, 8_000_000, 1000),
    ]));
    let (_, driver) = acc.phase_summary();
    assert_eq!(driver.driver_count, 3);
    assert_eq!(driver.total_ok, 3000);
    assert_eq!(driver.total_err, 10);
    // error_rate = 10 / 3010
    assert!((driver.error_rate - 10.0 / 3010.0).abs() < 0.0001);
}

#[test]
fn per_driver_latencies_sorted_ascending() {
    let mut acc = PhaseMetricsAccumulator::new();
    // Baseline: all zeros
    acc.ingest(&snap_with_drivers(vec![
        ("d1", 0, 0, 0, 0),
        ("d2", 0, 0, 0, 0),
        ("d3", 0, 0, 0, 0),
    ]));
    // Latest: different latencies per driver
    acc.ingest(&snap_with_drivers(vec![
        ("d1", 1000, 0, 15_000_000, 1000), // avg 15ms
        ("d2", 1000, 0, 8_000_000, 1000),  // avg 8ms
        ("d3", 1000, 0, 12_000_000, 1000), // avg 12ms
    ]));
    let lats = acc.per_driver_latencies();
    assert_eq!(lats.len(), 3);
    // Should be sorted: 8, 12, 15
    assert!((lats[0].1 - 8.0).abs() < 0.001);
    assert!((lats[1].1 - 12.0).abs() < 0.001);
    assert!((lats[2].1 - 15.0).abs() < 0.001);
}

#[test]
fn phase_summary_resets_accumulator() {
    let mut acc = PhaseMetricsAccumulator::new();
    acc.ingest(&snap_with_clusters(vec![("c1", 5000, 33_000)]));
    // Baseline then latest so delta is non-zero
    acc.ingest(&snap_with_drivers(vec![("d1", 0, 0, 0, 0)]));
    acc.ingest(&snap_with_drivers(vec![("d1", 1000, 0, 10_000_000, 1000)]));
    let (c1, d1) = acc.phase_summary();
    assert!(c1.snapshot_count > 0);
    assert!(d1.total_ok > 0);

    // After reset, everything should be zero
    let (c2, d2) = acc.phase_summary();
    assert_eq!(c2.snapshot_count, 0);
    assert_eq!(d2.driver_count, 0);
    assert_eq!(d2.total_ok, 0);
}

#[test]
fn baseline_captured_from_first_driver_snapshot() {
    let mut acc = PhaseMetricsAccumulator::new();
    // First snapshot has no drivers — baseline not captured yet
    acc.ingest(&empty_snap());
    // Second snapshot has drivers — this becomes the baseline
    acc.ingest(&snap_with_drivers(vec![("d1", 500, 0, 5_000_000, 500)]));
    // Third snapshot — latest
    acc.ingest(&snap_with_drivers(vec![("d1", 1000, 0, 10_000_000, 1000)]));
    let (_, driver) = acc.phase_summary();
    // Delta should be 1000-500=500, not 1000-0
    assert_eq!(driver.total_ok, 500);
    assert_eq!(driver.latency_samples, 500);
}

#[test]
fn driver_with_zero_samples_excluded_from_latencies() {
    let mut acc = PhaseMetricsAccumulator::new();
    acc.ingest(&snap_with_drivers(vec![
        ("d1", 0, 0, 0, 0),
        ("d2", 0, 0, 0, 0),
    ]));
    // d1 has samples, d2 does not
    acc.ingest(&snap_with_drivers(vec![
        ("d1", 1000, 0, 10_000_000, 1000),
        ("d2", 0, 0, 0, 0),
    ]));
    let lats = acc.per_driver_latencies();
    assert_eq!(lats.len(), 1);
    assert_eq!(lats[0].0, "d1");
}

#[test]
fn headline_from_readme_scenario() {
    // Simulate the README's 12-driver scenario
    let mut acc = PhaseMetricsAccumulator::new();
    // Baseline: all zeros
    let baseline_drivers: Vec<(&str, u64, u64, u64, u64)> = (0..12)
        .map(|i| {
            let id = Box::leak(format!("d{}", i).into_boxed_str()) as &str;
            (id, 0u64, 0u64, 0u64, 0u64)
        })
        .collect();
    acc.ingest(&snap_with_drivers(baseline_drivers));

    // Latest: each driver ~2M round-trips, ~10ms avg latency, 0 errors
    let latest_drivers: Vec<(&str, u64, u64, u64, u64)> = (0..12)
        .map(|i| {
            let id = Box::leak(format!("d{}", i).into_boxed_str()) as &str;
            let ok = 2_000_000u64;
            let lat_ms = 8.0 + (i as f64) * 0.5; // 8.0, 8.5, 9.0, ... 13.5
            let lat_sum = (lat_ms * 1000.0 * ok as f64) as u64;
            (id, ok, 0u64, lat_sum, ok)
        })
        .collect();
    acc.ingest(&snap_with_drivers(latest_drivers));

    let lats = acc.per_driver_latencies();
    assert_eq!(lats.len(), 12);

    // Min should be ~8.0, max ~13.5
    assert!((lats[0].1 - 8.0).abs() < 0.1);
    assert!((lats[11].1 - 13.5).abs() < 0.1);

    // Mean = (8.0 + 8.5 + ... + 13.5) / 12 = 10.75
    let mean: f64 = lats.iter().map(|(_, l)| l).sum::<f64>() / 12.0;
    assert!((mean - 10.75).abs() < 0.1);

    let (_, driver) = acc.phase_summary();
    assert_eq!(driver.total_ok, 24_000_000);
    assert_eq!(driver.total_err, 0);
    assert!((driver.error_rate).abs() < 0.0001);
}

#[test]
fn compute_headline_twelve_drivers() {
    use crate::results::DriverPhaseMetrics;
    use crate::run::compute_headline;

    // 12 drivers with latencies 8.0, 8.5, 9.0, ..., 13.5 ms (sorted)
    let per_driver_lats: Vec<(String, f64)> = (0..12)
        .map(|i| (format!("d{}", i), 8.0 + i as f64 * 0.5))
        .collect();
    let dm = DriverPhaseMetrics {
        driver_count: 12,
        total_ok: 24_000_000,
        total_err: 0,
        latency_sum_us: 0,
        latency_samples: 0,
        mean_latency_ms: 0.0,
        error_rate: 0.0,
    };
    let h = compute_headline(Some(("ramp-13500".into(), 13_500, per_driver_lats, dm)))
        .expect("should produce headline");

    assert_eq!(h.top_tier_name, "ramp-13500");
    assert_eq!(h.top_tier_ccu, 13_500);
    assert_eq!(h.driver_count, 12);
    // mean = (8.0 + 8.5 + ... + 13.5) / 12 = 10.75
    assert!((h.mean_latency_ms - 10.75).abs() < 0.01);
    // median of even count: avg of lats[5]=10.5 and lats[6]=11.0 = 10.75
    assert!((h.median_latency_ms - 10.75).abs() < 0.01);
    assert!((h.min_latency_ms - 8.0).abs() < 0.01);
    assert!((h.max_latency_ms - 13.5).abs() < 0.01);
    assert_eq!(h.total_round_trips, 24_000_000);
    assert_eq!(h.total_errors, 0);
    assert!((h.error_rate_pct).abs() < 0.001);
}

#[test]
fn compute_headline_odd_driver_count() {
    use crate::results::DriverPhaseMetrics;
    use crate::run::compute_headline;

    // 3 drivers: 5.0, 10.0, 15.0
    let per_driver_lats = vec![("d0".into(), 5.0), ("d1".into(), 10.0), ("d2".into(), 15.0)];
    let dm = DriverPhaseMetrics {
        driver_count: 3,
        total_ok: 3000,
        total_err: 30,
        latency_sum_us: 0,
        latency_samples: 0,
        mean_latency_ms: 0.0,
        error_rate: 0.0,
    };
    let h = compute_headline(Some(("tier".into(), 1000, per_driver_lats, dm)))
        .expect("should produce headline");

    assert_eq!(h.driver_count, 3);
    assert!((h.mean_latency_ms - 10.0).abs() < 0.01);
    // median of odd count: lats[1] = 10.0
    assert!((h.median_latency_ms - 10.0).abs() < 0.01);
    assert!((h.min_latency_ms - 5.0).abs() < 0.01);
    assert!((h.max_latency_ms - 15.0).abs() < 0.01);
    assert_eq!(h.total_round_trips, 3030);
    assert_eq!(h.total_errors, 30);
    // error_rate_pct = 30/3030 * 100 ≈ 0.99%
    assert!((h.error_rate_pct - 30.0 / 3030.0 * 100.0).abs() < 0.01);
}

#[test]
fn compute_headline_none_on_empty_input() {
    use crate::run::compute_headline;
    assert!(compute_headline(None).is_none());
}

#[test]
fn compute_headline_none_on_empty_latencies() {
    use crate::results::DriverPhaseMetrics;
    use crate::run::compute_headline;

    let h = compute_headline(Some((
        "tier".into(),
        1000,
        vec![],
        DriverPhaseMetrics::default(),
    )));
    assert!(h.is_none());
}
