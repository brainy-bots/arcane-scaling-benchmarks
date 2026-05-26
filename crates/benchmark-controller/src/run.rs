//! End-to-end controller run loop.
//!
//! Wires everything together: load plan → connect to orchestrator HTTP API
//! → spawn SSE consumer → start `RampScheduler` → on each phase boundary
//! reset the live gate → write per-phase results → write final manifest.
//!
//! This is what the `benchmark-controller` binary calls from `main`.

use crate::dashboard::{spawn_dashboard, DashboardState};
use crate::gate::Evaluation;
use crate::orchestrator_client::HttpOrchestratorClient;
use crate::phase_metrics::PhaseMetricsAccumulator;
use crate::plan::{parse, TestPlan};
use crate::results::{
    HeadlineSummary, OverallOutcome, PhaseOutcome, PhaseOutcomeEntry, PhaseResult, ResultsWriter,
    RunManifest, Uploader,
};
use crate::scheduler::{OrchestratorClient, RampScheduler, SchedulerOutcome};
use crate::sse_consumer::{spawn_sse_consumer, LiveGateSignal, LiveGateState};
use arcane_swarm_orchestrator::telemetry::TelemetrySnapshot;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};
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
    /// Whether to render the live ASCII dashboard to stdout. Callers
    /// should set this to `std::io::stdout().is_terminal()` (auto) or
    /// override via a CLI flag. When false, only the binary's terminal
    /// summary line is printed.
    pub enable_dashboard: bool,
}

/// Final outcome of a run.
#[derive(Debug, Clone, PartialEq)]
pub struct RunOutcome {
    pub scheduler_outcome: SchedulerOutcome,
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

/// Compute a stable hex-encoded SHA-like marker for the plan file. We use a
/// minimal djb2-style fold rather than pulling in a hash dependency — the
/// goal is "matches when the file is byte-identical, differs otherwise."
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

    // Snapshot broadcast — single SSE connection feeds the gate ingestion
    // path, the dashboard, and the metrics accumulator. Capacity 64 covers
    // ~2 min of 2-Hz snapshots before a slow subscriber would Lag (which
    // the dashboard tolerates by skipping).
    let (snap_tx, snap_rx_for_dashboard) = broadcast::channel::<TelemetrySnapshot>(64);
    let snap_rx_for_metrics = snap_tx.subscribe();
    let _sse = spawn_sse_consumer(
        cfg.orchestrator_base_url.clone(),
        live_gate.clone(),
        Some(snap_tx.clone()),
    );

    // Metrics accumulator — receives every snapshot and tracks per-phase
    // cluster and driver metrics. Shared with the run loop via mutex.
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

    // Dashboard wiring. The `DashboardState` is updated by the per-phase
    // loop below as phases progress and gate state changes, so the
    // renderer can show the current phase, hold progress, and gate.
    let dashboard_state = Arc::new(RwLock::new(DashboardState::new(plan.clone())));
    let _dashboard = if cfg.enable_dashboard {
        Some(spawn_dashboard(
            dashboard_state.clone(),
            snap_rx_for_dashboard,
        ))
    } else {
        // Drop the receiver so the broadcast doesn't keep buffering
        // when no one will read.
        drop(snap_rx_for_dashboard);
        None
    };

    let abort_flag = Arc::new(AtomicBool::new(false));
    install_sigint_handler(abort_flag.clone());

    let started_at_unix_ms = now_unix_ms();
    let started_at = Instant::now();
    {
        // Anchor the dashboard's "elapsed" clock to the same start instant
        // so the on-screen counter matches the manifest's started_at.
        let mut s = dashboard_state.write().await;
        s.overall_started_at = started_at;
        s.phase_started_at = started_at;
    }

    let mut phase_outcomes: Vec<PhaseOutcomeEntry> = Vec::new();
    let mut overall = OverallOutcome::Pass;
    let mut last_scheduler_outcome = SchedulerOutcome::Completed;
    // Track the top passing tier's data for headline summary.
    #[allow(clippy::type_complexity)]
    let mut top_passing_tier: Option<(
        String,
        u32,
        Vec<(String, f64)>,
        crate::results::DriverPhaseMetrics,
    )> = None;

