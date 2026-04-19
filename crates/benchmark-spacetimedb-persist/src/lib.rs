//! SpacetimeDB module for **Arcane + SpacetimeDB** benchmark mode.
//!
//! In this mode Arcane clusters own all simulation and game state. SpacetimeDB acts as the
//! throttled durable sink for the cluster's per-tick snapshot.
//!
//! ## Why the module is minimal
//!
//! Earlier revisions of this module exposed per-action reducers (`apply_damage`,
//! `use_item`, `pickup_item`, `player_interact`) that the cluster called inline during
//! `on_tick`. That pattern turned the tick loop into a synchronous HTTP driver — the
//! cluster blocked on SpacetimeDB round-trips thousands of times per second under load.
//!
//! The progressive-API level-1 persistence path (see
//! `arcane/docs/architecture/progressive-api.md`) solves this: the cluster keeps HP,
//! inventory, buffs, and interaction counters in local memory, writes them to each
//! entity's `user_data` JSON field, and the `set_entities` snapshot carries the whole
//! picture to SpacetimeDB at 1 Hz. No per-action reducers needed on the cluster hot path.
//!
//! What this module exposes, therefore, is just the persistence sink:
//! - `Entity` table with `{ entity_id, x, y, z, user_data: String }`.
//! - `set_entities` reducer: clusters invoke this at 1 Hz to replace the table with the
//!   current snapshot.
//!
//! Game-logic reducers (validation, anti-cheat, shop purchases) would land at ladder
//! level 2+ when a concrete game demands them — none does today for the benchmark.

use spacetimedb::{reducer, table, ReducerContext, Table};

// ── Entity table (public: clients subscribe, clusters write at 1 Hz) ────────
//
// `user_data` is a JSON-encoded string populated by the cluster. The column is opaque to
// this module by design — the cluster owns the schema. Games that don't mutate `user_data`
// get an empty string.

#[table(accessor = entity, public)]
pub struct Entity {
    #[primary_key]
    pub entity_id: spacetimedb::Uuid,
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub user_data: String,
}

// ── Init ─────────────────────────────────────────────────────────────────────

#[reducer(init)]
pub fn init(_ctx: &ReducerContext) {
    log::info!("benchmark-spacetimedb-persist initialized (Arcane mode; L1 auto-persist sink)");
}

// ── Entity persistence (called by Arcane clusters at 1 Hz) ───────────────────

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
