# Workload parity analysis

This document describes exactly what computation and I/O each benchmark mode performs per tick, so anyone can verify that both modes do equivalent work.

## Constants (identical in both modes)

| Constant | Value | Used for |
|----------|-------|----------|
| WORLD_SIZE | 5000 | World bounds |
| PHYSICS_SPEED | 600 units/sec | Movement speed |
| PHYSICS_DT | 0.05 sec | Tick interval (20 Hz) |
| WORLD_MIN | 200 | Clamp lower bound |
| WORLD_MAX | 4800 | Clamp upper bound |
| COLLISION_RADIUS | 50 units | Proximity threshold |
| COLLISION_DAMAGE | 10 HP | Damage per collision |
| BUFF_SPEED_MULTIPLIER | 2.0 | Speed potion effect |
| BUFF_DURATION | 200 ticks (10 sec) | Buff expiration |

Source files:
- SpacetimeDB-only: `crates/benchmark-spacetimedb-full/src/lib.rs` lines 16-22
- Arcane cluster: `crates/benchmark-cluster/src/simulation.rs` lines 18-26

## Per-tick operations

N = number of entities, B = active buffs, C = collision pairs, A = game actions per tick.

### SpacetimeDB-only mode

The `physics_tick` scheduled reducer runs at 20 Hz inside the SpacetimeDB WASM module:

| Step | What | I/O |
|------|------|-----|
| 1. Tick counter | Read + increment singleton row | 1 table read, 1 table write |
| 2. Expire buffs | Scan active_buff table, delete expired | B table reads, ~0 deletes (most ticks) |
| 3. Read direction | For each entity, look up PlayerInput | N table reads |
| 4. Read buff | For each entity, look up ActiveBuff | N table reads |
| 5. Move | `position += direction * step * speed_mult`, clamp | N × (2 multiply, 2 add, 2 clamp) |
| 6. Write position | Update Entity table row | N table writes |
| 7. Collect positions | Read all entities for collision check | N table reads |
| 8. Collision check | Pairwise distance: `dx*dx + dz*dz < radius²` | N² × (2 sub, 2 mul, 1 add, 1 compare) |
| 9. Apply damage | In-process function per collision pair | C × (2 table reads + 2 table writes) |

Game actions (pickup_item, use_item, interact) arrive separately via HTTP reducer calls from the swarm at `actions_per_sec` rate. These are not part of `physics_tick`.

### Arcane + SpacetimeDB mode

The `BenchmarkSimulation::on_tick` runs at 20 Hz inside the Arcane cluster process:

| Step | What | I/O |
|------|------|-----|
| 1. Expire buffs | HashMap retain (remove expired) | B in-memory comparisons |
| 2. Process actions | For each GAME_ACTION from clients: parse, call SpacetimeDB reducer | A × 1 HTTP round-trip |
| 3. Read buff | For each entity, look up in local HashMap | N HashMap lookups |
| 4. Move | `position += velocity * speed_mult`, clamp | N × (2 multiply, 2 add, 2 clamp) |
| 5. Collect positions | Read entity positions from in-memory map | N in-memory reads |
| 6. Collision check | Pairwise distance: `dx*dx + dz*dz < radius²` | N² × (2 sub, 2 mul, 1 add, 1 compare) |
| 7. Apply damage | Single batched HTTP call with all collision pairs | 1 HTTP round-trip (apply_damage_batch) |

Position persistence to SpacetimeDB happens at 1 Hz (every 20 ticks), not per tick.

## What's the same

- **Arithmetic operations per entity:** Identical. Both do 2 multiplies, 2 adds, 2 clamps per entity for movement.
- **Collision detection:** Same O(n²) algorithm with same constants. Both iterate all pairs and check squared distance.
- **Buff mechanics:** Same effect (2x speed), same duration (200 ticks). Both expire buffs and apply multiplier.
- **Game actions:** Same types (pickup_item, use_item, interact) at the same rate. Both ultimately call SpacetimeDB reducers.

## What's different (by design)

| Aspect | SpacetimeDB-only | Arcane |
|--------|-----------------|-------|
| **Direction storage** | PlayerInput table (database) | entity.velocity (in-memory) |
| **Buff storage** | ActiveBuff table (database) | HashMap (in-memory) |
| **Position storage** | Entity table (database, written every tick) | In-memory (persisted to SpacetimeDB at 1 Hz) |
| **Collision damage** | In-process function call | 1 batched HTTP call per tick |
| **Action delivery** | Direct HTTP from client to SpacetimeDB | Client → cluster WebSocket → cluster HTTP to SpacetimeDB |
| **State broadcast** | SpacetimeDB subscription fanout | Cluster → Redis pub/sub + WebSocket to clients |

These differences are the **point of the benchmark**. SpacetimeDB-only does everything through database operations on a single machine. Arcane keeps high-frequency state in memory and distributes simulation across clusters, only calling SpacetimeDB for authoritative state changes.

## Why both modes are fair

1. **Same computation:** Identical arithmetic per entity, identical collision algorithm.
2. **Same game logic:** Same actions at same rates, same buff effects, same damage.
3. **Different I/O patterns represent different architectures:** SpacetimeDB pays for database reads/writes every tick. Arcane pays for network calls to SpacetimeDB only for persistent/authoritative changes. This is the trade-off each architecture makes.
4. **Collision damage batched in Arcane mode:** Without batching, the cluster would make N² blocking HTTP calls per tick — an unrealistic penalty since any real implementation would batch. The SpacetimeDB module's `apply_collision_damage` is an in-process call, so batching makes the comparison fair.

## How to verify

1. Compare physics constants in both source files (listed above).
2. Compare the movement math: both compute `position += input * speed * speed_mult` and clamp.
3. Compare collision detection: both iterate `i in 0..N, j in (i+1)..N` and check `dx² + dz² < radius²`.
4. Run both modes with 1 player and compare logged positions — they should match within floating-point precision.

## Source files

| Component | File |
|-----------|------|
| SpacetimeDB-only module | `crates/benchmark-spacetimedb-full/src/lib.rs` |
| Arcane-mode SpacetimeDB module | `crates/benchmark-spacetimedb-persist/src/lib.rs` |
| Arcane cluster simulation | `crates/benchmark-cluster/src/simulation.rs` |
| Swarm (load generator) | `arcane_swarm/crates/arcane-swarm/src/` |