    for (idx, phase) in plan.phases.iter().enumerate() {
        // Per-phase: reset the live gate, build a single-phase mini-scheduler,
        // run it. Wrapping each phase in its own scheduler call keeps the
        // results-writing boundary clean and lets us record per-phase
        // outcomes against the same phase the gate was reset for.
        let mut gate_config = phase.gate.clone().unwrap_or_default();
        let mut auto_injected_entity_gate = false;
        if phase.target_players > 0 && gate_config.min_total_entities.is_none() {
            let auto_min = (phase.target_players as f64 * 0.8) as u64;
            eprintln!(
                "phase {:?}: auto-injecting min_total_entities={auto_min} (80% of {})",
                phase.name, phase.target_players
            );
            gate_config.min_total_entities = Some(auto_min);
            auto_injected_entity_gate = true;
        }
        live_gate.start_phase(gate_config).await;
        if auto_injected_entity_gate {
            // Ramp needs time to spawn players — use a wider breach window
            // (~15s at 2Hz) so the gate doesn't fire before entities appear.
            live_gate.set_breach_window(30).await;
        }

        let phase_started = now_unix_ms();
        let phase_started_inst = Instant::now();
        {
            let mut s = dashboard_state.write().await;
            s.current_phase_index = idx;
            s.phase_started_at = phase_started_inst;
            s.gate_state = "pass".to_string();
        }
        let single_phase_plan = TestPlan {
            plan: plan.plan.clone(),
            phases: vec![phase.clone()],
        };
        let client =
            HttpOrchestratorClient::new(cfg.orchestrator_base_url.clone(), cfg.submitter.clone());
        let signal = LiveGateSignal::new(live_gate.clone());
        let mut scheduler = RampScheduler::new(single_phase_plan, client, signal)
            .with_emit_terminal_stop_on_completed(false);
        // Share the abort flag across all per-phase schedulers.
        scheduler.abort = abort_flag.clone();
        let outcome = scheduler.run().await;
        last_scheduler_outcome = outcome.clone();
        let phase_ended = now_unix_ms();
        let phase_dur = phase_started_inst.elapsed();

        let phase_outcome = match (&outcome, live_gate.current().await) {
            (SchedulerOutcome::Completed, _) => PhaseOutcome::Pass,
            (SchedulerOutcome::Aborted { reason, .. }, Evaluation::Fail) => PhaseOutcome::Fail {
                breach_axes: vec![reason.clone()],
            },
            (SchedulerOutcome::Aborted { reason, .. }, _) => PhaseOutcome::Fail {
                breach_axes: vec![reason.clone()],
            },
            (SchedulerOutcome::Manual, _) => PhaseOutcome::Skipped {
                reason: "manual abort".into(),
            },
        };
        {
            let mut s = dashboard_state.write().await;
            s.gate_state = match &phase_outcome {
                PhaseOutcome::Pass => "pass",
                PhaseOutcome::Fail { .. } => "fail",
                PhaseOutcome::Skipped { .. } => "skipped",
            }
            .to_string();
        }
        let _ = phase_dur;

        let (per_driver_lats, cluster_metrics, driver_metrics) = {
            let mut acc = metrics_acc.lock().await;
            let lats = acc.per_driver_latencies();
            let (c, d) = acc.phase_summary();
            (lats, c, d)
        };

        // Track per-driver latencies for headline at the top passing tier.
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
                ended_at_unix_ms: phase_ended,
                outcome: phase_outcome.clone(),
                cluster_metrics,
                driver_metrics,
            })
            .await
            .map_err(|e| format!("write_phase {}: {}", idx, e))?;

        phase_outcomes.push(PhaseOutcomeEntry {
            phase_index: idx,
            phase_name: phase.name.clone(),
            outcome: phase_outcome.clone(),
        });

        // If this phase failed or was aborted, mark the overall outcome and
        // stop running subsequent phases (the controller's contract).
        if !matches!(phase_outcome, PhaseOutcome::Pass) {
            overall = OverallOutcome::Fail;
            // Mark remaining phases as Skipped so the manifest reflects
            // intent.
            for (j, p) in plan.phases.iter().enumerate().skip(idx + 1) {
                phase_outcomes.push(PhaseOutcomeEntry {
                    phase_index: j,
                    phase_name: p.name.clone(),
                    outcome: PhaseOutcome::Skipped {
                        reason: "earlier phase failed".into(),
                    },
                });
            }
            break;
        }
    }

    // Terminal Stop — submitted exactly once after all phases finish (or
    // we broke out early on failure). The per-phase schedulers no longer
    // emit Stop on Completed (they did, which tore drivers down between
    // phases). On manual abort / gate failure, the per-phase scheduler
    // already emitted Stop, so this is a redundant best-effort.
    {
        use arcane_swarm_orchestrator::protocol::OrchestratorCommand;
        let client =
            HttpOrchestratorClient::new(cfg.orchestrator_base_url.clone(), cfg.submitter.clone());
        let _ = client.submit(OrchestratorCommand::Stop).await;
    }

    // Signal the dashboard task to clear its screen and exit so the
    // binary's terminal summary line below isn't overwritten.
    {
        let mut s = dashboard_state.write().await;
        s.finished = true;
    }
    if let Some(h) = _dashboard {
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), h).await;
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

    let _total_duration = started_at.elapsed();

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
        scheduler_outcome: last_scheduler_outcome,
        phase_outcomes,
        overall,
        manifest_path,
    })
}

/// Compute the README headline numbers from the top passing tier's
/// per-driver latencies and aggregate metrics.
///
/// Formula for each number:
/// - `mean_latency_ms`:   mean of per-driver average latencies
/// - `median_latency_ms`: median of per-driver average latencies
/// - `min/max_latency_ms`: range of per-driver average latencies
/// - `total_round_trips`:  sum of (ok + err) across all drivers in the phase
/// - `error_rate_pct`:     sum(err) / sum(ok + err) × 100
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
    let median = if n.is_multiple_of(2) {
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

/// Optional SIGINT handler. Sets the abort flag on Ctrl+C so the scheduler
/// can shut down cleanly. Best-effort — if the runtime feature isn't
/// available, we silently skip.
fn install_sigint_handler(flag: Arc<AtomicBool>) {
    let f = flag.clone();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            f.store(true, Ordering::Relaxed);
        }
    });
}

/// Convenience: list `phase_*.json` + `manifest.json` filenames under `dir`,
/// sorted. Used by tests + post-run debug.
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
