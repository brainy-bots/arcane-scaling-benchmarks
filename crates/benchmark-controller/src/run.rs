//! End-to-end controller run loop.
//!
//! Wires everything together: load plan → connect to orchestrator HTTP API
//! → spawn SSE consumer → for each phase: send commands → warmup gate
//! (wait for entities to reach target) → hold with live gates → phase-end
//! validation → write results → write final manifest.

use crate::dashboard::{spawn_dashboard, DashboardState};
use crate::gate::Evaluation;
use crate::orchestrator_client::HttpOrchestratorClient;
use crate::phase_metrics::PhaseMetricsAccumulator;
use crate::plan::{parse, Phase, TestPlan};
use crate::redis_monitor::RedisMonitor;
use crate::results::{
    HeadlineSummary, OverallOutcome, PhaseOutcome, PhaseOutcomeEntry, PhaseResult, ResultsWriter,
    RunManifest, Uploader,
};
use crate::scheduler::OrchestratorClient;
use crate::sse_consumer::{spawn_sse_consumer, LiveGateState};
use arcane_swarm_orchestrator::protocol::{
    OrchestratorCommand, SetPlayersCommand, SetSpawnDelayMsCommand,
};
use arcane_swarm_orchestrator::telemetry::TelemetrySnapshot;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{broadcast, Mutex, RwLock};

/// Configuration for one controller run.
pub struct RunConfig {
    /// Path to the TOML plan file.
    pub plan_path: PathBuf,
    /// Orchestrator HTTP base URL (e.g. `http://10.0.1.5:8090`).
    pub orchestrator_base_url: String,
    /// Local directory to write `phase_*.json` and `manifest.json`.
    pub results_dir: PathBuf,
    /// Submitter id recorded with each command in the orchestrator log.
    pub submitter: String,
    /// Whether to render the live ASCII dashboard to stdout.
    pub enable_dashboard: bool,
    /// Redis URL for health monitoring (e.g. `redis://10.0.0.5:6379`).
    /// When set, the controller polls `INFO` every 2 s and records per-phase
    /// Redis health metrics alongside the cluster/driver metrics.
    pub redis_url: Option<String>,
}

/// Final outcome of a run.
#[derive(Debug, Clone, PartialEq)]
pub struct RunOutcome {
    pub phase_outcomes: Vec<PhaseOutcomeEntry>,
    pub overall: OverallOutcome,
    pub manifest_path: PathBuf,
}

fn now_unix_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

fn plan_marker(toml_text: &str) -> String {
    let mut h: u64 = 5381;
    for b in toml_text.bytes() {
        h = h.wrapping_mul(33).wrapping_add(b as u64);
    }
    format!("{:016x}", h)
}

