//! Benchmark simulation — implements ClusterSimulation with kinematic physics.
//!
//! ## Fairness contract
//!
//! The physics constants and operations here MUST match the SpacetimeDB-only module's
//! `physics_tick` reducer exactly. If you change a value here, change it in
//! `crates/benchmark-spacetimedb-full/src/lib.rs` too.
//!
//! The collision detection algorithm is identical: O(n^2) pairwise distance check.
//! This is intentionally expensive — it's the work that Arcane distributes across clusters.

use std::collections::HashMap;

use arcane_core::cluster_simulation::{ClusterSimulation, ClusterTickContext};
use uuid::Uuid;

// ── Physics constants (MUST match benchmark-spacetimedb-full) ───────��───────
pub const WORLD_SIZE: f64 = 5000.0;
pub const PHYSICS_SPEED: f64 = 600.0;
pub const PHYSICS_DT: f64 = 0.05; // 20 Hz
pub const WORLD_MIN: f64 = 200.0;
pub const WORLD_MAX: f64 = WORLD_SIZE - 200.0;
pub const COLLISION_RADIUS: f64 = 50.0;
pub const COLLISION_DAMAGE: u32 = 10;
pub const BUFF_SPEED_MULTIPLIER: f64 = 2.0;
pub const BUFF_DURATION_TICKS: u64 = 200; // 10 seconds at 20 Hz

/// Per-entity buff state tracked by the cluster (not persisted — ephemeral).
struct BuffState {
    speed_multiplier: f64,
    expires_at_tick: u64,
}

/// Benchmark simulation implementing kinematic physics, collision detection,
/// buff application, and SpacetimeDB integration for game actions.
pub struct BenchmarkSimulation {
    /// SpacetimeDB HTTP endpoint for reducer calls (e.g. apply_damage, use_item).
    spacetimedb_url: String,
    /// SpacetimeDB database name.
    database: String,
    /// HTTP client for SpacetimeDB calls.
    client: reqwest::blocking::Client,
    /// Active buffs per entity (cluster-local, ephemeral).
    buffs: std::sync::Mutex<HashMap<Uuid, BuffState>>,
}

impl BenchmarkSimulation {
    pub fn new(spacetimedb_url: String, database: String) -> Self {
        Self {
            spacetimedb_url,
            database,
            client: reqwest::blocking::Client::builder()
                .timeout(std::time::Duration::from_secs(5))
                .build()
                .expect("reqwest client"),
            buffs: std::sync::Mutex::new(HashMap::new()),
        }
    }

    fn reducer_url(&self, reducer: &str) -> String {
        format!(
            "{}/v1/database/{}/call/{}",
            self.spacetimedb_url, self.database, reducer
        )
    }

    fn call_apply_damage(&self, target_id: Uuid, amount: u32) {
        let body = format!(
            "[[{{\"__uuid__\":{}}},{}]",
            target_id.as_u128(),
            amount
        );
        let _ = self
            .client
            .post(&self.reducer_url("apply_damage"))
            .header("Content-Type", "application/json")
            .body(body)
            .send();
    }

    fn call_use_item(&self, owner_id: Uuid, item_type: u32) -> bool {
        let body = format!(
            "[[{{\"__uuid__\":{}}},{}]",
            owner_id.as_u128(),
            item_type
        );
        self.client
            .post(&self.reducer_url("use_item"))
            .header("Content-Type", "application/json")
            .body(body)
            .send()
            .map(|r| r.status().is_success())
            .unwrap_or(false)
    }

    fn call_pickup_item(&self, owner_id: Uuid, item_type: u32, quantity: u32) {
        let body = format!(
            "[[{{\"__uuid__\":{}}},{},{}]",
            owner_id.as_u128(),
            item_type,
            quantity
        );
        let _ = self
            .client
            .post(&self.reducer_url("pickup_item"))
            .header("Content-Type", "application/json")
            .body(body)
            .send();
    }

    fn call_player_interact(&self, actor_id: Uuid, target_id: Uuid, event_type: u32) {
        let body = format!(
            "[[{{\"__uuid__\":{}}},{{\"__uuid__\":{}}},{}]",
            actor_id.as_u128(),
            target_id.as_u128(),
            event_type
        );
        let _ = self
            .client
            .post(&self.reducer_url("player_interact"))
            .header("Content-Type", "application/json")
            .body(body)
            .send();
    }
}

