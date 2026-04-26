//! Benchmark cluster binary — Arcane cluster server with BenchmarkSimulation.
//!
//! This is the cluster binary for the Arcane + SpacetimeDB benchmark mode.
//! It runs `run_cluster_loop` with a `BenchmarkSimulation` that performs the same
//! kinematic physics as SpacetimeDB's `physics_tick` reducer, plus collision detection
//! and buff application.
//!
//! Env:
//!   CLUSTER_ID            — required; UUID of this cluster.
//!   REDIS_URL             — optional; default `redis://127.0.0.1:6379`.
//!   NEIGHBOR_IDS          — optional; comma-separated UUIDs of neighbor clusters.
//!   CLUSTER_WS_PORT       — optional; default 8080.
//!
//! Persistence (read by `arcane_infra::spacetimedb_persist`; set by Run-Benchmark.ps1 or Docker):
//!   SPACETIMEDB_URI          — SpacetimeDB HTTP endpoint (default `http://127.0.0.1:3000`).
//!   SPACETIMEDB_DATABASE     — SpacetimeDB database name (default `arcane`).
//!   SPACETIMEDB_PERSIST      — "1" or "true" to enable (default: disabled).
//!   SPACETIMEDB_PERSIST_HZ   — persist frequency (default: 1).
//!   SPACETIMEDB_PERSIST_BATCH_SIZE — entities per HTTP request (default: 0 = unlimited).
//!
//! The simulation itself does not talk to SpacetimeDB. Per-entity game state (HP,
//! inventory, buffs) lives in cluster-local memory and rides on `entity.user_data`
//! through the Arcane L1 auto-persist path.

mod simulation;

use std::env;
use std::sync::Arc;

use arcane_infra::cluster_runner;
use uuid::Uuid;

use simulation::BenchmarkSimulation;

fn parse_uuids(s: &str) -> Vec<Uuid> {
    s.split(',')
        .map(|x| x.trim())
        .filter(|x| !x.is_empty())
        .filter_map(|x| Uuid::parse_str(x).ok())
        .collect()
}

fn main() -> Result<(), String> {
    let cluster_id =
        env::var("CLUSTER_ID").map_err(|_| "CLUSTER_ID env var required (UUID)".to_string())?;
    let cluster_id =
        Uuid::parse_str(&cluster_id).map_err(|e| format!("invalid CLUSTER_ID: {}", e))?;

    let redis_url = env::var("REDIS_URL").unwrap_or_else(|_| "redis://127.0.0.1:6379".to_string());
    let neighbor_ids = env::var("NEIGHBOR_IDS")
        .map(|s| parse_uuids(&s))
        .unwrap_or_default();
    let ws_port: u16 = env::var("CLUSTER_WS_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8080);

    let sim = BenchmarkSimulation::new();

    // Buff duration is reported as wall-clock seconds (the user-visible thing),
    // since the per-tick count varies with the cluster's tick rate.
    eprintln!(
        "benchmark-cluster: physics=kinematic collision_radius={} buff_duration={}s",
        simulation::COLLISION_RADIUS,
        simulation::BUFF_DURATION_SECONDS,
    );

    cluster_runner::run_cluster_loop(
        cluster_id,
        redis_url,
        neighbor_ids,
        ws_port,
        |_| vec![], // no injected demo entities — real players from swarm
        Some(Arc::new(sim)),
    )
}
