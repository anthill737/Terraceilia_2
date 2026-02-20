# TerraCelia — Architecture Notes

## Overview

TerraCelia is an agent-based economy simulation built in Godot 4. Agents (pops)
play one of three roles — **Farmer**, **Baker**, or **Household** — and interact
through a centralized Market. The simulation is tick-driven with a calendar
system that advances days and triggers daily economic cycles.

## Architecture: Agent + Components + Managers

All pops share a single **Agent** base class (`scripts/agent.gd`) backed by a
single scene (`scenes/Agent.tscn`). Role-specific behavior is provided by
swappable **Job** components, and global bookkeeping lives in **Manager** nodes
attached to Main.

### Scene Files

| Scene              | Purpose                                        |
|--------------------|------------------------------------------------|
| `scenes/Main.tscn` | Root scene — world layout, UI, initial agents  |
| `scenes/Agent.tscn`| Unified agent scene instantiated for all spawns |
| `scenes/Field.tscn`| Field plot placed in the world                 |

### Agent (`scripts/agent.gd`)

`CharacterBody2D` base class for every pop. Owns only:

- **Identity** — `person_id`, `person_name`, `life_events`, `log_event()`
- **Role** — `current_role`, `set_role(new_role)` for in-place switching
- **Component refs** — `wallet`, `inv`, `hunger`, `food_stockpile`,
  `route`, `inv_cap`, `prod_batch`, `profit`, `margin`, `throttle`,
  `food_reserve`, `cashflow`, `skills`, `visual_indicator`
- **Inspector** — `get_inspector_data() -> Dictionary`
- **Forwarding properties** — expose job-specific fields (`consecutive_days_negative_cashflow`,
  `switch_cooldown_days`, `training_days_remaining`, etc.) through the active
  `current_job` so external code never needs to know which job is active.
- **Click handling** — emits `pop_clicked` signal for inspector selection

Agent does **not** contain market logic, production logic, or hunger ticking.

### Job Components (`scripts/jobs/`)

Each is a `Node` that attaches to Agent as a child and provides role behavior.

| Script                   | Role       | Key Responsibilities                              |
|--------------------------|------------|---------------------------------------------------|
| `job_base.gd`            | (abstract) | Common interface: `activate()`, `deactivate()`, `set_tick()`, `on_day_changed()`, `_physics_process()`, `get_display_name()`, `get_inspector_data()` |
| `farmer_job.gd`          | Farmer     | Field tending, planting/harvesting, wheat selling, bread buying for food |
| `baker_job.gd`           | Baker      | Wheat buying, bread baking, bread selling, margin/profitability tracking |
| `household_job.gd`       | Household  | Bread buying, starvation/migration tracking, role-switch decision support |

#### Role Switching Flow

```
agent.set_role("Baker")
  → removes old job node + deactivate()
  → removes old Godot groups
  → creates new BakerJob, calls activate()
  → adds new Godot groups ("bakers", "agents")
  → updates sprite color
```

Identity (`person_id`, `person_name`, `life_events`, skills) is preserved.

### Shared Components (`scripts/components/`)

Reusable `Node` scripts attached as children of every Agent scene:

| Script                        | Purpose                                        |
|-------------------------------|------------------------------------------------|
| `wallet.gd`                   | Holds cash; `credit()`, `debit()` methods      |
| `inventory.gd`                | Dict-based item storage (`seeds`, `wheat`, `bread`) |
| `inventory_capacity.gd`       | Enforces max inventory per item                 |
| `hunger_need.gd`              | Hunger ticking, starvation, bread consumption   |
| `food_stockpile.gd`           | Food reserve tracking                           |
| `food_reserve.gd`             | Defensive bread buying for food security        |
| `route_runner.gd`             | Travel between locations (home → market → home) |
| `production_batch.gd`         | Batch production state (baker)                  |
| `production_profitability.gd` | Tracks cost/revenue to compute profit margins   |
| `margin_compression.gd`       | Detects margin squeeze (baker)                  |
| `inventory_throttle.gd`       | Throttles production based on unsold inventory  |
| `cashflow_tracker.gd`         | Per-pop rolling 7-day income/expense tracking   |
| `skill_set.gd`                | Tracks `skill_farmer`, `skill_baker` with diminishing-returns growth and cross-skill decay |
| `visual_indicator.gd`         | Wealth tier border rectangle above each agent   |

### Managers (`scripts/managers/`)

Global systems attached as children of the Main node:

