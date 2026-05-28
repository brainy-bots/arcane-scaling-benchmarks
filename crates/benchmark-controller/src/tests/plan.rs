//! Acceptance tests for #77 (phase / test-plan TOML schema).
//! The tests are the spec.

use crate::plan::{parse, serialize, Phase, PhaseGate, PlanMeta, TestPlan};

const VALID_PLAN: &str = r#"
[plan]
name = "headline-13500"
description = "13,500 CCU headline benchmark"
tick_rate_hz = 60

[[phases]]
name = "warmup"
target_players = 1000
spawn_delay_ms = 50
hold_seconds = 60
warmup_timeout_seconds = 90
[phases.gate]
max_p99_latency_ms = 100

[[phases]]
name = "ramp"
target_players = 13500
spawn_delay_ms = 25
hold_seconds = 600
[phases.gate]
max_p99_latency_ms = 100
max_error_rate = 0.01
min_entities = 13000
max_mean_tick_ms = 16.67
min_sample_rate = 0.02
"#;

#[test]
fn parse_valid_plan_returns_typed_struct() {
    let plan = parse(VALID_PLAN).expect("valid plan should parse");
    assert_eq!(plan.plan.name, "headline-13500");
    assert_eq!(plan.plan.description, "13,500 CCU headline benchmark");
    assert_eq!(plan.plan.tick_rate_hz, 60);
    assert_eq!(plan.phases.len(), 2);

    let warmup = &plan.phases[0];
    assert_eq!(warmup.name, "warmup");
    assert_eq!(warmup.target_players, 1000);
    assert_eq!(warmup.spawn_delay_ms, 50);
    assert_eq!(warmup.hold_seconds, 60);
    assert_eq!(warmup.warmup_timeout_seconds, 90);
    let gate = warmup.gate.as_ref().expect("warmup has a gate");
    assert_eq!(gate.max_p99_latency_ms, Some(100));

    let ramp = &plan.phases[1];
    assert_eq!(ramp.name, "ramp");
    assert_eq!(ramp.target_players, 13500);
    assert_eq!(ramp.warmup_timeout_seconds, 120); // default
    let gate = ramp.gate.as_ref().expect("ramp has a gate");
    assert_eq!(gate.max_p99_latency_ms, Some(100));
    assert_eq!(gate.max_error_rate, Some(0.01));
    assert_eq!(gate.min_entities, Some(13000));
    assert!((gate.max_mean_tick_ms.unwrap() - 16.67).abs() < 0.001);
    assert!((gate.min_sample_rate.unwrap() - 0.02).abs() < 0.001);
}

#[test]
fn parse_unknown_top_level_key_rejected_with_clear_error() {
    let bad = r#"
[plan]
name = "x"

[[phases]]
name = "p"
target_players = 1
spawn_delay_ms = 1
hold_seconds = 1

[bogus_section]
foo = 1
"#;
    let err = parse(bad).expect_err("unknown top-level section should be rejected");
    assert!(
        err.contains("bogus_section") || err.contains("unknown"),
        "error should name the offending key; got: {}",
        err
    );
}

#[test]
fn parse_unknown_phase_key_rejected() {
    let bad = r#"
[plan]
name = "x"

[[phases]]
name = "p"
target_players = 1
spawn_delay_ms = 1
hold_seconds = 1
typo_field = 7
"#;
    let err = parse(bad).expect_err("unknown per-phase key should be rejected");
    assert!(
        err.contains("typo_field") || err.contains("unknown"),
        "error should name the offending key; got: {}",
        err
    );
}

#[test]
fn phases_preserve_file_order() {
    let plan = parse(VALID_PLAN).unwrap();
    assert_eq!(plan.phases[0].name, "warmup");
    assert_eq!(plan.phases[1].name, "ramp");
}

#[test]
fn phase_gate_optional() {
    let no_gate = r#"
[plan]
name = "x"

[[phases]]
name = "p"
target_players = 1
spawn_delay_ms = 1
hold_seconds = 1
"#;
    let plan = parse(no_gate).unwrap();
    assert!(plan.phases[0].gate.is_none());
}

#[test]
fn round_trip_parse_serialize_parse_is_identical() {
    let plan = parse(VALID_PLAN).unwrap();
    let toml_str = serialize(&plan).expect("serialize roundtrip");
    let plan2 = parse(&toml_str).expect("re-parse roundtrip");
    assert_eq!(plan, plan2);
}

#[test]
fn plan_meta_construct_from_parts_for_completeness() {
    // Construct Phase + PlanMeta + PhaseGate by hand to flush out missed
    // pub fields (the integration scaffolding for downstream issues uses the
    // types directly).
    let _ = TestPlan {
        plan: PlanMeta {
            name: "x".to_string(),
            description: String::new(),
            tick_rate_hz: 60,
        },
        phases: vec![Phase {
            name: "p".to_string(),
            target_players: 1,
            spawn_delay_ms: 1,
            hold_seconds: 1,
            warmup_timeout_seconds: 120,
            gate: Some(PhaseGate::default()),
        }],
    };
}
