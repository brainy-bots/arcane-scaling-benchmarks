//! Redis health monitor — polls `INFO` every 2 s and stores snapshots.
//!
//! Key failure signals:
//! - `instantaneous_output_kbps`: approaching NIC cap = saturation
//! - `connected_clients` drop during a phase = Redis disconnected a subscriber
//! - `evicted_clients` non-zero = output-buffer-limit exceeded

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::RwLock;

#[derive(Debug, Clone)]
pub struct RedisHealthSnapshot {
    pub connected_clients: u64,
    pub instantaneous_output_kbps: f64,
    pub instantaneous_input_kbps: f64,
    pub used_memory_bytes: u64,
    pub pubsub_channels: u64,
    pub evicted_clients: u64,
    pub total_connections_received: u64,
    pub sampled_at_unix_ms: u128,
}

impl Default for RedisHealthSnapshot {
    fn default() -> Self {
        Self {
            connected_clients: 0,
            instantaneous_output_kbps: 0.0,
            instantaneous_input_kbps: 0.0,
            used_memory_bytes: 0,
            pubsub_channels: 0,
            evicted_clients: 0,
            total_connections_received: 0,
            sampled_at_unix_ms: 0,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct RedisPhaseMetrics {
    pub peak_output_kbps: f64,
    pub peak_input_kbps: f64,
    pub min_connected_clients: u64,
    pub max_connected_clients: u64,
    pub evicted_clients_delta: u64,
    pub peak_memory_bytes: u64,
    pub snapshot_count: u64,
}

pub struct RedisMonitor {
    snapshots: Arc<RwLock<Vec<RedisHealthSnapshot>>>,
    phase_start_idx: Arc<RwLock<usize>>,
}

impl RedisMonitor {
    pub fn new() -> Self {
        Self {
            snapshots: Arc::new(RwLock::new(Vec::new())),
            phase_start_idx: Arc::new(RwLock::new(0)),
        }
    }

    pub fn spawn(&self, redis_url: String) -> tokio::task::JoinHandle<()> {
        let snapshots = self.snapshots.clone();
        tokio::spawn(async move {
            loop {
                match poll_redis_info(&redis_url).await {
                    Ok(snap) => {
                        snapshots.write().await.push(snap);
                    }
                    Err(e) => {
                        eprintln!("redis_monitor: poll failed: {}", e);
                    }
                }
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        })
    }

    pub async fn latest(&self) -> Option<RedisHealthSnapshot> {
        self.snapshots.read().await.last().cloned()
    }

    pub async fn reset_phase(&self) {
        let len = self.snapshots.read().await.len();
        *self.phase_start_idx.write().await = len;
    }

    pub async fn phase_metrics(&self) -> RedisPhaseMetrics {
        let snaps = self.snapshots.read().await;
        let start = *self.phase_start_idx.read().await;
        let phase_snaps = &snaps[start..];

        if phase_snaps.is_empty() {
            return RedisPhaseMetrics::default();
        }

        let mut peak_out = 0.0_f64;
        let mut peak_in = 0.0_f64;
        let mut min_clients = u64::MAX;
        let mut max_clients = 0u64;
        let mut peak_mem = 0u64;

        for s in phase_snaps {
            peak_out = peak_out.max(s.instantaneous_output_kbps);
            peak_in = peak_in.max(s.instantaneous_input_kbps);
            min_clients = min_clients.min(s.connected_clients);
            max_clients = max_clients.max(s.connected_clients);
            peak_mem = peak_mem.max(s.used_memory_bytes);
        }

        let evicted_delta = phase_snaps
            .last()
            .map(|l| l.evicted_clients)
            .unwrap_or(0)
            .saturating_sub(phase_snaps.first().map(|f| f.evicted_clients).unwrap_or(0));

        RedisPhaseMetrics {
            peak_output_kbps: peak_out,
            peak_input_kbps: peak_in,
            min_connected_clients: if min_clients == u64::MAX {
                0
            } else {
                min_clients
            },
            max_connected_clients: max_clients,
            evicted_clients_delta: evicted_delta,
            peak_memory_bytes: peak_mem,
            snapshot_count: phase_snaps.len() as u64,
        }
    }
}

async fn poll_redis_info(redis_url: &str) -> Result<RedisHealthSnapshot, String> {
    let client = redis::Client::open(redis_url).map_err(|e| e.to_string())?;
    let mut conn = client
        .get_multiplexed_async_connection()
        .await
        .map_err(|e| e.to_string())?;

    let info: String = redis::cmd("INFO")
        .arg("all")
        .query_async(&mut conn)
        .await
        .map_err(|e| e.to_string())?;

    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);

    Ok(RedisHealthSnapshot {
        connected_clients: parse_info_u64(&info, "connected_clients"),
        instantaneous_output_kbps: parse_info_f64(&info, "instantaneous_output_kbps"),
        instantaneous_input_kbps: parse_info_f64(&info, "instantaneous_input_kbps"),
        used_memory_bytes: parse_info_u64(&info, "used_memory"),
        pubsub_channels: parse_info_u64(&info, "pubsub_channels"),
        evicted_clients: parse_info_u64(&info, "evicted_clients"),
        total_connections_received: parse_info_u64(&info, "total_connections_received"),
        sampled_at_unix_ms: now_ms,
    })
}

fn parse_info_u64(info: &str, key: &str) -> u64 {
    for line in info.lines() {
        if let Some(val) = line.strip_prefix(key).and_then(|s| s.strip_prefix(':')) {
            return val.trim().parse().unwrap_or(0);
        }
    }
    0
}

fn parse_info_f64(info: &str, key: &str) -> f64 {
    for line in info.lines() {
        if let Some(val) = line.strip_prefix(key).and_then(|s| s.strip_prefix(':')) {
            return val.trim().parse().unwrap_or(0.0);
        }
    }
    0.0
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_INFO: &str = "\
# Clients\r
connected_clients:42\r
blocked_clients:0\r
\r
# Stats\r
instantaneous_input_kbps:1234.56\r
instantaneous_output_kbps:5678.90\r
total_connections_received:100\r
evicted_clients:3\r
\r
# Memory\r
used_memory:87654321\r
\r
# Keyspace\r
pubsub_channels:8\r
";

    #[test]
    fn parse_info_fields() {
        assert_eq!(parse_info_u64(SAMPLE_INFO, "connected_clients"), 42);
        assert!((parse_info_f64(SAMPLE_INFO, "instantaneous_output_kbps") - 5678.90).abs() < 0.01);
        assert!((parse_info_f64(SAMPLE_INFO, "instantaneous_input_kbps") - 1234.56).abs() < 0.01);
        assert_eq!(parse_info_u64(SAMPLE_INFO, "used_memory"), 87654321);
        assert_eq!(parse_info_u64(SAMPLE_INFO, "pubsub_channels"), 8);
        assert_eq!(parse_info_u64(SAMPLE_INFO, "evicted_clients"), 3);
        assert_eq!(
            parse_info_u64(SAMPLE_INFO, "total_connections_received"),
            100
        );
    }

    #[test]
    fn parse_info_missing_key() {
        assert_eq!(parse_info_u64(SAMPLE_INFO, "nonexistent_key"), 0);
        assert!((parse_info_f64(SAMPLE_INFO, "nonexistent_key") - 0.0).abs() < 0.001);
    }

    #[tokio::test]
    async fn phase_metrics_empty() {
        let mon = RedisMonitor::new();
        let m = mon.phase_metrics().await;
        assert_eq!(m.snapshot_count, 0);
        assert_eq!(m.min_connected_clients, 0);
    }
}
