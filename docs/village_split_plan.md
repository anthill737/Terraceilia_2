# Phase 6 Plan: Splitting `village.gd`

**Author:** Builder 10 (T10)
**Source file:** `scripts/village/village.gd` — 1141 lines
**Branch at time of analysis:** `fix/cross-village-targeting-leak`
**Note:** File has uncommitted modifications from Builder 4 (T3 — trade flow counters). The new vars (`wheat_exported`, `wheat_imported`, `bread_exported`, `bread_imported`) and methods (`record_trade_export`, `record_trade_import`, `get_trade_flow_summary`, `reset_trade_flow_counters`) are included in this analysis.

---

## Overview

`village.gd` acts as a monolith that owns initialization, simulation ticking, agent spawning, role conversion, labor mobility, trade data, prosperity gating, economy stats, config loading, debug visualization, and snapshot reporting. The goal of Phase 6 is to extract discrete service classes while keeping `Village` as the owner/coordinator.

---

## Group 1 — Spawn Service

**Proposed file:** `scripts/village/spawn_service.gd`

### Functions

| Function | Lines | Notes |
|---|---|---|
| `spawn_farmer_at(pos)` | 570–650 | ~80 lines; async (await process_frame) |
| `spawn_baker_at(pos)` | 653–720 | ~68 lines; async |
| `spawn_household_at(pos)` | 723–779 | ~57 lines; async |
| `spawn_field_at(pos, assign_to, skip_auto_assign)` | 523–567 | ~45 lines |
| `_resolve_agent_scene()` | 492–499 | loads Agent.tscn |
| `_assign_new_identity(pop)` | 502–504 | delegates to pop_mgr |
| `_fixup_node_name(node, prefix)` | 507–515 | name sanitization |
| `_assign_field_to_farmer(field_node, farmer)` | 518–520 | delegates to field_mgr |
| `get_total_population()` | 488–489 | delegates to pop_mgr |
| `get_spawn_point_for_role(role)` | 1076–1089 | world-space position picker |
| `_get_next_farmer_position()` | 1092–1099 | **LEGACY/UNUSED** — superseded by `get_spawn_point_for_role` |
| `_get_next_baker_position()` | 1102–1109 | **LEGACY/UNUSED** — same |
| `_on_household_died(agent_node)` | 782–793 | removes dead household from pop arrays |

### Dependencies (what it calls)
- `pop_mgr` — `assign_identity()`, `next_farmer_id`, `next_baker_id`, `next_household_id`, `MAX_TOTAL_POP`, `count()`, `_next_person_id`
- `field_mgr` — `assign_field()`, `field_assignment_map`, `all_field_nodes`, `MAX_FIELDS`, `next_field_id`
- `AgentScene` — `instantiate()`
- `market`, `market_node`, `event_bus`, `econ_stats`, `calendar` — injected onto new agents
- `HungerNeed`, `FoodReserve`, `Wallet`, `Inventory` — bound on new agent via get_node()
- `village_id`, `village_center`, `spawn_radius`, `inner_spawn_radius`, `rng` — village identity
- `get_tree().process_frame` — Godot scene-tree await (async spawning)

### What calls these functions
- `_perform_role_conversion()` (labor service) calls `spawn_field_at()`
- `receive_tick()` calls `spawn_household_at()` via prosperity check
- `main.gd` / player placement calls `spawn_farmer_at()`, `spawn_baker_at()`, `spawn_field_at()`

### Extraction difficulty: **MEDIUM**

**Reason:** The spawn functions have no complex internal state but are deeply wired. Each spawn function manually injects `market`, `event_bus`, `econ_stats`, `calendar` and binds `HungerNeed`/`FoodReserve` directly. Extraction requires either:
1. Passing village as context: `SpawnService.new(village)` — then `service.spawn_farmer_at(pos)`
2. Or passing a setup dict with all dependencies

The `await get_tree().process_frame` calls need the scene tree — the service must either be an `add_child` node or the caller must handle the await. The `_perform_role_conversion()` call to `spawn_field_at()` creates a **circular dependency** with the labor service; this must be resolved before extraction (e.g., labor service calls `village.spawn_field_at()` via a signal or direct village reference).

The two `_get_next_*_position()` functions are unused and should be **deleted** before extraction.

---

## Group 2 — Trade Service

**Proposed file:** `scripts/village/trade_service.gd`

### Functions

