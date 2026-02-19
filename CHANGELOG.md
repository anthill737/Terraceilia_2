# Terraceilia — Changelog

All notable changes to this project are documented here.

---

## [Unreleased] — 2026-02-18

### UI Revamp — Economy HUD Bar

Replaced the scrollable right-sidebar stat cards with a compact, always-visible economy HUD strip.

**`scenes/Main.tscn`**
- Removed `CardsScroll` container and all child stat cards (FarmerCard, BakerCard, HouseholdCard, MarketCard, ProsperityCard) along with every individual label node inside them.
- Removed `HSeparator1`–`HSeparator4` and `HSeparator_Prosperity`.
- Reduced `Sidebar` minimum width from 360 px to 280 px. The sidebar now contains only the Event Log (full height, no scrolling required for stats).

**`scripts/main.gd`**
- Added `eco_sim_label`, `eco_village_label`, `eco_market_label`, `eco_prosperity_label`, `eco_farmer_label`, `eco_baker_label` variables.
- Added `_current_speed: float` variable updated by `_on_speed_changed()`.
- Rewrote `get_ui_labels()` to only wire the event log and pop inspector — removed all card-path `get_node()` calls that would crash with the new scene.
- Added `_build_economy_bar()` — creates a dark, rounded `PanelContainer` anchored just below the BUILD toolbar spanning the full WorldSpacer width. Contains six colour-coded sections: **SIM · VILLAGE · MARKET · PROSPERITY · FARMER · BAKER**.
- Added `_add_eco_section()` helper — each section gets a small accent-coloured category title (9 pt) and a two-line content label (11 pt).
- Replaced `update_ui()` with a slim call to `_update_eco_bar()` + `update_inspector()`. Removed ~80 lines of per-label null-check update code.
- `_update_eco_bar()` populates each section every frame: Day/speed, population breakdown, market inventory + prices, prosperity score + inputs, baseline farmer stats, baseline baker stats.

---

### Pop Inspector UI

Added a click-to-select inspector panel so any pop can be examined in real time.

**`scripts/farmer.gd`, `scripts/baker.gd`, `scripts/household_agent.gd`**
- Added `signal pop_clicked(pop: Node)`.
- Added `_unhandled_input(event)` — detects left-click within a 15 px radius of `global_position` using `get_local_mouse_position()` and emits `pop_clicked(self)`. Calls `get_viewport().set_input_as_handled()`.
- Added `get_inspector_data() -> Dictionary` returning: `name`, `role`, `cash`, `hunger` (string), `starving`, `bread`, inventory-specific fields (`seeds`/`wheat`/`flour` as applicable), `survival`, `state`, `neg_cashflow_days`/`fail_streak`, training progress where relevant.

**`scripts/main.gd`**
- Added `selected_pop`, `pop_inspector_panel`, `pop_inspector_title`, `pop_inspector_body` variables.
- `get_ui_labels()` now fetches and wires the `PopInspector` panel, title label, body `RichTextLabel`, and close button.
- Connects `pop_clicked` for the static scene pops (farmer, baker, household_agent) and for every dynamically spawned pop in `spawn_farmer_at()`, `spawn_baker_at()`, `spawn_household_at()`.
- `update_ui()` calls `update_inspector()` every frame.
- `select_pop(pop)` sets `selected_pop` and triggers an update.
- `_on_inspector_close()` clears selection and hides the panel.
- `update_inspector()` checks `is_instance_valid(selected_pop)` before rendering; clears and hides the panel if the pop was freed.

**`scenes/Main.tscn`**
- Added `PopInspector` (`PanelContainer`) as a direct child of the `UI` CanvasLayer (offset: 10, 50, 275, 360; hidden by default).
- Children: `VBox` → `TitleRow` (`HBoxContainer`) → `PopInspectorTitle` (`Label`) + `PopInspectorClose` (`Button`); `VBox` → `PopInspectorBody` (`RichTextLabel`, bbcode enabled, min size 245×240).

