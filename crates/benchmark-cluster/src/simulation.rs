//! Benchmark simulation — implements `ClusterSimulation` with kinematic physics.
//!
//! ## Progressive-API level-1 persistence
//!
//! Per-entity game state (HP, inventory, active buff, interaction counter) lives in
//! cluster-local memory and rides along with the Arcane L1 auto-persist path — the cluster
//! mutates each entity's `user_data` JSON at the end of every tick and the throttled
//! `set_entities` snapshot flushes it into SpacetimeDB at 1 Hz. No per-action reducer calls,
//! no HTTP client, no blocking the tick loop on SpacetimeDB round-trips.
//!
//! Before this module climbed to L1, every damage/use/pickup/interact event fired a blocking
//! `reqwest::blocking` POST inside `on_tick`, stalling the tick loop and producing silently
//! invalid benchmark numbers (entities=0 observed server-side under load).
//!
//! ## Fairness contract
//!
//! The physics constants and operations here MUST match the SpacetimeDB-only module's
//! `physics_tick` reducer exactly. If you change a value here, change it in
//! `crates/benchmark-spacetimedb-full/src/lib.rs` too. The collision detection algorithm is
//! identical: O(n²) pairwise distance check. This is intentionally expensive — it's the work
//! that Arcane distributes across clusters.

use std::collections::HashMap;
use std::sync::Mutex;

use arcane_core::cluster_simulation::{ClusterSimulation, ClusterTickContext};
use uuid::Uuid;

// ── Physics constants (MUST match benchmark-spacetimedb-full) ────────────────
pub const WORLD_SIZE: f64 = 5000.0;
#[allow(dead_code)] // Documented for equivalence with SpacetimeDB physics_tick
pub const PHYSICS_SPEED: f64 = 600.0;
#[allow(dead_code)] // Documented for equivalence with SpacetimeDB physics_tick
pub const PHYSICS_DT: f64 = 0.05; // 20 Hz
pub const WORLD_MIN: f64 = 200.0;
pub const WORLD_MAX: f64 = WORLD_SIZE - 200.0;
pub const COLLISION_RADIUS: f64 = 50.0;
pub const COLLISION_DAMAGE: u32 = 10;
pub const BUFF_SPEED_MULTIPLIER: f64 = 2.0;
/// Buff lasts the same wall-clock duration regardless of cluster tick rate.
/// Previously hardcoded as `BUFF_DURATION_TICKS = 200` (10s at 20 Hz). Now
/// derived from `ctx.dt_seconds` per tick so a 30 Hz cluster runs the buff
/// for 300 ticks and a 60 Hz cluster for 600 ticks — same 10 s on a clock.
pub const BUFF_DURATION_SECONDS: f64 = 10.0;
pub const INITIAL_HP: u32 = 100;
const SPEED_POTION_ITEM: u32 = 0;

/// How many ticks a 10-second speed buff covers at the current tick rate.
/// `dt_seconds` is the cluster's per-tick interval; at 20 Hz this returns
/// 200, at 30 Hz it returns 300.
pub fn buff_duration_ticks(dt_seconds: f64) -> u64 {
    (BUFF_DURATION_SECONDS / dt_seconds).round() as u64
}

#[derive(Default, Clone)]
struct BuffState {
    speed_multiplier: f64,
    expires_at_tick: u64,
}

/// Per-entity game state held cluster-local. Snapshotted into `entity.user_data` at the end
/// of every tick so the L1 auto-persist path (1 Hz `set_entities`) carries it to SpacetimeDB.
#[derive(Default, Clone)]
struct GameState {
    hp: u32,
    /// item_type → quantity.
    inventory: HashMap<u32, u32>,
    buff: Option<BuffState>,
    /// Lifetime count of `interact` actions originated by this entity. Cheap to carry; gives
    /// the benchmark a non-trivial per-entity field that changes over time.
    interaction_count: u32,
}

impl GameState {
    fn fresh() -> Self {
        Self {
            hp: INITIAL_HP,
            ..Self::default()
        }
    }

    fn to_user_data(&self, tick: u64) -> serde_json::Value {
        let inv: serde_json::Map<String, serde_json::Value> = self
            .inventory
            .iter()
            .map(|(k, v)| (k.to_string(), serde_json::Value::from(*v)))
            .collect();
        let buff = self
            .buff
            .as_ref()
            .filter(|b| b.expires_at_tick > tick)
            .map(|b| {
                serde_json::json!({
                    "mult": b.speed_multiplier,
                    "expires": b.expires_at_tick,
                })
            });
        serde_json::json!({
            "hp": self.hp,
            "inv": serde_json::Value::Object(inv),
            "buff": buff,
            "events": self.interaction_count,
        })
    }
}

pub struct BenchmarkSimulation {
    /// Per-entity game state (cluster-local authoritative copy).
    state: Mutex<HashMap<Uuid, GameState>>,
}

impl Default for BenchmarkSimulation {
    fn default() -> Self {
        Self::new()
    }
}

impl BenchmarkSimulation {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(HashMap::new()),
        }
    }
}

