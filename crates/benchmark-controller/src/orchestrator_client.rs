//! HTTP-based `OrchestratorClient` impl that POSTs commands to the
//! orchestrator's `/commands/submit` endpoint.

use crate::scheduler::OrchestratorClient;
use arcane_swarm_orchestrator::protocol::OrchestratorCommand;
use arcane_swarm_orchestrator::sse_server::{SubmitRequest, SubmitResponse};

pub struct HttpOrchestratorClient {
    base_url: String,
    submitter: String,
    http: reqwest::Client,
}

impl HttpOrchestratorClient {
    /// `base_url` is the orchestrator's HTTP host (e.g. `http://10.0.1.5:8090`).
    /// `submitter` is recorded in the orchestrator's command log alongside
    /// each command — use a stable identifier for the run.
    pub fn new(base_url: impl Into<String>, submitter: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            submitter: submitter.into(),
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(10))
                .build()
                .expect("reqwest client"),
        }
    }
}

impl OrchestratorClient for HttpOrchestratorClient {
    async fn submit(&self, command: OrchestratorCommand) -> Result<(), String> {
        let req = SubmitRequest {
            submitter: self.submitter.clone(),
            command,
        };
        let url = format!("{}/commands/submit", self.base_url);
        let resp = self
            .http
            .post(&url)
            .json(&req)
            .send()
            .await
            .map_err(|e| format!("submit POST: {}", e))?;
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(format!("orchestrator {} {}: {}", url, status, body));
        }
        let _decoded: SubmitResponse =
            serde_json::from_str(&body).map_err(|e| format!("submit response decode: {}", e))?;
        Ok(())
    }
}
