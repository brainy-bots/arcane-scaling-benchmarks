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

/// Per-phase result file shape.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PhaseResult {
    pub phase_index: usize,
    pub phase_name: String,
    pub started_at_unix_ms: u128,
    pub ended_at_unix_ms: u128,
    pub outcome: PhaseOutcome,
    /// Aggregated cluster /stats deltas over the phase window.
    #[serde(default)]
    pub cluster_deltas: serde_json::Value,
    /// Aggregated driver-reported metrics over the phase window.
    #[serde(default)]
    pub driver_metrics: serde_json::Value,
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
