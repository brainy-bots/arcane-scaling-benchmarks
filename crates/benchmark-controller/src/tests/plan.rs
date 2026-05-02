//! Acceptance tests for #77 (phase / test-plan TOML schema).
//! The tests are the spec. Implementation in `src/plan.rs` makes these pass.

#[test]
#[ignore]
fn parse_valid_plan_returns_typed_struct() {
    // Acceptance: Parsing a valid TOML returns a typed `TestPlan`.
    todo!()
}

#[test]
#[ignore]
fn parse_unknown_top_level_key_rejected_with_clear_error() {
    // Acceptance: Parsing rejects unknown top-level keys with a clear error.
    todo!()
}

#[test]
#[ignore]
fn phases_preserve_file_order() {
    // Acceptance: Phases are an ordered Vec<Phase>; index in the file is preserved.
    todo!()
}

#[test]
#[ignore]
fn phase_gate_optional() {
    // Acceptance: Per-phase `gate` is optional — phases without a gate are not evaluated.
    todo!()
}

#[test]
#[ignore]
fn round_trip_parse_serialize_parse_is_identical() {
    // Acceptance: parse → serialize → parse produces identical output (test fixture).
    todo!()
}
