//! Acceptance tests for #80 (per-phase results writer).
//! The tests are the spec.

use crate::plan::{Phase, PlanMeta, TestPlan};
use crate::results::{
    OverallOutcome, PhaseOutcome, PhaseOutcomeEntry, PhaseResult, ResultsWriter, RunManifest,
    Uploader,
};
use serde_json::json;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

/// Mock uploader: records every (key, body) pair.
#[derive(Default)]
struct MockUploader {
    calls: Mutex<Vec<(String, Vec<u8>)>>,
}
impl MockUploader {
    async fn calls(&self) -> Vec<(String, Vec<u8>)> {
        self.calls.lock().await.clone()
    }
}
impl Uploader for MockUploader {
    async fn upload(&self, key: String, body: Vec<u8>) -> Result<(), String> {
        self.calls.lock().await.push((key, body));
        Ok(())
    }
}

fn tempdir() -> std::path::PathBuf {
    let pid = std::process::id();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let p = std::env::temp_dir().join(format!("controller-results-test-{}-{}", pid, nanos));
    std::fs::create_dir_all(&p).unwrap();
    p
}

fn synth_phase_result(idx: usize, outcome: PhaseOutcome) -> PhaseResult {
    PhaseResult {
        phase_index: idx,
        phase_name: format!("phase_{}", idx),
        started_at_unix_ms: 1_700_000_000_000,
        ended_at_unix_ms: 1_700_000_060_000,
        outcome,
        cluster_deltas: json!({"cluster-a": {"bytes_out": 1_000_000_000}}),
        driver_metrics: json!({"mean_latency_ms": 50.0}),
    }
}

fn synth_manifest() -> RunManifest {
    RunManifest {
        plan_name: "headline-13500".into(),
        plan_sha: "deadbeef".into(),
        started_at_unix_ms: 1_700_000_000_000,
        ended_at_unix_ms: 1_700_000_180_000,
        phase_outcomes: vec![
            PhaseOutcomeEntry {
                phase_index: 0,
                phase_name: "warmup".into(),
                outcome: PhaseOutcome::Pass,
            },
            PhaseOutcomeEntry {
                phase_index: 1,
                phase_name: "ramp".into(),
                outcome: PhaseOutcome::Pass,
            },
        ],
        overall: OverallOutcome::Pass,
    }
}

fn synth_test_plan() -> TestPlan {
    TestPlan {
        plan: PlanMeta {
            name: "headline-13500".into(),
            description: String::new(),
        },
        phases: vec![Phase {
            name: "warmup".into(),
            target_players: 1000,
            spawn_delay_ms: 50,
            hold_seconds: 60,
            gate: None,
        }],
    }
}

#[tokio::test]
async fn three_phase_run_writes_phase_files_and_manifest() {
    let dir = tempdir();
    let writer = ResultsWriter::new(&dir, Arc::new(MockUploader::default()));
    writer.ensure_dir().await.unwrap();

    for i in 0..3 {
        writer
            .write_phase(&synth_phase_result(i, PhaseOutcome::Pass))
            .await
            .unwrap();
    }
    writer
        .write_manifest(&synth_test_plan(), &synth_manifest())
        .await
        .unwrap();

    for n in 1..=3 {
        let path = dir.join(format!("phase_{}.json", n));
        assert!(path.exists(), "{} should exist", path.display());
    }
    let manifest_path = dir.join("manifest.json");
    assert!(manifest_path.exists(), "manifest.json should exist");
}

#[tokio::test]
async fn phase_file_schema_includes_required_fields() {
    let dir = tempdir();
    let writer = ResultsWriter::new(&dir, Arc::new(MockUploader::default()));
    writer.ensure_dir().await.unwrap();

    let phase = synth_phase_result(0, PhaseOutcome::Pass);
    let path = writer.write_phase(&phase).await.unwrap();
    let bytes = tokio::fs::read(&path).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(json["phase_index"], 0);
    assert_eq!(json["phase_name"], "phase_0");
    assert!(json["started_at_unix_ms"].is_number());
    assert!(json["ended_at_unix_ms"].is_number());
    assert_eq!(json["outcome"]["outcome"], "pass");
    assert!(json["cluster_deltas"].is_object());
    assert!(json["driver_metrics"].is_object());
}

#[tokio::test]
async fn s3_upload_matches_local_byte_for_byte() {
    let dir = tempdir();
    let uploader = Arc::new(MockUploader::default());
    let writer = ResultsWriter::new(&dir, uploader.clone());
    writer.ensure_dir().await.unwrap();

    let phase = synth_phase_result(0, PhaseOutcome::Pass);
    let local_path = writer.write_phase(&phase).await.unwrap();
    writer
        .write_manifest(&synth_test_plan(), &synth_manifest())
        .await
        .unwrap();

    let calls = uploader.calls().await;
    assert_eq!(calls.len(), 2, "phase + manifest = 2 uploads");

    // Phase file body matches.
    let local_phase = tokio::fs::read(&local_path).await.unwrap();
    let (uploaded_phase_key, uploaded_phase_body) = &calls[0];
    assert_eq!(uploaded_phase_key, "phase_1.json");
    assert_eq!(local_phase, *uploaded_phase_body);

    // Manifest body matches.
    let local_manifest = tokio::fs::read(dir.join("manifest.json")).await.unwrap();
    let (uploaded_manifest_key, uploaded_manifest_body) = &calls[1];
    assert_eq!(uploaded_manifest_key, "manifest.json");
    assert_eq!(local_manifest, *uploaded_manifest_body);
}

#[tokio::test]
async fn schema_is_forward_compatible_with_extra_fields() {
    // A consumer reading a future-version phase file (with extra fields)
    // must still deserialize the known fields cleanly. Validate by parsing
    // a hand-rolled JSON with extra fields into PhaseResult.
    let with_extras = serde_json::json!({
        "phase_index": 0,
        "phase_name": "p1",
        "started_at_unix_ms": 1_700_000_000_000_u64,
        "ended_at_unix_ms": 1_700_000_060_000_u64,
        "outcome": { "outcome": "pass" },
        "cluster_deltas": {},
        "driver_metrics": {},
        "future_extra_field": "a value future-Martin added",
        "another_unknown": [1, 2, 3]
    });
    let parsed: PhaseResult =
        serde_json::from_value(with_extras).expect("forward-compatible parse");
    assert_eq!(parsed.phase_index, 0);
    assert_eq!(parsed.phase_name, "p1");
    assert!(matches!(parsed.outcome, PhaseOutcome::Pass));
}

#[tokio::test]
async fn fail_outcome_serializes_with_breach_axes() {
    let dir = tempdir();
    let writer = ResultsWriter::new(&dir, Arc::new(MockUploader::default()));
    writer.ensure_dir().await.unwrap();

    let phase = synth_phase_result(
        2,
        PhaseOutcome::Fail {
            breach_axes: vec!["max_p99_latency_ms".into()],
        },
    );
    let path = writer.write_phase(&phase).await.unwrap();
    let bytes = tokio::fs::read(&path).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["outcome"]["outcome"], "fail");
    assert_eq!(json["outcome"]["breach_axes"][0], "max_p99_latency_ms");
}
