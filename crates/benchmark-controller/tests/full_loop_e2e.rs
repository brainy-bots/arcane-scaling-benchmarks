//! Local end-to-end test: real orchestrator (in-process) + synthetic driver
//! + benchmark-controller's `run()` — driving a real TOML plan, writing
//!   real `phase_*.json` + `manifest.json` to a real tempdir.
//!
//! This is the "no Docker, no AWS" smoke test that validates the entire
//! controller path before any deployment.

use arcane_swarm_orchestrator::command_dispatcher::CommandDispatcher;
use arcane_swarm_orchestrator::driver_pool::DriverPool;
use arcane_swarm_orchestrator::protocol::{
    CommandAck, CommandEnvelope, DriverMessage, OrchestratorResponse, RegisterRequest,
};
use arcane_swarm_orchestrator::server::handle_connection as driver_handle_connection;
use arcane_swarm_orchestrator::sse_server::serve_bound;
use arcane_swarm_orchestrator::stats_collector::{ClusterEndpoint, ClusterStats, StatsCollector};
use arcane_swarm_orchestrator::telemetry::TelemetrySource;
use arcane_swarm_orchestrator::ws_driver_channel::WsDriverChannel;
use benchmark_controller::results::{NoopUploaderExt, OverallOutcome, PhaseOutcome};
use benchmark_controller::run::{list_results, run, RunConfig};
use futures::{SinkExt, StreamExt};
use serde_json::json;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::{client_async, tungstenite::Message};

struct IdleEndpoint;
impl ClusterEndpoint for IdleEndpoint {
    fn url(&self) -> &str {
        "https://test/stats"
    }
    async fn fetch(&self) -> Result<ClusterStats, String> {
        Ok(ClusterStats {
            bytes_in: 0,
            bytes_out: 0,
            last_tick_us: 33_000,
            broadcast_lagged_events: 0,
            entities_current: 1000,
            sampled_at: Instant::now(),
        })
    }
}

async fn spawn_orchestrator() -> (
    String, // driver WS url
    String, // HTTP base url for controller
    Arc<DriverPool>,
    Arc<TelemetrySource<WsDriverChannel, IdleEndpoint>>,
) {
    let pool = Arc::new(DriverPool::new(
        Duration::from_millis(100),
        Duration::from_secs(2),
        16,
    ));
    let dispatcher = Arc::new(CommandDispatcher::<WsDriverChannel>::new(pool.clone()));

    // Driver WS server
    let driver_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let driver_addr = driver_listener.local_addr().unwrap();
    let driver_url = format!("ws://{}", driver_addr);
    let pool_for_driver = pool.clone();
    let dispatcher_for_driver = dispatcher.clone();
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = driver_listener.accept().await else {
                return;
            };
            let pool = pool_for_driver.clone();
            let dispatcher = dispatcher_for_driver.clone();
            tokio::spawn(async move {
                let _ = driver_handle_connection(stream, pool, Some(dispatcher)).await;
            });
        }
    });

    // HTTP API server (telemetry SSE + command submit)
    let endpoint = Arc::new(IdleEndpoint);
    let collector = Arc::new(StatsCollector::new(vec![endpoint]));
    collector.poll_once().await.unwrap();
    let source = Arc::new(TelemetrySource::new(
        pool.clone(),
        dispatcher.clone(),
        collector.clone(),
    ));
    let (http_addr, _h) = serve_bound(
        "127.0.0.1:0".parse().unwrap(),
        source.clone(),
        Some(dispatcher.clone()),
    )
    .await
    .unwrap();
    let http_url = format!("http://{}", http_addr);

    // Drive periodic telemetry snapshots so the SSE consumer in the
    // controller has something to read.
    let s2 = source.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_millis(50)).await;
            s2.tick().await;
        }
    });

    (driver_url, http_url, pool, source)
}

