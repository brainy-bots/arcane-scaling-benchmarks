//! SpacetimeDB module for **SpacetimeDB-only** benchmark mode.
//!
//! In this mode SpacetimeDB handles everything: physics simulation, player input,
//! inventory, interactions, and collision detection. There are no Arcane clusters.
//!
//! ## Physics constants
//!
//! These MUST match the Arcane-mode BenchmarkSimulation (benchmark-cluster crate).
//! If you change a value here, change it there too.
//! See: crates/benchmark-cluster/src/lib.rs

use spacetimedb::{reducer, table, ReducerContext, ScheduleAt, Table};
use std::time::Duration;

// ── Physics constants (must match benchmark-cluster BenchmarkSimulation) ─────
pub const WORLD_SIZE: f64 = 5000.0;
pub const PHYSICS_SPEED: f64 = 600.0;
pub const PHYSICS_DT: f64 = 0.05; // 20 Hz
pub const WORLD_MIN: f64 = 200.0;
pub const WORLD_MAX: f64 = WORLD_SIZE - 200.0;
pub const COLLISION_RADIUS: f64 = 50.0;
pub const COLLISION_DAMAGE: u32 = 10;

// ── Entity table (public: clients subscribe) ────────────────────────────────

#[table(accessor = entity, public)]
pub struct Entity {
    #[primary_key]
    pub entity_id: spacetimedb::Uuid,
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

// ── PlayerInput table (private: no client subscription, no fanout) ──────────

#[table(accessor = player_input)]
pub struct PlayerInput {
    #[primary_key]
    pub entity_id: spacetimedb::Uuid,
    pub dir_x: f64,
    pub dir_z: f64,
}

// ── Buff table (private: cluster reads, no client fanout) ───────────────────

#[table(accessor = active_buff)]
pub struct ActiveBuff {
    #[primary_key]
    pub entity_id: spacetimedb::Uuid,
    /// Speed multiplier (1.0 = normal, 2.0 = double speed).
    pub speed_multiplier: f64,
    /// Tick when the buff expires (compared against physics_tick count).
    pub expires_at_tick: u64,
}

// ── Health table (public: clients see HP) ───────────────────────────────────

#[table(accessor = health, public)]
pub struct Health {
    #[primary_key]
    pub entity_id: spacetimedb::Uuid,
    pub hp: u32,
    pub max_hp: u32,
}

// ── Inventory table ─────────────────────────────────────────────────────────

#[table(accessor = inventory, public,
    index(accessor = owner_item, btree(columns = [owner_id, item_type])),
)]
pub struct Inventory {
    #[primary_key]
    #[auto_inc]
    pub row_id: u64,
    pub owner_id: spacetimedb::Uuid,
    pub item_type: u32,
    pub quantity: u32,
}

// ── GameEvent table ─────────────────────────────────────────────────────────

#[table(accessor = game_event, public)]
pub struct GameEvent {
    #[primary_key]
    #[auto_inc]
    pub event_id: u64,
    pub actor_id: spacetimedb::Uuid,
    pub target_id: spacetimedb::Uuid,
    pub event_type: u32,
    pub timestamp_us: i64,
}

// ── Physics timer ───────────────────────────────────────────────────────────

#[table(accessor = physics_timer, scheduled(physics_tick))]
pub struct PhysicsTimer {
    #[primary_key]
    #[auto_inc]
    pub scheduled_id: u64,
    pub scheduled_at: spacetimedb::ScheduleAt,
}

// ── Tick counter (for buff expiration) ──────────────────────────────────────

#[table(accessor = tick_counter)]
pub struct TickCounter {
    #[primary_key]
    pub id: u32, // always 0, singleton row
    pub tick: u64,
}

// ── Init ────────────────────────────────────────────────────────────────────

#[reducer(init)]
pub fn init(ctx: &ReducerContext) {
    log::info!("benchmark-spacetimedb-full module initialized");
    ctx.db.physics_timer().insert(PhysicsTimer {
        scheduled_id: 0,
        scheduled_at: ScheduleAt::from(Duration::from_millis(50)),
    });
    ctx.db.tick_counter().insert(TickCounter { id: 0, tick: 0 });
}