| Script                        | Responsibility                                  |
|-------------------------------|-------------------------------------------------|
| `population_manager.gd`       | Pop arrays (`all_farmers`, `all_bakers`, `households`), cap enforcement (MAX_TOTAL_POP = 50), identity assignment, person-id counter |
| `field_manager.gd`            | Field arrays, cap enforcement (MAX_FIELDS = 10), field-to-farmer assignment map, field ticking |
| `economy_stats_manager.gd`    | Global rolling 7-day cashflow aggregation per role |

Main.gd uses **property forwarding** to expose manager data transparently:
```gdscript
var all_farmers: Array:
    get: return pop_mgr.all_farmers if pop_mgr else []
```
This allows all existing code to read/write these arrays without knowing about
the managers.

### Other Core Scripts

| Script                   | Responsibility                                       |
|--------------------------|------------------------------------------------------|
| `main.gd`                | Scene orchestrator — wires agents/managers/UI, spawn functions, inspector, economy HUD |
| `market.gd`              | Centralized market — wheat/bread inventory, pricing, hysteresis, `last_trade_result` dictionary with standardized reason codes |
| `labor_market.gd`        | Scarcity computation, role-switch requests, migration signals |
| `simulation_clock.gd`    | Tick counter and `on_tick` signal                    |
| `calendar.gd`            | Day counter derived from ticks, `day_changed` signal |
| `event_bus.gd`           | Global event/log bus                                 |
| `economy_audit.gd`       | Periodic economy snapshots for debugging             |
| `prosperity_meter.gd`    | Tracks settlement prosperity for growth decisions    |
| `field_plot.gd`          | Individual field: planting, growth, harvest states   |

### UI Scripts (`scripts/ui/`)

| Script                    | Purpose                                |
|---------------------------|----------------------------------------|
| `admin_menu.gd`           | Admin/debug menu                       |
| `placement_controller.gd` | Click-to-place entity placement        |
| `world_click_catcher.gd`  | Routes world clicks to placement logic |

## Key Design Decisions

1. **One scene, one script** — All agents use `Agent.tscn` + `agent.gd`.
   Role-specific behavior is injected via `set_role()` which adds a `JobBase`
   child node. No subclass scripts.

2. **In-place role switching** — When a Household converts to Farmer, the
   existing Agent node stays in the tree. Only the job component is swapped.
   Identity, life events, skills, and wallet all persist.

3. **Property forwarding** — Manager state is exposed on `main.gd` via
   computed properties that delegate to manager instances. This preserved
   backward compatibility with hundreds of existing references.

4. **Market return codes** — Every `buy_*`/`sell_*` function in `market.gd`
   populates `last_trade_result: Dictionary` with `qty`, `reason`, `item`,
   `price`, `market_wheat`, `market_bread`. Reason strings:
   `success`, `partial`, `blocked`, `empty`, `insufficient_funds`,
   `storage_full`, `walk_away`, `capped`, `zero_request`.

5. **Skills with diminishing returns** — `skill += base_gain * (1.0 - skill)`
   per day in current role. Productivity multiplier:
   `lerp(0.85, 1.25, skill)`. Cross-role decay: `skill -= 0.002 * skill`.

## Deleted Legacy Files

These files existed before the refactor and have been removed:

- `scripts/farmer.gd` — Old Farmer subclass (replaced by `agent.gd` + `farmer_job.gd`)
- `scripts/baker.gd` — Old Baker subclass (replaced by `agent.gd` + `baker_job.gd`)
- `scripts/household_agent.gd` — Old HouseholdAgent subclass (replaced by `agent.gd` + `household_job.gd`)
- `scripts/household.gd` — Earlier Household prototype (unused)
- `scripts/field.gd` — Earlier Field prototype (superseded by `field_plot.gd`)
- `scripts/simulation_runner.gd` — Stub (timing constants moved to `simulation_clock.gd`/`calendar.gd`)
- `scripts/market_shocks.gd` — Unused market shock system
- `scripts/components/food_need.gd` — Unused (superseded by `hunger_need.gd`)
- `scenes/Farmer.tscn` — Old scene (replaced by `Agent.tscn`)
- `scenes/Baker.tscn` — Old scene (replaced by `Agent.tscn`)
- `scenes/Household.tscn` — Old scene (replaced by `Agent.tscn`)

## Adding a New Role

1. Create `scripts/jobs/new_role_job.gd` extending `JobBase`
2. Implement `activate()`, `deactivate()`, `set_tick()`, `on_day_changed()`,
   `_physics_process()`, `get_display_name()`, `get_inspector_data()`
3. Register the role string in `Agent.set_role()` (add an `elif` branch)
4. Add any new components as children of `Agent.tscn` if needed
5. Update `PopulationManager`, `LaborMarket`, and `EconomyStatsManager`
   group names as needed