async fn spawn_synthetic_driver(driver_url: String) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let stream = TcpStream::connect(driver_url.trim_start_matches("ws://"))
            .await
            .unwrap();
        let (ws, _) = client_async(&driver_url, stream).await.unwrap();
        let (mut sender, mut receiver) = ws.split();

        let req = DriverMessage::Register(RegisterRequest {
            capabilities: json!({"role": "smoke-test-driver"}),
        });
        sender
            .send(Message::Text(serde_json::to_string(&req).unwrap()))
            .await
            .unwrap();
        let msg = receiver.next().await.unwrap().unwrap();
        let resp: OrchestratorResponse = serde_json::from_str(msg.to_text().unwrap()).unwrap();
        let driver_id = match resp {
            OrchestratorResponse::Ack(ack) => ack.driver_id.unwrap(),
            other => panic!("expected register Ack, got {:?}", other),
        };

        // Ack every Command envelope; ignore other messages.
        while let Some(Ok(msg)) = receiver.next().await {
            if !msg.is_text() {
                continue;
            }
            if let Ok(OrchestratorResponse::Command(CommandEnvelope { seq, .. })) =
                serde_json::from_str::<OrchestratorResponse>(msg.to_text().unwrap())
            {
                let ack = DriverMessage::CommandAck(CommandAck {
                    driver_id,
                    command_seq: seq,
                });
                let _ = sender
                    .send(Message::Text(serde_json::to_string(&ack).unwrap()))
                    .await;
            }
        }
    })
}

fn tempdir() -> std::path::PathBuf {
    let pid = std::process::id();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let p = std::env::temp_dir().join(format!("controller-fullloop-{}-{}", pid, nanos));
    std::fs::create_dir_all(&p).unwrap();
    p
}

const SMOKE_PLAN: &str = r#"
[plan]
name = "smoke"
description = "local-only end-to-end smoke for the controller binary path"

[[phases]]
name = "tiny-warmup"
target_players = 50
spawn_delay_ms = 5
hold_seconds = 0

[[phases]]
name = "tiny-ramp"
target_players = 100
spawn_delay_ms = 5
hold_seconds = 0
[phases.gate]
min_entities = 100
"#;

#[tokio::test]
async fn full_loop_writes_phase_files_and_manifest() {
    let (driver_url, http_url, pool, _source) = spawn_orchestrator().await;
    let _driver = spawn_synthetic_driver(driver_url).await;

    // Wait for driver registration
    for _ in 0..50 {
        if pool.len().await >= 1 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(pool.len().await, 1, "synthetic driver should register");

    // Write plan to a tempfile
    let dir = tempdir();
    let plan_path = dir.join("plan.toml");
    std::fs::write(&plan_path, SMOKE_PLAN).unwrap();
    let results_dir = dir.join("results");

    let cfg = RunConfig {
        plan_path,
        orchestrator_base_url: http_url.clone(),
        results_dir: results_dir.clone(),
        submitter: "smoke-test".to_string(),
        enable_dashboard: false,
    };
    let outcome = run(cfg, Arc::new(NoopUploaderExt))
        .await
        .expect("run should succeed");

    // Both phases should have passed (the phase-2 gate min_entities=100 is
    // satisfied because IdleEndpoint reports entities_current=1000).
    assert_eq!(outcome.overall, OverallOutcome::Pass);
    assert_eq!(outcome.phase_outcomes.len(), 2);
    for entry in &outcome.phase_outcomes {
        assert!(matches!(entry.outcome, PhaseOutcome::Pass));
    }

    // phase_1.json + phase_2.json + manifest.json on disk
    let files = list_results(&results_dir).await.unwrap();
    let names: Vec<String> = files
        .iter()
        .map(|p| p.file_name().unwrap().to_string_lossy().to_string())
        .collect();
    assert!(names.contains(&"phase_1.json".to_string()));
    assert!(names.contains(&"phase_2.json".to_string()));
    assert!(names.contains(&"manifest.json".to_string()));
}