impl ClusterSimulation for BenchmarkSimulation {
    fn on_tick(&self, ctx: &mut ClusterTickContext<'_>) {
        let tick = ctx.tick;
        let mut state = self.state.lock().expect("game state lock");

        // Ensure every live entity has a state row; drop rows for entities no longer present.
        state.retain(|id, _| ctx.entities.contains_key(id));
        for id in ctx.entities.keys() {
            state.entry(*id).or_insert_with(GameState::fresh);
        }

        // Process game actions from clients (mutate local state; no HTTP).
        for action in ctx.game_actions {
            let Some(gs) = state.get_mut(&action.entity_id) else {
                continue;
            };
            match action.action_type.as_str() {
                "use_item" => {
                    let item_type = action
                        .payload
                        .get("item_type")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0) as u32;
                    let consumed = match gs.inventory.get_mut(&item_type) {
                        Some(q) if *q > 0 => {
                            *q -= 1;
                            if *q == 0 {
                                gs.inventory.remove(&item_type);
                            }
                            true
                        }
                        _ => false,
                    };
                    if consumed && item_type == SPEED_POTION_ITEM {
                        gs.buff = Some(BuffState {
                            speed_multiplier: BUFF_SPEED_MULTIPLIER,
                            expires_at_tick: tick + buff_duration_ticks(ctx.dt_seconds),
                        });
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
                    *gs.inventory.entry(item_type).or_insert(0) += quantity;
                }
                "interact" => {
                    gs.interaction_count = gs.interaction_count.saturating_add(1);
                }
                _ => {}
            }
        }

        // Physics: the swarm sends velocity as pre-computed per-tick displacement
        // (dir * PHYSICS_SPEED * PHYSICS_DT), so we add it directly. Speed multiplier
        // from any active buff applies on top.
        for entity in ctx.entities.values_mut() {
            let speed_mult = state
                .get(&entity.entity_id)
                .and_then(|gs| gs.buff.as_ref())
                .filter(|b| b.expires_at_tick > tick)
                .map(|b| b.speed_multiplier)
                .unwrap_or(1.0);

            entity.position.x =
                (entity.position.x + entity.velocity.x * speed_mult).clamp(WORLD_MIN, WORLD_MAX);
            entity.position.z =
                (entity.position.z + entity.velocity.z * speed_mult).clamp(WORLD_MIN, WORLD_MAX);
        }

        // Collision detection — O(n²), same as SpacetimeDB-only mode. Damage goes to local
        // state; the 1 Hz L1 snapshot carries the resulting HP values into SpacetimeDB.
        let ids_pos: Vec<(Uuid, f64, f64)> = ctx
            .entities
            .values()
            .map(|e| (e.entity_id, e.position.x, e.position.z))
            .collect();
        let radius_sq = COLLISION_RADIUS * COLLISION_RADIUS;
        for i in 0..ids_pos.len() {
            for j in (i + 1)..ids_pos.len() {
                let dx = ids_pos[i].1 - ids_pos[j].1;
                let dz = ids_pos[i].2 - ids_pos[j].2;
                if dx * dx + dz * dz < radius_sq {
                    if let Some(gs) = state.get_mut(&ids_pos[i].0) {
                        gs.hp = gs.hp.saturating_sub(COLLISION_DAMAGE);
                    }
                    if let Some(gs) = state.get_mut(&ids_pos[j].0) {
                        gs.hp = gs.hp.saturating_sub(COLLISION_DAMAGE);
                    }
                }
            }
        }

        // Sync local state into entity.user_data so the L1 auto-persist snapshot carries it.
        for (id, entity) in ctx.entities.iter_mut() {
            if let Some(gs) = state.get(id) {
                entity.user_data = gs.to_user_data(tick);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use arcane_core::cluster_simulation::GameAction;
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

    fn run_tick(
        sim: &BenchmarkSimulation,
        tick: u64,
        entities: &mut HashMap<Uuid, EntityStateEntry>,
        actions: &[GameAction],
    ) {
        let mut pending_removals: Vec<Uuid> = Vec::new();
        let mut ctx = ClusterTickContext {
            cluster_id: Uuid::nil(),
            tick,
            dt_seconds: 0.05,
            entities,
            pending_removals: &mut pending_removals,
            game_actions: actions,
        };
        sim.on_tick(&mut ctx);
    }

    #[test]
    fn physics_adds_velocity_directly_with_clamp() {
        // Swarm sends velocity as displacement (dir * PHYSICS_SPEED * PHYSICS_DT = 30 for dir=1).
        let sim = BenchmarkSimulation::new();
        let mut entities = HashMap::new();
        entities.insert(Uuid::from_u128(1), mk_entity(1, 2500.0, 2500.0, 30.0, 0.0));

        run_tick(&sim, 1, &mut entities, &[]);

        let ent = entities.get(&Uuid::from_u128(1)).unwrap();
        assert!((ent.position.x - 2530.0).abs() < 0.001);
        assert!((ent.position.z - 2500.0).abs() < 0.001);
    }

    #[test]
    fn physics_clamps_to_world_bounds() {
        let sim = BenchmarkSimulation::new();
        let mut entities = HashMap::new();
        entities.insert(
            Uuid::from_u128(1),
            mk_entity(1, WORLD_MAX - 10.0, 2500.0, 30.0, 0.0),
        );
        run_tick(&sim, 1, &mut entities, &[]);
        let ent = entities.get(&Uuid::from_u128(1)).unwrap();
        assert_eq!(ent.position.x, WORLD_MAX);
    }

    #[test]
    fn collision_drops_hp_locally_without_network() {
        let sim = BenchmarkSimulation::new();
        let mut entities = HashMap::new();
        // Two entities 30 units apart — inside COLLISION_RADIUS (50).
        entities.insert(Uuid::from_u128(1), mk_entity(1, 100.0, 100.0, 0.0, 0.0));
        entities.insert(Uuid::from_u128(2), mk_entity(2, 130.0, 100.0, 0.0, 0.0));

        run_tick(&sim, 1, &mut entities, &[]);

        let e1 = entities.get(&Uuid::from_u128(1)).unwrap();
        let ud = &e1.user_data;
        assert_eq!(
            ud["hp"].as_u64().unwrap(),
            (INITIAL_HP - COLLISION_DAMAGE) as u64
        );
    }

    #[test]
    fn pickup_then_use_grants_buff_and_speeds_movement() {
        let sim = BenchmarkSimulation::new();
        let id = Uuid::from_u128(1);
        let mut entities = HashMap::new();
        entities.insert(id, mk_entity(1, 1000.0, 1000.0, 10.0, 0.0));

        let pickup = GameAction {
            entity_id: id,
            action_type: "pickup_item".into(),
            payload: serde_json::json!({ "item_type": 0, "quantity": 1 }),
        };
        let use_it = GameAction {
            entity_id: id,
            action_type: "use_item".into(),
            payload: serde_json::json!({ "item_type": 0 }),
        };

        // Tick 1: pickup item. No buff yet, velocity multiplier 1.0.
        run_tick(&sim, 1, &mut entities, &[pickup]);
        assert_eq!(entities.get(&id).unwrap().position.x, 1010.0);

        // Tick 2: use item — buff takes effect *this same tick* (applied before physics).
        // Position advances by 10 * 2.0 = 20.
        run_tick(&sim, 2, &mut entities, &[use_it]);
        assert_eq!(entities.get(&id).unwrap().position.x, 1030.0);
    }

    #[test]
    fn user_data_sync_carries_inventory_and_events() {
        let sim = BenchmarkSimulation::new();
        let id = Uuid::from_u128(1);
        let mut entities = HashMap::new();
        entities.insert(id, mk_entity(1, 2500.0, 2500.0, 0.0, 0.0));

        let actions = vec![
            GameAction {
                entity_id: id,
                action_type: "pickup_item".into(),
                payload: serde_json::json!({ "item_type": 5, "quantity": 3 }),
            },
            GameAction {
                entity_id: id,
                action_type: "interact".into(),
                payload: serde_json::json!({}),
            },
        ];
        run_tick(&sim, 1, &mut entities, &actions);

        let ud = &entities.get(&id).unwrap().user_data;
        assert_eq!(ud["hp"].as_u64().unwrap(), INITIAL_HP as u64);
        assert_eq!(ud["inv"]["5"].as_u64().unwrap(), 3);
        assert_eq!(ud["events"].as_u64().unwrap(), 1);
        assert!(ud["buff"].is_null());
    }

    #[test]
    fn buff_expires_and_clears_from_user_data() {
        let sim = BenchmarkSimulation::new();
        let id = Uuid::from_u128(1);
        let mut entities = HashMap::new();
        entities.insert(id, mk_entity(1, 2500.0, 2500.0, 0.0, 0.0));

        let pickup = GameAction {
            entity_id: id,
            action_type: "pickup_item".into(),
            payload: serde_json::json!({ "item_type": 0, "quantity": 1 }),
        };
        let use_it = GameAction {
            entity_id: id,
            action_type: "use_item".into(),
            payload: serde_json::json!({ "item_type": 0 }),
        };
        run_tick(&sim, 1, &mut entities, &[pickup]);
        run_tick(&sim, 2, &mut entities, &[use_it]);
        assert!(!entities.get(&id).unwrap().user_data["buff"].is_null());

        // Advance past expiration. The test runs at dt = 0.05 (20 Hz) so the
        // buff covers 200 ticks; the helper makes that explicit.
        let expiry = 2 + buff_duration_ticks(0.05) + 1;
        run_tick(&sim, expiry, &mut entities, &[]);
        assert!(entities.get(&id).unwrap().user_data["buff"].is_null());
    }

    #[test]
    fn state_row_is_reclaimed_when_entity_leaves() {
        let sim = BenchmarkSimulation::new();
        let id = Uuid::from_u128(1);
        let mut entities = HashMap::new();
        entities.insert(id, mk_entity(1, 2500.0, 2500.0, 0.0, 0.0));
        run_tick(&sim, 1, &mut entities, &[]);
        assert!(sim.state.lock().unwrap().contains_key(&id));

        entities.clear();
        run_tick(&sim, 2, &mut entities, &[]);
        assert!(sim.state.lock().unwrap().is_empty());
    }
}