| Function | Lines | Notes |
|---|---|---|
| `get_trade_snapshot()` | 360–376 | read-only market snapshot |
| `record_trade_export(good, qty)` | 381–384 | increments export counters |
| `record_trade_import(good, qty)` | 387–392 | increments import counters |
| `get_trade_flow_summary()` | 397–406 | returns dict with net flows |
| `reset_trade_flow_counters()` | 409–414 | zero all counters |

### Variables owned by this service
```
var wheat_exported: int = 0   # line 53
var wheat_imported: int = 0   # line 54
var bread_exported: int = 0   # line 55
var bread_imported: int = 0   # line 56
```

### Dependencies (what it calls)
- `market` — `get_bid_price()`, `wheat`, `bread`, `wheat_target`, `bread_target`, `wheat_market_buy_blocked`, `bread_market_buy_blocked`
- `global_position` — for `world_pos` in snapshot
- `village_id`, `village_name` — identity

### What calls these functions
- `FarmerJob` / `BakerJob` agent scripts call `get_trade_snapshot()` on all villages
- `FarmerJob` / `BakerJob` call `record_trade_export()` after a remote sale
- Agent scripts call `record_trade_import()` on arrival village after a sale
- `_on_calendar_day_changed()` should call `reset_trade_flow_counters()` (currently missing — should be added)
- Telemetry / inspector reads `get_trade_flow_summary()`

**Note:** `receive_trade_arrival()` was mentioned in the coordinator task description but is **not present** in `village.gd` as of this analysis. It may live in the agent job script instead, or it is a planned addition in a future phase.

### Extraction difficulty: **EASY**

**Reason:** These functions are thin, read-only or counter-mutation. The counters are simple vars. The only coupling is to `market` (already an injected reference) and village identity vars. A `TradeService` node could hold the counters and receive `market` + identity at `bind()` time. Village would delegate `get_trade_snapshot()` etc. to the service. No async, no scene-tree coupling.

---

## Group 3 — Labor / Career Service

**Proposed file:** `scripts/village/labor_service.gd`

### Functions

| Function | Lines | Notes |
|---|---|---|
| `_on_migrate_requested(agent, reason)` | 844–876 | removes migrating agent from all arrays |
| `_on_role_switch_requested(household, new_role)` | 879–893 | queues pending_conversion |
| `_perform_role_conversion(household, role)` | 896–1011 | 116 lines; converts household → farmer or baker |

### Variables owned by this service
```
var pending_conversions: Array = []   # line 45
var sim_failed: bool = false          # line 46
```

### Dependencies (what it calls)
- `labor_market` — signal source; `LaborMarket.BAKER_TRAINING_DAYS`, `LaborMarket.FARMER_TRAINING_DAYS`
- `pop_mgr` — arrays and IDs
- `field_mgr` — `field_assignment_map`
- `event_bus` — logging
- `market`, `calendar` — re-bound on converted agents (HungerNeed/FoodReserve)
- `households`, `all_farmers`, `all_bakers` — direct array mutation
- Spawn helpers: `spawn_field_at()`, `_assign_field_to_farmer()`, `_fixup_node_name()`, `get_spawn_point_for_role()`
- `village_id`, `next_farmer_id`, `next_baker_id`
- `Agent` class (type cast), `CareerEvaluator` node on agent

### What calls these functions
- `labor_market.migrate_requested` signal → `_on_migrate_requested()`
- `labor_market.role_switch_requested` signal → `_on_role_switch_requested()`
- `_on_calendar_day_changed()` calls `pending_conversions` loop → `_perform_role_conversion()`

### Extraction difficulty: **HARD**

**Reason:** `_perform_role_conversion()` is a 116-line mega-function that:
1. Reads agent state (`CareerEvaluator`, `Wallet`, `current_role`)
2. Calls spawn helpers (`spawn_field_at()`, `_assign_field_to_farmer()`, `_fixup_node_name()`)
3. Mutates role arrays (`households`, `all_farmers`, `all_bakers`)
4. Rebinds `HungerNeed` and `FoodReserve` on the converted agent
5. Creates new scene nodes (`home`, `bakery_spot`) with `add_child()` called on **village**

