//! ASCII dashboard for `benchmark-controller`.
//!
//! Subscribes to the SSE-fed `TelemetrySnapshot` broadcast and renders a
//! plain ANSI screen to stdout every time a snapshot arrives (or every 2 s
//! if the stream stalls). No external TUI dependency — keeps the binary
//! small and avoids alt-screen weirdness when run inside `docker run -it`
//! against an SSM tunnel.
//!
//! The renderer assumes a vt100-compatible terminal. When stdout is not a
//! TTY (CI, file redirection), the run loop should not spawn this task —
//! see `run::should_enable_dashboard`.
//!
//! Layout (one screen, redraws in place):
//!
//! ```text
//! ARCANE BENCHMARK CONTROLLER · headline-13500
//! ─────────────────────────────────────────────
//! Phase 3/10  tier-4500-aggregate   target=4500
//! Hold 12s / 30s   Gate: PASS   Elapsed 1:42
//!
//! CLUSTERS (4)
//!   32f2a101  entities=1125  tick=5.0ms
//!   …
//!   TOTAL    entities=4500 / 4500    worst tick=5.2ms / 16.7ms budget
//!
//! DRIVERS  active=12  stale=0
//!
//! RECENT COMMANDS (newest first)
//!   seq=6  set_players(4500)        acked 12/12  age 11s
//!   …
//! ```
//!
//! On overall completion the dashboard task is dropped; the binary's main
//! prints the final outcome line as before so output is greppable for
//! "overall = Pass".

use crate::plan::TestPlan;
use arcane_swarm_orchestrator::protocol::OrchestratorCommand;
use arcane_swarm_orchestrator::telemetry::TelemetrySnapshot;
use std::io::Write;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, RwLock};

/// Cross-task state the run loop updates as phases progress, so the
/// dashboard can render without inspecting the scheduler internals.
pub struct DashboardState {
    pub plan: TestPlan,
    /// Index into `plan.phases` of the currently-running phase.
    pub current_phase_index: usize,
    /// When the current phase started. Used for the hold-progress bar.
    pub phase_started_at: Instant,
    /// When the run as a whole started. Used for the "elapsed" line.
    pub overall_started_at: Instant,
    /// Most recent gate evaluation, lower-cased ("pass" / "fail" / etc).
    pub gate_state: String,
    /// Set true once the run loop is finished — the dashboard task stops
    /// re-rendering and exits cleanly. Without this it would keep redrawing
    /// over the binary's terminal summary line.
    pub finished: bool,
}

impl DashboardState {
    pub fn new(plan: TestPlan) -> Self {
        let now = Instant::now();
        Self {
            plan,
            current_phase_index: 0,
            phase_started_at: now,
            overall_started_at: now,
            gate_state: "pending".to_string(),
            finished: false,
        }
    }
}