pub async fn run<U>(cfg: RunConfig, uploader: Arc<U>) -> Result<RunOutcome, String>
where
    U: Uploader + 'static,
{
    let toml_text =
        std::fs::read_to_string(&cfg.plan_path).map_err(|e| format!("read plan: {}", e))?;
    let plan: TestPlan = parse(&toml_text)?;
    let plan_sha = plan_marker(&toml_text);
    let tick_rate_hz = plan.plan.tick_rate_hz;

    let writer = ResultsWriter::new(&cfg.results_dir, uploader);
    writer
        .ensure_dir()
        .await
        .map_err(|e| format!("ensure_dir: {}", e))?;

    let live_gate = Arc::new(LiveGateState::new(
        plan.phases
            .first()
            .and_then(|p| p.gate.clone())
            .unwrap_or_default(),
    ));

    let (snap_tx, snap_rx_for_dashboard) = broadcast::channel::<TelemetrySnapshot>(64);
    let snap_rx_for_metrics = snap_tx.subscribe();
    let _sse = spawn_sse_consumer(
        cfg.orchestrator_base_url.clone(),
        live_gate.clone(),
        Some(snap_tx.clone()),
    );

    let redis_monitor = cfg.redis_url.as_ref().map(|url| {
        let mon = Arc::new(RedisMonitor::new());
        let _handle = mon.spawn(url.clone());
        eprintln!("redis_monitor: polling {}", url);
        mon
    });

    let metrics_acc = Arc::new(Mutex::new(PhaseMetricsAccumulator::new()));
    {
        let acc = metrics_acc.clone();
        let mut rx = snap_rx_for_metrics;
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(snap) => {
                        acc.lock().await.ingest(&snap);
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    let dashboard_state = Arc::new(RwLock::new(DashboardState::new(plan.clone())));
    let _dashboard = if cfg.enable_dashboard {
        Some(spawn_dashboard(
            dashboard_state.clone(),
            snap_rx_for_dashboard,
        ))
    } else {
        drop(snap_rx_for_dashboard);
        None
    };

    let abort_flag = Arc::new(AtomicBool::new(false));
    install_sigint_handler(abort_flag.clone());

    let started_at_unix_ms = now_unix_ms();
    let started_at = Instant::now();
    {
        let mut s = dashboard_state.write().await;
        s.overall_started_at = started_at;
        s.phase_started_at = started_at;
    }

    let client =
        HttpOrchestratorClient::new(cfg.orchestrator_base_url.clone(), cfg.submitter.clone());

    let mut phase_outcomes: Vec<PhaseOutcomeEntry> = Vec::new();
    let mut overall = OverallOutcome::Pass;
    #[allow(clippy::type_complexity)]
    let mut top_passing_tier: Option<(
        String,
        u32,
        Vec<(String, f64)>,
        crate::results::DriverPhaseMetrics,
    )> = None;

    let mut last_spawn_delay: Option<u32> = None;

    for (idx, phase) in plan.phases.iter().enumerate() {
        if abort_flag.load(Ordering::Relaxed) {
            let _ = client.submit(OrchestratorCommand::Stop).await;
            skip_remaining(&plan, idx, &mut phase_outcomes, "manual abort");
            overall = OverallOutcome::Fail;
            break;
        }

        // --- Configure gate for this phase ---
        let mut gate_config = phase.gate.clone().unwrap_or_default();
        // Auto-inject tick budget gate from plan's tick_rate_hz
        if gate_config.max_mean_tick_ms.is_none() && tick_rate_hz > 0 {
            gate_config.max_mean_tick_ms = Some(1000.0 / tick_rate_hz as f64);
        }
        // Auto-inject min_total_entities at 98% of target. Warmup guarantees
        // 100% at hold start; this catches mid-hold drops.
        if phase.target_players > 0 && gate_config.min_total_entities.is_none() {
            gate_config.min_total_entities =
                Some((phase.target_players as f64 * 0.98) as u64);
        }
        live_gate.start_phase(gate_config.clone()).await;

        let phase_started = now_unix_ms();
        let phase_started_inst = Instant::now();
        {
            let mut s = dashboard_state.write().await;
            s.current_phase_index = idx;
            s.phase_started_at = phase_started_inst;
            s.gate_state = "warmup".to_string();
        }

        // --- Send commands ---
        if last_spawn_delay != Some(phase.spawn_delay_ms) {
            if let Err(e) = client
                .submit(OrchestratorCommand::SetSpawnDelayMs(
                    SetSpawnDelayMsCommand {
                        spawn_delay_ms: phase.spawn_delay_ms,
                    },
                ))
                .await
            {
                record_fail(
                    &writer,
                    &metrics_acc,
                    &redis_monitor,
                    idx,
                    phase,
                    phase_started,
                    &mut phase_outcomes,
                    format!("SetSpawnDelayMs failed: {e}"),
                )
                .await;
                skip_remaining(&plan, idx + 1, &mut phase_outcomes, "earlier phase failed");
                overall = OverallOutcome::Fail;
                break;
            }
            last_spawn_delay = Some(phase.spawn_delay_ms);
        }

        if let Err(e) = client
            .submit(OrchestratorCommand::SetPlayers(SetPlayersCommand {
                player_count: phase.target_players,
            }))
            .await
        {
            record_fail(
                &writer,
                &metrics_acc,
                &redis_monitor,
                idx,
                phase,
                phase_started,
                &mut phase_outcomes,
                format!("SetPlayers failed: {e}"),
            )
            .await;
            skip_remaining(&plan, idx + 1, &mut phase_outcomes, "earlier phase failed");
            overall = OverallOutcome::Fail;
            break;
        }

        // --- Warmup gate: wait for entities to reach target ---
        if phase.target_players > 0 {
            let warmup_result = wait_for_warmup(
                phase,
                &snap_tx,
                &abort_flag,
                &dashboard_state,
            )
            .await;

            if let Err(reason) = warmup_result {
                eprintln!(
                    "phase {:?}: warmup failed — {}",
                    phase.name, reason
                );
                record_fail(
                    &writer,
                    &metrics_acc,
                    &redis_monitor,
                    idx,
                    phase,
                    phase_started,
                    &mut phase_outcomes,
                    reason,
                )
                .await;
                skip_remaining(&plan, idx + 1, &mut phase_outcomes, "earlier phase failed");
                overall = OverallOutcome::Fail;
                break;
            }
        }

        // --- Reset metrics for clean measurement window ---
        {
            let mut acc = metrics_acc.lock().await;
            acc.reset();
        }
        if let Some(ref mon) = redis_monitor {
            mon.reset_phase().await;
        }

        // --- Hold: poll gate at 500ms intervals ---
        {
            let mut s = dashboard_state.write().await;
            s.gate_state = "pass".to_string();
            s.phase_started_at = Instant::now(); // reset for hold progress
        }

        let hold = Duration::from_secs(phase.hold_seconds);
        let hold_start = Instant::now();
        let mut gate_failed = false;

        while hold_start.elapsed() < hold {
            if abort_flag.load(Ordering::Relaxed) {
                let _ = client.submit(OrchestratorCommand::Stop).await;
                skip_remaining(&plan, idx, &mut phase_outcomes, "manual abort");
                overall = OverallOutcome::Fail;
                break;
            }

            let eval = live_gate.current().await;
            if matches!(eval, Evaluation::Fail) {
                gate_failed = true;
                break;
            }

            let remaining = hold.saturating_sub(hold_start.elapsed());
            let sleep_for = Duration::from_millis(500).min(remaining);
            if sleep_for.is_zero() {
                break;
            }
            tokio::time::sleep(sleep_for).await;
        }

        if abort_flag.load(Ordering::Relaxed) {
            break;
        }

        // --- Collect phase metrics ---
        let (per_driver_lats, cluster_metrics, driver_metrics) = {
            let mut acc = metrics_acc.lock().await;
            let lats = acc.per_driver_latencies();
            let (c, d) = acc.phase_summary();
            (lats, c, d)
        };
        let redis_metrics = match &redis_monitor {
            Some(mon) => {
                let m = mon.phase_metrics().await;
                if m.evicted_clients_delta > 0 {
                    eprintln!(
                        "phase {:?}: WARNING — Redis evicted {} client(s) during this phase",
                        phase.name, m.evicted_clients_delta
                    );
                }
                eprintln!(
                    "phase {:?}: redis peak_out={:.0} kbps, clients={}-{}, mem={:.1} MB",
                    phase.name,
                    m.peak_output_kbps,
                    m.min_connected_clients,
                    m.max_connected_clients,
                    m.peak_memory_bytes as f64 / 1_048_576.0,
                );
                Some(m)
            }
            None => None,
        };

        // --- Determine phase outcome ---
        let phase_outcome = if gate_failed {
            {
                let mut s = dashboard_state.write().await;
                s.gate_state = "fail".to_string();
            }
            PhaseOutcome::Fail {
                breach_axes: vec!["live gate breach window exceeded".to_string()],
            }
        } else {
            // Phase-end validation
            let phase_end_result = {
                let gate = live_gate.gate_lock().await;
                gate.evaluate_phase_end(&cluster_metrics, &driver_metrics)
            };

            if !phase_end_result.passed {
                {
                    let mut s = dashboard_state.write().await;
                    s.gate_state = "fail".to_string();
                }
                eprintln!(
                    "phase {:?}: phase-end validation failed: {:?}",
                    phase.name, phase_end_result.breach_axes
                );
                PhaseOutcome::Fail {
                    breach_axes: phase_end_result.breach_axes,
                }
            } else {
                PhaseOutcome::Pass
            }
        };

        let is_pass = matches!(phase_outcome, PhaseOutcome::Pass);
        if is_pass && phase.target_players > 0 {
            top_passing_tier = Some((
                phase.name.clone(),
                phase.target_players,
                per_driver_lats,
                driver_metrics.clone(),
            ));
        }

        let _ = writer
            .write_phase(&PhaseResult {
                phase_index: idx,
                phase_name: phase.name.clone(),
                started_at_unix_ms: phase_started,
                ended_at_unix_ms: now_unix_ms(),
                outcome: phase_outcome.clone(),
                cluster_metrics,
                driver_metrics,
                redis_metrics,
            })
            .await
            .map_err(|e| format!("write_phase {}: {}", idx, e))?;

        phase_outcomes.push(PhaseOutcomeEntry {
            phase_index: idx,
            phase_name: phase.name.clone(),
            outcome: phase_outcome.clone(),
        });

        if !is_pass {
            overall = OverallOutcome::Fail;
            skip_remaining(&plan, idx + 1, &mut phase_outcomes, "earlier phase failed");
            break;
        }
    }

    // Terminal Stop
    {
        let _ = client.submit(OrchestratorCommand::Stop).await;
    }

    // Signal dashboard to exit
    {
        let mut s = dashboard_state.write().await;
        s.finished = true;
    }
    if let Some(h) = _dashboard {
        let _ = tokio::time::timeout(Duration::from_secs(3), h).await;
    }

    let ended_at_unix_ms = now_unix_ms();
    let headline = compute_headline(top_passing_tier);

    let manifest = RunManifest {
        plan_name: plan.plan.name.clone(),
        plan_sha,
        started_at_unix_ms,
        ended_at_unix_ms,
        phase_outcomes: phase_outcomes.clone(),
        overall,
        headline: headline.clone(),
    };
    let manifest_path = writer
        .write_manifest(&plan, &manifest)
        .await
        .map_err(|e| format!("write_manifest: {}", e))?;

    if let Some(ref h) = headline {
        eprintln!();
        eprintln!("─── HEADLINE SUMMARY ───");
        eprintln!(
            "Top tier: {} ({} CCU, {} drivers)",
            h.top_tier_name, h.top_tier_ccu, h.driver_count
        );
        eprintln!(
            "Mean driver latency: {:.2} ms (median {:.2} ms, range {:.2} – {:.2} ms)",
            h.mean_latency_ms, h.median_latency_ms, h.min_latency_ms, h.max_latency_ms
        );
        eprintln!(
            "Round-trips: {} | Errors: {} ({:.3}%)",
            h.total_round_trips, h.total_errors, h.error_rate_pct
        );
        eprintln!("────────────────────────");
    }

    Ok(RunOutcome {
        phase_outcomes,
        overall,
        manifest_path,
    })
}

/// Wait for entities to reach `target_players`. Returns Ok(()) on success,
/// Err(reason) on timeout or abort.
async fn wait_for_warmup(
    phase: &Phase,
    snap_tx: &broadcast::Sender<TelemetrySnapshot>,
    abort_flag: &Arc<AtomicBool>,
    dashboard_state: &Arc<RwLock<DashboardState>>,
) -> Result<(), String> {
    let target = phase.target_players as u64;
    let timeout = Duration::from_secs(phase.warmup_timeout_seconds);
    let started = Instant::now();
    let mut rx = snap_tx.subscribe();

    eprintln!(
        "phase {:?}: warmup — waiting for {} entities (timeout {}s)",
        phase.name, target, phase.warmup_timeout_seconds
    );

    loop {
        if abort_flag.load(Ordering::Relaxed) {
            return Err("manual abort during warmup".to_string());
        }

        if started.elapsed() >= timeout {
            return Err(format!(
                "warmup timeout: entities did not reach {} within {}s",
                target, phase.warmup_timeout_seconds
            ));
        }

        let remaining = timeout.saturating_sub(started.elapsed());
        let snap = tokio::select! {
            result = rx.recv() => {
                match result {
                    Ok(s) => s,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => {
                        return Err("SSE stream closed during warmup".to_string());
                    }
                }
            }
            _ = tokio::time::sleep(remaining) => {
                return Err(format!(
                    "warmup timeout: entities did not reach {} within {}s",
                    target, phase.warmup_timeout_seconds
                ));
            }
        };

        let total_entities: u64 = snap.clusters.values().map(|c| c.entities_current).sum();
        let elapsed = started.elapsed().as_secs();
        if total_entities >= target {
            eprintln!(
                "phase {:?}: warmup complete — {} entities reached in {}s",
                phase.name, total_entities, elapsed
            );
            {
                let mut s = dashboard_state.write().await;
                s.gate_state = "ready".to_string();
            }
            return Ok(());
        }

        // Update dashboard with warmup progress
        if elapsed % 5 == 0 {
            eprintln!(
                "phase {:?}: warmup {}/{} entities ({}s / {}s)",
                phase.name, total_entities, target, elapsed, phase.warmup_timeout_seconds
            );
        }
    }
}

/// Record a failed phase and write its result file.
async fn record_fail<U: Uploader + 'static>(
    writer: &ResultsWriter<U>,
    metrics_acc: &Arc<Mutex<PhaseMetricsAccumulator>>,
    redis_monitor: &Option<Arc<RedisMonitor>>,
    idx: usize,
    phase: &Phase,
    phase_started: u128,
    phase_outcomes: &mut Vec<PhaseOutcomeEntry>,
    reason: String,
) {
    let (cluster_metrics, driver_metrics) = {
        let mut acc = metrics_acc.lock().await;
        acc.phase_summary()
    };
    let redis_metrics = match redis_monitor {
        Some(mon) => Some(mon.phase_metrics().await),
        None => None,
    };
    let outcome = PhaseOutcome::Fail {
        breach_axes: vec![reason],
    };
    let _ = writer
        .write_phase(&PhaseResult {
            phase_index: idx,
            phase_name: phase.name.clone(),
            started_at_unix_ms: phase_started,
            ended_at_unix_ms: now_unix_ms(),
            outcome: outcome.clone(),
            cluster_metrics,
            driver_metrics,
            redis_metrics,
        })
        .await;
    phase_outcomes.push(PhaseOutcomeEntry {
        phase_index: idx,
        phase_name: phase.name.clone(),
        outcome,
    });
}

/// Mark all remaining phases as skipped.
fn skip_remaining(
    plan: &TestPlan,
    from: usize,
    phase_outcomes: &mut Vec<PhaseOutcomeEntry>,
    reason: &str,
) {
    for (j, p) in plan.phases.iter().enumerate().skip(from) {
        phase_outcomes.push(PhaseOutcomeEntry {
            phase_index: j,
            phase_name: p.name.clone(),
            outcome: PhaseOutcome::Skipped {
                reason: reason.to_string(),
            },
        });
    }
}

/// Compute the README headline numbers from the top passing tier's
/// per-driver latencies and aggregate metrics.
#[allow(clippy::type_complexity)]
pub(crate) fn compute_headline(
    top_tier: Option<(
        String,
        u32,
        Vec<(String, f64)>,
        crate::results::DriverPhaseMetrics,
    )>,
) -> Option<HeadlineSummary> {
    let (name, ccu, per_driver_lats, driver_metrics) = top_tier?;
    if per_driver_lats.is_empty() {
        return None;
    }

    let lats: Vec<f64> = per_driver_lats.iter().map(|(_, l)| *l).collect();
    let n = lats.len();
    let mean = lats.iter().sum::<f64>() / n as f64;
    let median = if n % 2 == 0 {
        (lats[n / 2 - 1] + lats[n / 2]) / 2.0
    } else {
        lats[n / 2]
    };
    let min = lats.first().copied().unwrap_or(0.0);
    let max = lats.last().copied().unwrap_or(0.0);

    let total_calls = driver_metrics.total_ok + driver_metrics.total_err;
    let error_rate_pct = if total_calls > 0 {
        driver_metrics.total_err as f64 / total_calls as f64 * 100.0
    } else {
        0.0
    };

    Some(HeadlineSummary {
        top_tier_name: name,
        top_tier_ccu: ccu,
        driver_count: n,
        mean_latency_ms: mean,
        median_latency_ms: median,
        min_latency_ms: min,
        max_latency_ms: max,
        total_round_trips: total_calls,
        total_errors: driver_metrics.total_err,
        error_rate_pct,
    })
}

fn install_sigint_handler(flag: Arc<AtomicBool>) {
    let f = flag.clone();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            f.store(true, Ordering::Relaxed);
        }
    });
}

/// Convenience: list `phase_*.json` + `manifest.json` filenames under `dir`.
pub async fn list_results(dir: impl AsRef<Path>) -> std::io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    let mut entries = tokio::fs::read_dir(dir).await?;
    while let Some(entry) = entries.next_entry().await? {
        let path = entry.path();
        if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
            if name == "manifest.json" || (name.starts_with("phase_") && name.ends_with(".json")) {
                out.push(path);
            }
        }
    }
    out.sort();
    Ok(out)
}
