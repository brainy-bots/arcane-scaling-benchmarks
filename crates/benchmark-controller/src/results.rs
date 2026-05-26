//! Per-phase results writer (#80).
//!
//! At the end of each phase, write `phase_<index>.json` with the phase's
//! validity outcome and aggregated stats. At end of run, write `manifest.json`
//! with the run-level summary. Both are written locally and uploaded to S3
//! via a pluggable `Uploader` trait (mirrors the orchestrator's
//! TelemetryArchive pattern).

use crate::plan::TestPlan;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Aggregated cluster-side metrics over a phase's hold window.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct ClusterPhaseMetrics {
    pub total_entities: u64,
    pub cluster_count: usize,
    pub worst_tick_us: u64,
    pub mean_tick_us: u64,
    pub total_bytes_in: u64,
    pub total_bytes_out: u64,
    pub snapshot_count: u64,
}

/// Per-driver cumulative metrics at phase boundary.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct DriverPhaseMetrics {
    pub driver_count: usize,
    pub total_ok: u64,
    pub total_err: u64,
    pub latency_sum_us: u64,
    pub latency_samples: u64,
    pub mean_latency_ms: f64,
    pub error_rate: f64,
}

/// Headline numbers matching the README format. Computed from the top
/// passing tier's driver metrics at phase-end minus phase-start.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct HeadlineSummary {
    pub top_tier_name: String,
    pub top_tier_ccu: u32,
    pub driver_count: usize,
    pub mean_latency_ms: f64,
    pub median_latency_ms: f64,
    pub min_latency_ms: f64,
    pub max_latency_ms: f64,
    pub total_round_trips: u64,
    pub total_errors: u64,
    pub error_rate_pct: f64,
}

/// Per-phase result file shape.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PhaseResult {
    pub phase_index: usize,
    pub phase_name: String,
    pub started_at_unix_ms: u128,
    pub ended_at_unix_ms: u128,
    pub outcome: PhaseOutcome,
    #[serde(default)]
    pub cluster_metrics: ClusterPhaseMetrics,
    #[serde(default)]
    pub driver_metrics: DriverPhaseMetrics,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "outcome")]
pub enum PhaseOutcome {
    #[serde(rename = "pass")]
    Pass,
    #[serde(rename = "fail")]
    Fail { breach_axes: Vec<String> },
    #[serde(rename = "skipped")]
    Skipped { reason: String },
}

/// Run-level summary shape.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RunManifest {
    pub plan_name: String,
    pub plan_sha: String,
    pub started_at_unix_ms: u128,
    pub ended_at_unix_ms: u128,
    pub phase_outcomes: Vec<PhaseOutcomeEntry>,
    pub overall: OverallOutcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub headline: Option<HeadlineSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PhaseOutcomeEntry {
    pub phase_index: usize,
    pub phase_name: String,
    pub outcome: PhaseOutcome,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OverallOutcome {
    Pass,
    Fail,
}

/// Pluggable S3 uploader (parallels `arcane_swarm_orchestrator::telemetry_archive::Uploader`).
pub trait Uploader: Send + Sync {
    fn upload(
        &self,
        key: String,
        body: Vec<u8>,
    ) -> impl std::future::Future<Output = Result<(), String>> + Send;
}

/// No-op uploader for local-only deployments and tests where we only care
/// about disk artifacts.
pub struct NoopUploaderExt;
impl Uploader for NoopUploaderExt {
    async fn upload(&self, _key: String, _body: Vec<u8>) -> Result<(), String> {
        Ok(())
    }
}

/// Real S3 uploader. Shells out to the `aws` CLI rather than pulling in
/// `aws-sdk-s3` (the cloud nodes already have `aws` installed via the
/// AWS-CLI bootstrap; the operator's laptop has it too). Each upload runs
/// `aws s3 cp - s3://<bucket>/<prefix>/<key>` via stdin.
pub struct S3Uploader {
    bucket: String,
    prefix: String,
}

impl S3Uploader {
    pub fn new(bucket: impl Into<String>, prefix: impl Into<String>) -> Self {
        let mut p = prefix.into();
        if !p.is_empty() && !p.ends_with('/') {
            p.push('/');
        }
        Self {
            bucket: bucket.into(),
            prefix: p,
        }
    }
}

impl Uploader for S3Uploader {
    async fn upload(&self, key: String, body: Vec<u8>) -> Result<(), String> {
        use tokio::io::AsyncWriteExt;
        use tokio::process::Command;
        let s3_uri = format!("s3://{}/{}{}", self.bucket, self.prefix, key);
        let mut child = Command::new("aws")
            .args([
                "s3",
                "cp",
                "-",
                &s3_uri,
                "--no-progress",
                "--only-show-errors",
            ])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| format!("spawn aws s3 cp: {}", e))?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(&body).await.map_err(|e| e.to_string())?;
            // Drop closes stdin so aws sees EOF.
        }
        let out = child
            .wait_with_output()
            .await
            .map_err(|e| format!("wait aws s3 cp: {}", e))?;
        if !out.status.success() {
            return Err(format!(
                "aws s3 cp {} failed: {}",
                s3_uri,
                String::from_utf8_lossy(&out.stderr)
            ));
        }
        Ok(())
    }
}

pub struct ResultsWriter<U: Uploader + 'static> {
    pub dir: PathBuf,
    pub uploader: std::sync::Arc<U>,
}

impl<U: Uploader + 'static> ResultsWriter<U> {
    pub fn new(dir: impl Into<PathBuf>, uploader: std::sync::Arc<U>) -> Self {
        Self {
            dir: dir.into(),
            uploader,
        }
    }

    /// Ensure the output directory exists. Idempotent.
    pub async fn ensure_dir(&self) -> std::io::Result<()> {
        tokio::fs::create_dir_all(&self.dir).await
    }

    /// Write `phase_<index>.json` (1-indexed in the filename so it matches
    /// the prior tier-results convention) and upload the same bytes.
    pub async fn write_phase(&self, result: &PhaseResult) -> Result<PathBuf, String> {
        let body = serde_json::to_vec_pretty(result).map_err(|e| e.to_string())?;
        let filename = format!("phase_{}.json", result.phase_index + 1);
        let path = self.dir.join(&filename);
        tokio::fs::write(&path, &body)
            .await
            .map_err(|e| e.to_string())?;
        self.uploader.upload(filename, body).await?;
        Ok(path)
    }

    /// Write `manifest.json` (run-level summary) and upload the same bytes.
    /// `_plan` is accepted for future extension (e.g. embedding the plan
    /// snapshot) but not yet referenced — the manifest carries `plan_name`
    /// and `plan_sha` which are sufficient for the current contract.
    pub async fn write_manifest(
        &self,
        _plan: &TestPlan,
        manifest: &RunManifest,
    ) -> Result<PathBuf, String> {
        let body = serde_json::to_vec_pretty(manifest).map_err(|e| e.to_string())?;
        let filename = "manifest.json".to_string();
        let path = self.dir.join(&filename);
        tokio::fs::write(&path, &body)
            .await
            .map_err(|e| e.to_string())?;
        self.uploader.upload(filename, body).await?;
        Ok(path)
    }
}