/// Spawn the dashboard renderer task. Pulls the latest snapshot from the
/// broadcast `snap_rx` and the live phase state from `state`.
pub fn spawn_dashboard(
    state: Arc<RwLock<DashboardState>>,
    mut snap_rx: broadcast::Receiver<TelemetrySnapshot>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut latest: Option<TelemetrySnapshot> = None;
        // Refresh on snapshot arrival OR every 2s so the elapsed/hold lines
        // tick visibly even when SSE is quiet between snapshots.
        loop {
            tokio::select! {
                res = snap_rx.recv() => {
                    match res {
                        Ok(s) => latest = Some(s),
                        Err(broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
                _ = tokio::time::sleep(Duration::from_secs(2)) => {}
            }
            let s = state.read().await;
            if s.finished {
                // Move cursor below the dashboard so the binary's terminal
                // summary line lands on its own row instead of overwriting
                // the last redraw.
                let mut out = std::io::stdout().lock();
                let _ = write!(out, "\x1b[2J\x1b[H");
                let _ = out.flush();
                break;
            }
            let _ = render(&s, latest.as_ref());
        }
    })
}

fn render(state: &DashboardState, snap: Option<&TelemetrySnapshot>) -> std::io::Result<()> {
    let mut out = std::io::stdout().lock();
    // Clear screen + home cursor. We re-render the whole screen each tick
    // rather than diffing — at 0.5 Hz that's irrelevant for performance and
    // avoids any ratatui-style alt-screen state to manage.
    write!(out, "\x1b[2J\x1b[H")?;

    let total_phases = state.plan.phases.len();
    let phase = state
        .plan
        .phases
        .get(state.current_phase_index)
        .or_else(|| state.plan.phases.last());
    let phase_name = phase.map(|p| p.name.as_str()).unwrap_or("(none)");
    let target = phase.map(|p| p.target_players).unwrap_or(0);
    let hold_total = phase.map(|p| p.hold_seconds).unwrap_or(0);
    let phase_elapsed = state.phase_started_at.elapsed().as_secs();
    let overall_elapsed = state.overall_started_at.elapsed().as_secs();

    writeln!(
        out,
        "\x1b[1mARCANE BENCHMARK CONTROLLER\x1b[0m  ·  {}",
        state.plan.plan.name
    )?;
    writeln!(out, "{}", "─".repeat(72))?;
    writeln!(
        out,
        "Phase {}/{}  \x1b[1m{}\x1b[0m   target={}",
        state.current_phase_index + 1,
        total_phases,
        phase_name,
        target
    )?;
    let gate_color = match state.gate_state.as_str() {
        "fail" => "\x1b[31m",
        "pass" => "\x1b[32m",
        _ => "\x1b[33m",
    };
    writeln!(
        out,
        "Hold {}s / {}s   Gate: {}{}\x1b[0m   Elapsed {}:{:02}",
        phase_elapsed,
        hold_total,
        gate_color,
        state.gate_state.to_uppercase(),
        overall_elapsed / 60,
        overall_elapsed % 60
    )?;
    writeln!(out)?;

    if let Some(snap) = snap {
        // ── clusters ────────────────────────────────────────────────────
        writeln!(out, "\x1b[1mCLUSTERS\x1b[0m ({})", snap.clusters.len())?;
        let mut clusters: Vec<_> = snap.clusters.iter().collect();
        clusters.sort_by(|a, b| a.0.cmp(b.0));
        let mut total_ent: u64 = 0;
        let mut worst_tick_us: u64 = 0;
        for (id, c) in &clusters {
            writeln!(
                out,
                "  {:<24}  entities={:>5}  tick={:>5.2}ms",
                short_cluster_id(id),
                c.entities_current,
                c.last_tick_us as f64 / 1000.0
            )?;
            total_ent += c.entities_current;
            worst_tick_us = worst_tick_us.max(c.last_tick_us);
        }
        if target > 0 {
            let pct = (total_ent as f64 / target as f64 * 100.0).min(100.0);
            writeln!(
                out,
                "  {:<24}  entities={:>5} / {:<5}  ({:>3.0}%)   worst tick={:.2}ms / 16.67ms budget",
                "TOTAL", total_ent, target, pct,
                worst_tick_us as f64 / 1000.0
            )?;
        } else {
            // Cooldown / drain — there's no positive target to compute %
            // against; just show actual + worst tick.
            writeln!(
                out,
                "  {:<24}  entities={:>5}            (drain)   worst tick={:.2}ms / 16.67ms budget",
                "TOTAL", total_ent,
                worst_tick_us as f64 / 1000.0
            )?;
        }
        writeln!(out)?;

        // ── drivers ─────────────────────────────────────────────────────
        let active = snap.fleet.iter().filter(|d| d.state == "Active").count();
        let stale = snap.fleet.iter().filter(|d| d.state == "Stale").count();
        let other = snap.fleet.len() - active - stale;
        writeln!(
            out,
            "\x1b[1mDRIVERS\x1b[0m  active={}  stale={}  other={}  (fleet={})",
            active,
            stale,
            other,
            snap.fleet.len()
        )?;
        writeln!(out)?;

        // ── commands ────────────────────────────────────────────────────
        writeln!(out, "\x1b[1mRECENT COMMANDS\x1b[0m (newest first)")?;
        let cmds_iter = snap.recent_commands.iter().take(6);
        for c in cmds_iter {
            let kind = format_command(&c.command);
            let acked = c.acked_drivers.len();
            let missing = c.missing_drivers.len();
            let missing_color = if missing > 0 { "\x1b[31m" } else { "" };
            let missing_reset = if missing > 0 { "\x1b[0m" } else { "" };
            writeln!(
                out,
                "  seq={:<4} {:<32} acked {:>2}/{:<2}  {}missing {}{}  age {}s",
                c.seq,
                kind,
                acked,
                acked + missing,
                missing_color,
                missing,
                missing_reset,
                c.age_ms / 1000
            )?;
        }
    } else {
        writeln!(out, "(waiting for first telemetry snapshot…)")?;
    }
    out.flush()?;
    Ok(())
}

/// Strip the orchestrator's verbose stats-URL key down to a useful
/// operator-facing label. Keys today look like
/// `http://10.0.0.84:8091/stats`; we want `10.0.0.84:8091`. Falls back
/// to a 24-char prefix if the key doesn't follow the URL shape (so
/// future cluster-id schemes still render something sensible).
fn short_cluster_id(id: &str) -> String {
    let trimmed = id.trim_start_matches("http://").trim_start_matches("https://");
    let host_port = trimmed.split('/').next().unwrap_or(trimmed);
    if host_port.len() > 24 {
        host_port[..24].to_string()
    } else {
        host_port.to_string()
    }
}

fn format_command(cmd: &OrchestratorCommand) -> String {
    match cmd {
        OrchestratorCommand::SetPlayers(c) => format!("set_players({})", c.player_count),
        OrchestratorCommand::SetSpawnDelayMs(c) => format!("set_spawn_delay_ms({})", c.spawn_delay_ms),
        OrchestratorCommand::Stop => "stop".to_string(),
    }
}