This creates a **bidirectional dependency**: labor service needs spawn service AND spawn service is partially needed during conversion. Both services need direct access to the scene tree (via village's `add_child()`). A clean split requires either:
- Passing a `VillageContext` interface
- Using signals to request spawns from village
- Or leaving `_perform_role_conversion()` in village and only extracting the signal handlers + `pending_conversions` management

The `_on_migrate_requested()` and `_on_role_switch_requested()` functions alone are straightforward to extract (they are clean signal handlers). `_perform_role_conversion()` should be addressed **last** and may require a Godot-native refactor (Phase 4 signals) before it can be cleanly isolated.

---

## Group 4 — Prosperity Service

**Proposed file:** Not warranted as a standalone file — prosperity is already in `ProsperityMeter`. The chunk in `receive_tick()` (lines 325–346) is just a delegation block.

### Functions / Blocks

| Function/Block | Lines | Notes |
|---|---|---|
| Prosperity block inside `receive_tick()` | 325–346 | spawn check + suppress check + SPAWN CHECK log |
| `prosperity_meter.bind_references(...)` in `initialize()` | 261 | wiring |

### Dependencies
- `prosperity_meter` — `update_prosperity()`, `should_spawn_household()`, `record_spawn()`, `prosperity_score`, `PROSPERITY_THRESHOLD_TO_GROW`
- `labor_market` — `should_suppress_spawn()`
- `households` — size check
- `calendar.day_index`
- `spawn_household_at()` — spawns the new household
- `event_bus` — SPAWN CHECK log

### Extraction difficulty: **EASY (as extraction); N/A as new service**

**Reason:** The actual prosperity logic lives entirely in `ProsperityMeter`. The block in `receive_tick()` is 20 lines of delegation. It can be extracted to a `_tick_prosperity(tick)` private method in village, keeping the code organized without needing a new service file. A full `ProsperityService` wrapper is unnecessary overhead.

---

## Group 5 — Economy / Market Service (Day Cycle)

**Proposed file:** Could partially move to `scripts/village/economy_service.gd` for the day-cycle logic, but see notes.

### Functions

| Function | Lines | Notes |
|---|---|---|
| `receive_tick(tick)` | 305–349 | main tick distributor — dispatches to all sub-systems |
| `tick_sim(tick)` | 296–297 | canonical entry point (thin wrapper) |
| `tick(_delta)` | 301–302 | legacy alias — no-op |
| `_on_calendar_day_changed(day)` | 799–841 | day-cycle handler: pop logs, labor_market, agent day, cashflow, sim-fail check, pending conversions |
| `get_market()` | 352–354 | accessor |
| `_roll_global_cashflow()` | 1026–1028 | delegates to econ_stats.roll_daily() |
| `global_role_rolling_7d_sum(role)` | 1031–1032 | delegates to econ_stats |
| `global_role_rolling_7d_avg(role)` | 1035–1036 | delegates to econ_stats |
| `_load_economy_config()` | 1043–1056 | JSON file load |
| `_apply_market_seed()` | 1059–1066 | seeds market from config |

### Dependencies (what it calls)
- `calendar`, `market`, `audit`, `field_mgr`, `labor_market`, `econ_stats`
- `all_farmers`, `all_bakers`, `households` — iterates all agents
- `prosperity_meter` — calls `update_prosperity()`
- `sim_failed`, `pop_mgr`, `event_bus`
- `_roll_global_cashflow()`, `pending_conversions` loop, `_perform_role_conversion()`

### What calls these functions
- `SimulationClock.ticked` signal → `tick_sim()` (wired in `world.gd`)
- `calendar.day_changed` signal → `_on_calendar_day_changed()` (wired in `initialize()`)
- `main.gd` / inspector reads `get_market()`

### Extraction difficulty: **HARD**

**Reason:** `_on_calendar_day_changed()` does 6 different things and is tightly coupled to nearly every other service. `receive_tick()` is the entry point for the entire simulation loop — it cannot be moved without restructuring the whole tick flow. These are best kept in `village.gd` as coordinator responsibilities. The config functions (`_load_economy_config`, `_apply_market_seed`) are called only from `initialize()` and could be inlined or extracted to a standalone config loader utility.

The rolling stat helpers (`global_role_rolling_7d_sum`, `global_role_rolling_7d_avg`) are pure delegation to `econ_stats` and could be removed from village entirely — callers should access `village.econ_stats` directly.

---

## Group 6 — Debug / Snapshot Service

**Proposed file:** `scripts/village/snapshot_service.gd` (or keep in village as private methods)

### Functions

| Function | Lines | Notes |
|---|---|---|
| `_draw()` | 1116–1140 | Godot override — draws territory circles/labels |
| `get_population_summary()` | 417–425 | returns dict of pop counts |
| `get_econ_snapshot()` | 428–483 | 56 lines; deep dict of market + agent state |
| `log_population_snapshot()` | 1017–1023 | logs pop counts to event_bus |

### Dependencies (what it calls)
- `pop_mgr`, `field_mgr` — counts
- `market` — prices, quantities
- `calendar` — day
- `prosperity_meter` — score + sub-inputs
- `all_farmers`, `all_bakers` — first valid agent for baseline reads
- `event_bus` — logging
- `village_center`, `spawn_radius`, `inner_spawn_radius`, `village_name` — for `_draw()`

### What calls these functions
- `main.gd` / inspector calls `get_econ_snapshot()`, `get_population_summary()`
- `_draw()` called automatically by Godot's rendering loop
- `log_population_snapshot()` may be called externally for debug dumps

### Extraction difficulty: **EASY**

**Reason:** All functions are read-only (except `_draw()` which is visual-only). `get_econ_snapshot()` is the most complex but touches no mutable state — it reads and packages. `_draw()` must remain on the `Node2D` (village itself) since it is a Godot override, but it delegates entirely to `village_center` and draw primitives. A `SnapshotService` could hold `get_econ_snapshot()` and `get_population_summary()` if passed references, but since these are pure read operations with no lifecycle of their own, keeping them in village as public API is acceptable.

---

## Group 7 — Core / Coordinator (remains in `village.gd`)

These belong in village permanently — they are the coordinator logic, not services.

| Function | Lines | Notes |
|---|---|---|
| `initialize(seed_val, config)` | 100–293 | 193-line setup; delegates to all services |
| `tick_sim(tick)` | 296–297 | SimulationClock entry point |
| `tick(_delta)` | 301–302 | legacy no-op alias |
| `_draw()` | 1116–1140 | Node2D Godot override; cannot move |
| All variable declarations | 1–97 | identity, refs, managers, config vars |

After extraction, `initialize()` should shrink dramatically by delegating wiring to each service's `bind()` or `setup()` method.

---

## Summary Table

| Service | File | Lines Extractable | Difficulty | Notes |
|---|---|---|---|---|
| Spawn Service | `scripts/village/spawn_service.gd` | ~350 | MEDIUM | async spawns; needs village scene ref; circular dep with labor service |
| Trade Service | `scripts/village/trade_service.gd` | ~55 | EASY | thin wrappers + 4 counters; cleanest extraction |
| Labor/Career Service | `scripts/village/labor_service.gd` | ~170 | HARD | `_perform_role_conversion` has deep coupling; requires Phase 4 signal refactor first |
| Prosperity (inline) | — (keep in village) | ~20 | EASY | already delegated to ProsperityMeter; just extract to `_tick_prosperity()` |
| Economy/Day Cycle | — (keep in village) | ~60 partial | HARD | tick + day-change handlers are coordinator logic; config functions can be inlined or extracted separately |
| Debug/Snapshot | `scripts/village/snapshot_service.gd` or keep | ~80 | EASY | read-only; `_draw()` must stay in village |

---

## Recommended Extraction Order

1. **Trade Service** — cleanest, zero risk, no async, no scene-tree coupling
2. **Debug/Snapshot** — read-only, safe to move without breaking any behavior
3. **Spawn Service** — medium risk; solve async/scene-tree question first; delete the two legacy `_get_next_*_position()` functions before starting
4. **Prosperity inline method** — trivial refactor, just extract the `receive_tick()` block to `_tick_prosperity()`
5. **Economy/Config** — extract config loading (`_load_economy_config`, `_apply_market_seed`) to a `VillageConfig` helper; leave tick/day handlers in village
6. **Labor/Career Service** — do this LAST, after Phase 4 (signal-driven trade refactor) is complete; the signal-based architecture will make `_perform_role_conversion()` much cleaner

---

## Key Risks / Blockers

- **`_perform_role_conversion()` calls `spawn_field_at()` and `add_child()`** — requires village scene reference; cannot be cleanly isolated until spawning is signal-driven or the conversion function explicitly receives a `Village` reference
- **Async spawns (`await get_tree().process_frame`)** — the spawn service must either be a child node of Village (so it has scene-tree access) or spawning must be refactored to be non-async
- **Array sharing** — `all_farmers`, `all_bakers`, `households` are delegate properties on village that proxy to `pop_mgr`. Services that mutate these arrays (labor service, spawn service) must use the same array objects. Do not copy arrays — always pass references
- **`_on_calendar_day_changed()` is a catch-all** — splitting it requires deciding which service owns each sub-block; the pending_conversions loop must move with the labor service but the `labor_market.update_daily()` call arguably stays in village
- **Legacy position functions** — `_get_next_farmer_position()` (line 1092) and `_get_next_baker_position()` (line 1102) appear unused. Confirm no external callers before deleting