// ── Scheduled physics tick ──────────────────────────────────────────────────

#[reducer]
pub fn physics_tick(ctx: &ReducerContext, _timer: PhysicsTimer) -> Result<(), String> {
    // Advance tick counter
    let current_tick = match ctx.db.tick_counter().id().find(&0) {
        Some(mut tc) => {
            tc.tick += 1;
            let t = tc.tick;
            ctx.db.tick_counter().id().update(tc);
            t
        }
        None => 0,
    };

    // Expire old buffs
    let expired: Vec<spacetimedb::Uuid> = ctx
        .db
        .active_buff()
        .iter()
        .filter(|b| b.expires_at_tick <= current_tick)
        .map(|b| b.entity_id)
        .collect();
    for id in expired {
        ctx.db.active_buff().entity_id().delete(&id);
    }

    // Move entities
    let step = PHYSICS_SPEED * PHYSICS_DT;
    let entities: Vec<Entity> = ctx.db.entity().iter().collect();
    for mut ent in entities {
        let (dx, dz) = ctx
            .db
            .player_input()
            .entity_id()
            .find(&ent.entity_id)
            .map(|inp| (inp.dir_x, inp.dir_z))
            .unwrap_or((0.0, 0.0));

        // Apply speed buff if active
        let speed_mult = ctx
            .db
            .active_buff()
            .entity_id()
            .find(&ent.entity_id)
            .map(|b| b.speed_multiplier)
            .unwrap_or(1.0);

        let effective_step = step * speed_mult;
        ent.x = (ent.x + dx * effective_step).clamp(WORLD_MIN, WORLD_MAX);
        ent.z = (ent.z + dz * effective_step).clamp(WORLD_MIN, WORLD_MAX);
        ctx.db.entity().entity_id().update(ent);
    }

    // Collision detection — O(n^2) but that's the point: this is expensive work
    // that Arcane distributes across clusters
    let all: Vec<Entity> = ctx.db.entity().iter().collect();
    let radius_sq = COLLISION_RADIUS * COLLISION_RADIUS;
    for i in 0..all.len() {
        for j in (i + 1)..all.len() {
            let dx = all[i].x - all[j].x;
            let dz = all[i].z - all[j].z;
            if dx * dx + dz * dz < radius_sq {
                apply_collision_damage(ctx, all[i].entity_id, all[j].entity_id);
            }
        }
    }

    Ok(())
}

fn apply_collision_damage(ctx: &ReducerContext, a: spacetimedb::Uuid, b: spacetimedb::Uuid) {
    for id in [a, b] {
        if let Some(mut h) = ctx.db.health().entity_id().find(&id) {
            h.hp = h.hp.saturating_sub(COLLISION_DAMAGE);
            ctx.db.health().entity_id().update(h);
        }
    }
}

// ── Player management ───────────────────────────────────────────────────────

#[reducer]
pub fn update_player(ctx: &ReducerContext, entity: Entity) -> Result<(), String> {
    if ctx.db.entity().entity_id().find(&entity.entity_id).is_some() {
        ctx.db.entity().entity_id().update(entity);
    } else {
        // New player — also create health row
        let eid = entity.entity_id;
        ctx.db.entity().insert(entity);
        ctx.db.health().insert(Health {
            entity_id: eid,
            hp: 100,
            max_hp: 100,
        });
    }
    Ok(())
}

#[reducer]
pub fn update_player_input(
    ctx: &ReducerContext,
    entity_id: spacetimedb::Uuid,
    dir_x: f64,
    dir_z: f64,
) -> Result<(), String> {
    if let Some(mut row) = ctx.db.player_input().entity_id().find(&entity_id) {
        row.dir_x = dir_x;
        row.dir_z = dir_z;
        ctx.db.player_input().entity_id().update(row);
    } else {
        ctx.db.player_input().insert(PlayerInput {
            entity_id,
            dir_x,
            dir_z,
        });
    }
    Ok(())
}

#[reducer]
pub fn remove_player_by_id(
    ctx: &ReducerContext,
    entity_id: spacetimedb::Uuid,
) -> Result<(), String> {
    ctx.db.entity().entity_id().delete(&entity_id);
    ctx.db.player_input().entity_id().delete(&entity_id);
    ctx.db.health().entity_id().delete(&entity_id);
    ctx.db.active_buff().entity_id().delete(&entity_id);
    Ok(())
}