impl ClusterSimulation for BenchmarkSimulation {
    fn on_tick(&self, ctx: &mut ClusterTickContext<'_>) {
        let tick = ctx.tick;
        let mut buffs = self.buffs.lock().expect("buffs lock");

        // Expire old buffs
        buffs.retain(|_, b| b.expires_at_tick > tick);

        // Process game actions from clients
        for action in ctx.game_actions {
            match action.action_type.as_str() {
                "use_item" => {
                    let item_type = action
                        .payload
                        .get("item_type")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0) as u32;
                    // Call SpacetimeDB to validate and consume
                    if self.call_use_item(action.entity_id, item_type) {
                        // Item 0 = speed potion: apply buff locally
                        if item_type == 0 {
                            buffs.insert(
                                action.entity_id,
                                BuffState {
                                    speed_multiplier: BUFF_SPEED_MULTIPLIER,
                                    expires_at_tick: tick + BUFF_DURATION_TICKS,
                                },
                            );
                        }
                    }
                }
                "pickup_item" => {
                    let item_type = action
                        .payload
                        .get("item_type")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0) as u32;
                    let quantity = action
                        .payload
                        .get("quantity")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(1) as u32;
                    self.call_pickup_item(action.entity_id, item_type, quantity);
                }
                "interact" => {
                    let target_id = action
                        .payload
                        .get("target_id")
                        .and_then(|v| v.as_str())
                        .and_then(|s| Uuid::parse_str(s).ok())
                        .unwrap_or(Uuid::nil());
                    let event_type = action
                        .payload
                        .get("event_type")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0) as u32;
                    self.call_player_interact(action.entity_id, target_id, event_type);
                }
                _ => {} // unknown action type — ignore
            }
        }

        // Physics: move entities based on velocity (client sends direction as velocity)
        let step = PHYSICS_SPEED * PHYSICS_DT;
        for entity in ctx.entities.values_mut() {
            let speed_mult = buffs
                .get(&entity.entity_id)
                .map(|b| b.speed_multiplier)
                .unwrap_or(1.0);

            // Velocity from client is direction (normalized-ish); apply speed
            let vx = entity.velocity.x;
            let vz = entity.velocity.z;
            let effective_step = step * speed_mult;
            entity.position.x = (entity.position.x + vx * effective_step).clamp(WORLD_MIN, WORLD_MAX);
            entity.position.z = (entity.position.z + vz * effective_step).clamp(WORLD_MIN, WORLD_MAX);
        }

        // Collision detection — O(n^2), same as SpacetimeDB-only mode
        let entities: Vec<(Uuid, f64, f64)> = ctx
            .entities
            .values()
            .map(|e| (e.entity_id, e.position.x, e.position.z))
            .collect();
        let radius_sq = COLLISION_RADIUS * COLLISION_RADIUS;
        for i in 0..entities.len() {
            for j in (i + 1)..entities.len() {
                let dx = entities[i].1 - entities[j].1;
                let dz = entities[i].2 - entities[j].2;
                if dx * dx + dz * dz < radius_sq {
                    // Call SpacetimeDB to apply damage authoritatively
                    self.call_apply_damage(entities[i].0, COLLISION_DAMAGE);
                    self.call_apply_damage(entities[j].0, COLLISION_DAMAGE);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use arcane_core::replication_channel::EntityStateEntry;
    use arcane_core::Vec3;

    fn mk_entity(id: u128, x: f64, z: f64, vx: f64, vz: f64) -> EntityStateEntry {
        EntityStateEntry::new(
            Uuid::from_u128(id),
            Uuid::nil(),
            Vec3::new(x, 0.0, z),
            Vec3::new(vx, 0.0, vz),
        )
    }

    #[test]
    fn physics_moves_entity_by_velocity_times_speed_times_dt() {
        let mut entities = HashMap::new();
        entities.insert(Uuid::from_u128(1), mk_entity(1, 2500.0, 2500.0, 1.0, 0.0));

        let step = PHYSICS_SPEED * PHYSICS_DT; // 600 * 0.05 = 30
        for entity in entities.values_mut() {
            entity.position.x = (entity.position.x + entity.velocity.x * step).clamp(WORLD_MIN, WORLD_MAX);
            entity.position.z = (entity.position.z + entity.velocity.z * step).clamp(WORLD_MIN, WORLD_MAX);
        }

        let ent = entities.get(&Uuid::from_u128(1)).unwrap();
        assert!((ent.position.x - 2530.0).abs() < 0.001, "x should be 2500 + 1.0*30 = 2530");
        assert!((ent.position.z - 2500.0).abs() < 0.001, "z unchanged");
    }

    #[test]
    fn physics_clamps_to_world_bounds() {
        let mut entities = HashMap::new();
        entities.insert(Uuid::from_u128(1), mk_entity(1, WORLD_MAX - 10.0, 2500.0, 1.0, 0.0));

        let step = PHYSICS_SPEED * PHYSICS_DT; // 30
        for entity in entities.values_mut() {
            entity.position.x = (entity.position.x + entity.velocity.x * step).clamp(WORLD_MIN, WORLD_MAX);
        }

        let ent = entities.get(&Uuid::from_u128(1)).unwrap();
        assert_eq!(ent.position.x, WORLD_MAX, "should clamp to WORLD_MAX");
    }

    #[test]
    fn collision_detection_finds_nearby_entities() {
        let entities: Vec<(Uuid, f64, f64)> = vec![
            (Uuid::from_u128(1), 100.0, 100.0),
            (Uuid::from_u128(2), 130.0, 100.0), // 30 units away — within COLLISION_RADIUS (50)
            (Uuid::from_u128(3), 500.0, 500.0), // far away
        ];
        let radius_sq = COLLISION_RADIUS * COLLISION_RADIUS;
        let mut collisions = Vec::new();
        for i in 0..entities.len() {
            for j in (i + 1)..entities.len() {
                let dx = entities[i].1 - entities[j].1;
                let dz = entities[i].2 - entities[j].2;
                if dx * dx + dz * dz < radius_sq {
                    collisions.push((entities[i].0, entities[j].0));
                }
            }
        }
        assert_eq!(collisions.len(), 1);
        assert_eq!(collisions[0].0, Uuid::from_u128(1));
        assert_eq!(collisions[0].1, Uuid::from_u128(2));
    }
}
