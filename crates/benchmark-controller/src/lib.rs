//! Benchmark controller — owns phase logic, ramp schedule, validity gates,
//! and per-phase results. Drives the swarm orchestrator over WebSocket;
//! subscribes to its telemetry SSE for stats and gate evaluation.
//!
//! See `EPIC #75` in `arcane-scaling-benchmarks` for the full architecture.
//! Test scaffolds for each component land here; implementations land in
//! follow-up PRs.

pub mod dashboard;
pub mod gate;
pub mod orchestrator_client;
pub mod phase_metrics;
pub mod plan;
pub mod redis_monitor;
pub mod results;
pub mod run;
pub mod scheduler;
pub mod sse_consumer;

#[cfg(test)]
mod tests {
    mod gate;
    mod phase_metrics;
    mod plan;
    mod results;
    mod scheduler;
}