---

### Live Total Population Counter

**`scripts/farmer.gd`** — `add_to_group("farmers")` in `_ready()`.  
**`scripts/baker.gd`** — `add_to_group("bakers")` in `_ready()`.  
**`scripts/household_agent.gd`** — `add_to_group("households")` in `_ready()`.  
**`scripts/main.gd`** — `update_ui()` reads group sizes via `get_nodes_in_group()` and formats `Pop: N (H:h F:f B:b)`.  
**`scenes/Main.tscn`** — Added `TotalPop` Label under ProsperityVBox (now removed with the card revamp; population display moved to the VILLAGE section of the eco bar).

---

### Hard Village Caps

**`scripts/main.gd`**
- Added `const MAX_FIELDS: int = 10` and `const MAX_TOTAL_POP: int = 50`.
- Added `get_total_population() -> int` (sum of households + all_farmers + all_bakers).
- `spawn_field_at()` blocks and logs `[LAND] Spawn blocked` when `all_field_nodes.size() >= MAX_FIELDS`; added `skip_auto_assign` parameter for atomic conversions.
- `spawn_farmer_at()`, `spawn_baker_at()`, `spawn_household_at()` each check `get_total_population() >= MAX_TOTAL_POP` at the top and return early with a `[POP] Spawn blocked` log.
- Emergency spawn path also guarded by `MAX_TOTAL_POP`.
- `_on_calendar_day_changed()` prints daily `[LAND STATUS]` and `[POP STATUS]` lines.

---

### Atomic Farmer Conversion (fix "no fields" ordering bug)

Fixed a race condition where a newly converted Farmer would tick before its Field was assigned, causing `[ERROR] Farmer has no fields assigned` spam.

**`scripts/main.gd` — `_perform_role_conversion()`**
- Rewritten as an atomic sequence: (1) check population cap, (2) check land cap, (3) call `spawn_field_at(..., skip_auto_assign: true)` to pre-create the field, (4) call `spawn_farmer_at(pos, pre_field)` so the field is assigned *before* `set_route_nodes` is called, (5) append farmer to tracking lists. If field spawn fails at any step, conversion is aborted and the agent reverts to Household.
- `spawn_farmer_at()` accepts an optional `initial_field_node` parameter and calls `add_field()` before `set_route_nodes`.

**`scripts/farmer.gd`**
- Added `_initialized: bool = false` flag; set to `true` in `add_field()`.
- `_rebuild_route()` no-ops the "lost all fields" warning when `_initialized == false`.
- Added `warned_no_field_today: bool = false`; set in `handle_field_arrival()` to throttle repeat warnings; reset in `on_day_changed()`.

---

### Startup Grace Period & Dead-Equilibrium Prevention

**`scripts/labor_market.gd`**
- Added local `const STARTUP_GRACE_DAYS` constant (mirrors SimulationRunner value, avoids cross-scope parse errors).
- Migration is suppressed during the grace period and if `ever_had_bread_supply == false`; fail streaks are reset when suppressed.
- `ever_had_bread_supply` flag is set true the first time any market bread supply is observed.

**`scripts/main.gd`**
- Emergency-spawn path: if `population == 0` AND economy is producing food AND `day > STARTUP_GRACE_DAYS`, a single Household is force-spawned to prevent dead equilibrium.
- `spawn_household()` no longer blocked by temporary bread scarcity or migration grace state; only `prosperity > SPAWN_THRESHOLD` and `population < MAX_POP` apply.
- Added `null` / `is_instance_valid` guards at the call site for `EconomyAudit.audit()`.

**`scripts/economy_audit.gd`**
- `audit()` checks each agent argument with `is_instance_valid()` before accessing properties; previously freed agents no longer crash the audit.

---

### Agent State Hardening (anti-stall, anti-deadlock)

