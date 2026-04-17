//! SpacetimeDB module for **Arcane + SpacetimeDB** benchmark mode.
//!
//! In this mode Arcane clusters handle physics simulation and collision detection.
//! This module provides:
//! - Entity position persistence (clusters write at 1 Hz via `set_entities`)
//! - Inventory management (use_item validates and grants buffs)
//! - Interaction/event logging
//! - Damage application (clusters call `apply_damage` on collision)
//! - Health tracking
//!
//! There is NO `physics_tick`, NO `update_player_input`, NO `PlayerInput` table.
//! The cluster owns movement. SpacetimeDB owns durable state.
//!
//! ## Buff response pattern
//!
//! When a client sends "use_item" through the cluster, the cluster calls the
//! `use_item` reducer here. The reducer consumes the item and writes to `active_buff`.
//! The cluster reads the result (success = buff granted) and applies the speed
//! multiplier in its simulation. This is the "Client → Cluster → SpacetimeDB" pattern.

use spacetimedb::{reducer, table, ReducerContext, Table};

// ── Entity table (public: clients subscribe, clusters write at 1 Hz) ────────

#[table(accessor = entity, public)]
pub struct Entity {
    #[primary_key]
    pub entity_id: spacetimedb::Uuid,
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

// ── Health table (public: clients see HP) ───────────────────────────────────

#[table(accessor = health, public)]
pub struct Health {
    #[primary_key]
    pub entity_id: spacetimedb::Uuid,
    pub hp: u32,
    pub max_hp: u32,
}

// ── Buff table (cluster reads after use_item call) ──────────────────────────

#[table(accessor = active_buff, public)]
pub struct ActiveBuff {
    #[primary_key]
    pub entity_id: spacetimedb::Uuid,
    /// Speed multiplier (1.0 = normal, 2.0 = double speed).
    pub speed_multiplier: f64,
    /// Duration in ticks (cluster tracks expiration locally).
    pub duration_ticks: u64,
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

// ── Init ────────────────────────────────────────────────────────────────────

#[reducer(init)]
pub fn init(_ctx: &ReducerContext) {
    log::info!("benchmark-spacetimedb-persist module initialized (Arcane mode — no physics)");
}

// ── Entity persistence (called by Arcane clusters at 1 Hz) ────��─────────────

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

/// Register a new player (called by cluster when a player joins).
#[reducer]
pub fn register_player(
    ctx: &ReducerContext,
    entity_id: spacetimedb::Uuid,
    x: f64,
    y: f64,
    z: f64,
) -> Result<(), String> {
    if ctx.db.entity().entity_id().find(&entity_id).is_none() {
        ctx.db.entity().insert(Entity {
            entity_id,
            x,
            y,
            z,
        });
    }
    if ctx.db.health().entity_id().find(&entity_id).is_none() {
        ctx.db.health().insert(Health {
            entity_id,
            hp: 100,
            max_hp: 100,
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
    ctx.db.health().entity_id().delete(&entity_id);
    ctx.db.active_buff().entity_id().delete(&entity_id);
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
/// The cluster calls this reducer and reads the active_buff table to apply the effect.
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
        return Ok(());
    }

    // Item 0 = speed potion: write buff so cluster can read it
    if item_type == 0 {
        if let Some(mut buff) = ctx.db.active_buff().entity_id().find(&owner_id) {
            buff.speed_multiplier = 2.0;
            buff.duration_ticks = 200; // 10 seconds at 20 Hz
            ctx.db.active_buff().entity_id().update(buff);
        } else {
            ctx.db.active_buff().insert(ActiveBuff {
                entity_id: owner_id,
                speed_multiplier: 2.0,
                duration_ticks: 200,
            });
        }
    }

    Ok(())
}

// ── Damage (called by Arcane clusters on collision detection) ────────────────

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