#[reducer]
pub fn set_entities(ctx: &ReducerContext, entities: Vec<Entity>) -> Result<(), String> {
    let ids: Vec<_> = ctx.db.entity().iter().map(|r| r.entity_id).collect();
    for id in ids {
        ctx.db.entity().entity_id().delete(&id);
    }
    for e in entities {
        ctx.db.entity().insert(e);
    }
    Ok(())
}

// ── Inventory reducers ──────────────────────────────────────────────────────

#[reducer]
pub fn pickup_item(
    ctx: &ReducerContext,
    owner_id: spacetimedb::Uuid,
    item_type: u32,
    quantity: u32,
) -> Result<(), String> {
    let mut found = false;
    for mut row in ctx.db.inventory().owner_item().filter((owner_id, item_type)) {
        row.quantity += quantity;
        ctx.db.inventory().row_id().update(row);
        found = true;
        break;
    }
    if !found {
        ctx.db.inventory().insert(Inventory {
            row_id: 0,
            owner_id,
            item_type,
            quantity,
        });
    }
    Ok(())
}

/// Use an item. item_type 0 = speed potion (grants 2x speed for 200 ticks / 10 seconds).
#[reducer]
pub fn use_item(
    ctx: &ReducerContext,
    owner_id: spacetimedb::Uuid,
    item_type: u32,
) -> Result<(), String> {
    let mut consumed = false;
    for mut row in ctx.db.inventory().owner_item().filter((owner_id, item_type)) {
        if row.quantity > 1 {
            row.quantity -= 1;
            ctx.db.inventory().row_id().update(row);
        } else {
            ctx.db.inventory().row_id().delete(&row.row_id);
        }
        consumed = true;
        break;
    }
    if !consumed {
        return Ok(()); // no item to use
    }

    // Item 0 = speed potion: grant buff
    if item_type == 0 {
        let current_tick = ctx
            .db
            .tick_counter()
            .id()
            .find(&0)
            .map(|tc| tc.tick)
            .unwrap_or(0);
        if let Some(mut buff) = ctx.db.active_buff().entity_id().find(&owner_id) {
            buff.speed_multiplier = 2.0;
            buff.expires_at_tick = current_tick + 200; // 10 seconds at 20 Hz
            ctx.db.active_buff().entity_id().update(buff);
        } else {
            ctx.db.active_buff().insert(ActiveBuff {
                entity_id: owner_id,
                speed_multiplier: 2.0,
                expires_at_tick: current_tick + 200,
            });
        }
    }

    Ok(())
}

// ── Interaction / event reducers ────────────────────────────────────────────

#[reducer]
pub fn player_interact(
    ctx: &ReducerContext,
    actor_id: spacetimedb::Uuid,
    target_id: spacetimedb::Uuid,
    event_type: u32,
) -> Result<(), String> {
    ctx.db.game_event().insert(GameEvent {
        event_id: 0,
        actor_id,
        target_id,
        event_type,
        timestamp_us: ctx.timestamp.to_micros_since_unix_epoch(),
    });
    Ok(())
}

#[reducer]
pub fn apply_damage(
    ctx: &ReducerContext,
    target_id: spacetimedb::Uuid,
    amount: u32,
) -> Result<(), String> {
    if let Some(mut h) = ctx.db.health().entity_id().find(&target_id) {
        h.hp = h.hp.saturating_sub(amount);
        ctx.db.health().entity_id().update(h);
    }
    Ok(())
}

#[reducer]
pub fn cleanup_old_events(ctx: &ReducerContext, max_age_secs: u64) -> Result<(), String> {
    let cutoff =
        ctx.timestamp.to_micros_since_unix_epoch() - (max_age_secs as i64 * 1_000_000);
    let stale: Vec<u64> = ctx
        .db
        .game_event()
        .iter()
        .filter(|e| e.timestamp_us < cutoff)
        .map(|e| e.event_id)
        .collect();
    for id in stale {
        ctx.db.game_event().event_id().delete(&id);
    }
    Ok(())
}