**`scripts/farmer.gd`, `scripts/baker.gd`, `scripts/household_agent.gd`**

1. **Travel Timeout Safety** — `var travel_ticks: int` increments each tick while a `travel_id` is active. When `travel_ticks > MAX_TRAVEL_TICKS` (300), the route is cancelled, `travel_id` cleared, state reset to `IDLE`, and `[BUGFIX] Travel timeout reset` is logged.
2. **Market Block Fallback (hysteresis cooldown)** — When a SELL or BUY action is blocked by hysteresis, state transitions to `IDLE` with a short cooldown (5–15 ticks) instead of immediately re-dispatching to the market. Logs `[BUGFIX] Action blocked → cooldown`.
3. **Production Pause Safety** — If production is paused by hysteresis and there is no pending target, active route, or cooldown, state is forced to `IDLE` so `decision()` runs next tick.
4. **Idle State Guard** — In `_process` / tick loop: if `state == IDLE`, no active route, no cooldown, and hunger > 0 or production is possible, `decision()` is called unconditionally to prevent silent permanent idle.

**`scripts/main.gd`**
- After each `queue_free()` in migration paths, logs `[MIGRATE CONFIRM] <agent_name> removed` and ensures the agent is purged from all tracking arrays.

---

## [0.2.0] — 2026-01-15

### Equilibrium-Capable Market Refactor

Full details in `REFACTOR_SUMMARY.md`. Summary of changes:

**`scripts/market.gd`**
- Disabled `PRODUCER_HYSTERESIS_CONFIG` — `can_producer_sell()` and `can_producer_produce()` now always return `true`.
- Removed hard buy-blocking at upper band; replaced with smooth 10%-minimum taper in `get_max_buy_qty()`.
- Demand-confirmed pricing: prices only rise on days with `trades_today > 0`.
- Simplified clearing-price tracking; removed upper-band checks from statistics.
- Softened decay: wheat decay **disabled**, bread decay reduced to 0.5–1.5 %/day (only above upper band).
- Removed `DECAY_WINDOW_DAYS`, weekly cadence variables, and price-freeze logic.
- Added `market_shocks` reference and integration hooks.

**`scripts/field_plot.gd`**
- `harvest()` applies seasonal yield multiplier from `MarketShocks`.

**`scripts/components/food_stockpile.gd`**
- `needed_to_reach_target()` adds demand-shock bonus when a shock is active.

**`scripts/market_shocks.gd`** *(new)*
- Manages three bounded shock types:
  - **Seasonal yield** — sinusoidal ±10% wheat output over a 90-day cycle.
  - **Demand shocks** — 8% daily chance to add +1 bread need to 30% of consumers.
  - **Seed supply shocks** — 5% daily chance to cap seed availability at 50% for 3–7 days.
- All shocks affect mechanics (supply/demand), never set prices directly.

**`scripts/main.gd`**
- Creates and wires `MarketShocks` instance; connects `calendar.day_changed` → `shocks.set_day()`; binds to market, field plots, and food stockpiles.

---

## [0.1.0] — Initial Release

- Component-based agent architecture: Wallet, Inventory, HungerNeed, FoodStockpile, RouteRunner, InventoryCapacity, ProductionBatch, ProductionProfitability, FoodReserve, MarginCompression, InventoryThrottle.
- Farmer, Baker, Household agents with movement and economic decision-making.
- Market with dynamic wheat and bread pricing, hysteresis bands, and bid-based clearing.
- Calendar system with day-changed signals driving hunger depletion.
- EconomyAudit invariant checks.
- EventBus for decoupled logging.
- ProsperityMeter scoring wealth, food security, starvation pressure, and trade activity.
- LaborMarket occupational mobility: households can train as farmers or bakers; agents may migrate when fail streaks exceed threshold.
- AdminMenu for field assignment management.
- Initial UI: sidebar with agent stat cards and event log.
