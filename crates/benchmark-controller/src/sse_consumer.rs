//! SSE consumer + adapter that turns `TelemetrySnapshot` events into
//! `GateState` for the scheduler.
//!
//! Spawns a background task that holds an HTTP/SSE connection to the
//! orchestrator's `/telemetry/stream`, parses each `data: <json>` event into a
//! `TelemetrySnapshot`, feeds it through a shared `ValidityGate`, and stores
//! the most recent `Evaluation` in an `ArcSwap`-style `RwLock`. The
//! scheduler queries via the `GateSignal` impl below.

use crate::gate::{Evaluation, ValidityGate};
use crate::plan::PhaseGate;
use crate::scheduler::{GateSignal, GateState};
use arcane_swarm_orchestrator::telemetry::TelemetrySnapshot;
use futures::StreamExt;
use std::sync::Arc;
use tokio::sync::{Mutex, RwLock};

/// Live, mutable phase state that both the scheduler and the SSE consumer
/// read/write.
pub struct LiveGateState {
    gate: Mutex<ValidityGate>,
    last: RwLock<Evaluation>,
}

impl LiveGateState {
    pub fn new(initial: PhaseGate) -> Self {
        Self {
            gate: Mutex::new(ValidityGate::new(initial)),
            last: RwLock::new(Evaluation::Pass),
        }
    }

    /// Reset for a new phase. Call from the scheduler at phase boundaries.
    pub async fn start_phase(&self, config: PhaseGate) {
        self.gate.lock().await.start_phase(config);
        *self.last.write().await = Evaluation::Pass;
    }

    /// Feed one snapshot. Used by the SSE consumer.
    pub async fn ingest(&self, snap: &TelemetrySnapshot) {
        let mut gate = self.gate.lock().await;
        let outcome = gate.evaluate(snap);
        *self.last.write().await = outcome;
    }

    pub async fn current(&self) -> Evaluation {
        *self.last.read().await
    }
}

/// `GateSignal` impl that reads `LiveGateState::current` and maps to
/// `Pass` / `Fail`.
pub struct LiveGateSignal {
    state: Arc<LiveGateState>,
}

impl LiveGateSignal {
    pub fn new(state: Arc<LiveGateState>) -> Self {
        Self { state }
    }
}

impl GateSignal for LiveGateSignal {
    async fn check(&self) -> GateState {
        match self.state.current().await {
            Evaluation::Fail => GateState::Fail,
            _ => GateState::Pass,
        }
    }
}

/// Spawn an SSE consumer task. The task holds an HTTP/SSE connection to
/// `<base_url>/telemetry/stream`, parses each event into a
/// `TelemetrySnapshot`, and feeds it into `state`. Returns a JoinHandle the
/// caller can abort on shutdown.
pub fn spawn_sse_consumer(
    base_url: String,
    state: Arc<LiveGateState>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let url = format!("{}/telemetry/stream", base_url.trim_end_matches('/'));
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(0))
            .build();
        let client = match client {
            Ok(c) => c,
            Err(_) => return,
        };
        loop {
            // Reconnect on disconnect with a small backoff.
            let resp = match client.get(&url).send().await {
                Ok(r) => r,
                Err(_) => {
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                    continue;
                }
            };
            if !resp.status().is_success() {
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                continue;
            }
            let mut stream = resp.bytes_stream();
            let mut buf = String::new();
            while let Some(chunk_res) = stream.next().await {
                let bytes = match chunk_res {
                    Ok(b) => b,
                    Err(_) => break,
                };
                buf.push_str(&String::from_utf8_lossy(&bytes));
                while let Some(pos) = buf.find("\n\n") {
                    let frame = buf[..pos].to_string();
                    buf.drain(..pos + 2);
                    for line in frame.lines() {
                        if let Some(json_str) = line.strip_prefix("data: ") {
                            if let Ok(snap) = serde_json::from_str::<TelemetrySnapshot>(json_str) {
                                state.ingest(&snap).await;
                            }
                        }
                    }
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
    })
}
