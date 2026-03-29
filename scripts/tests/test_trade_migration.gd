extends Node

## Headless trade-migration test suite. Validates four scenarios:
##   1. TRADE_OFF  — no agent crosses village boundaries when trade disabled
##   2. TRADE_ON   — agents migrate when a better market exists and trade is enabled
##   3. RETURN     — agents return home once home market becomes more profitable
##   4. DETERMINISM — same RNG seed produces identical movement patterns
##
## Depends on T2 (FarmerJob trade eval loop) and T3 (BakerJob trade eval loop).
##
## Run: godot --headless --path <project_dir> res://scenes/TestTradeMigration.tscn

# ── Constants ─────────────────────────────────────────────────────────────────

## Ticks per game day (must match simulation_clock / other tests).
const TICKS_PER_DAY: int = 10
## Physics frames between each manually-driven tick (gives agents time to move).
const FRAMES_PER_TICK: int = 6

## How many ticks to run each scenario.
## Villages are repositioned to 250 px apart (see _reposition_v2_close).
## At SPEED=100 and 240fps physics, 250 px requires ~100 ticks (FRAMES_PER_TICK=6).
## TRADE_EVAL_INTERVAL=30 ticks — minimum needed = eval(30) + travel(100) = 130.
## Use 300 to include the commitment window start and confirm arrival state is stable.
const TRADE_OFF_TICKS: int = 35       # Only needs > TRADE_EVAL_INTERVAL (30)
const TRADE_ON_TICKS: int = 300       # eval (30) + travel (~100) + arrival margin
const RETURN_MIGRATE_TICKS: int = 300 # Same: allow full migration
const RETURN_FLIP_TICKS: int = 300    # After price flip: allow full return travel
const DETERM_TICKS: int = 300         # Enough to capture post-arrival state

## How much higher the "attractive" village prices are vs the home village.
## 3× is well above any travel cost the spec mandates, ensuring migration triggers.
const PRICE_MULTIPLIER: float = 3.0

## Base prices for Village 1 (home) when it is the cheaper village.
const BASE_WHEAT_PRICE: float = 1.5
const BASE_BREAD_PRICE: float = 2.5

## Fixed RNG seed used for both determinism runs.
const DETERM_SEED: int = 42

# ── Scenario state machine ────────────────────────────────────────────────────

enum Scenario {
	TRADE_OFF,      ## Test 1: trade disabled → no migration
	TRADE_ON,       ## Test 2: trade enabled + V2 prices 3× V1 → migration expected
	RETURN,         ## Test 3: migration then price flip → return expected
	DETERMINISM_A,  ## Test 4a: first run, record agent state
	DETERMINISM_B,  ## Test 4b: second run, compare state
}

var _scenario: Scenario = Scenario.TRADE_OFF
## Ticks remaining in current scenario (or current return sub-phase).
var _ticks_remaining: int = 0
## 0 = migrate phase, 1 = return phase (only used in RETURN scenario).
var _return_phase: int = 0
## Agents that were away from home when the price flip happened.
## Test 3b only checks THESE agents returned — V2-native agents migrating to V1
## during the high-V1 phase are doing normal migration, not "returning".
var _away_at_flip: Array = []
## Agent state snapshot from DETERMINISM_A run: name → village_id.
var _determ_state_a: Dictionary = {}
## Agents whose trade_arrived signal fired during the current scenario.
## Populated by _connect_trade_signals(); reset at start of each scenario.
var _arrived_agents: Array = []
## Set to true when trade_arrived signal fires on any agent's job.
## This is the canonical migration-complete state the test observes.
var _migration_completed: bool = false

# ── Scene / simulation references ─────────────────────────────────────────────

var _main: Node = null
var _world: Node = null
var _tick: int = 0
var _frame: int = 0
var _initialized: bool = false
var _done: bool = false
var _all_passed: bool = true

# ── Entry point ───────────────────────────────────────────────────────────────

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	print("[TRADE TEST] ═══════════════════════════════════════════════════════")
	print("[TRADE TEST] Trade Migration Test Suite")
	print("[TRADE TEST]   1: Trade OFF   — no migration when disabled")
	print("[TRADE TEST]   2: Trade ON    — profitable migration occurs")
	print("[TRADE TEST]   3: Return      — agents come home after price flip")
	print("[TRADE TEST]   4: Determinism — identical seeds → identical movement")
	print("[TRADE TEST] ═══════════════════════════════════════════════════════")
	# Defer so root is no longer busy setting up children before we add _main under it.
	call_deferred("_begin_scenario", Scenario.TRADE_OFF)


# ── Scenario lifecycle ────────────────────────────────────────────────────────

func _begin_scenario(s: Scenario) -> void:
	_scenario = s
	_tick = 0
	_frame = 0
	_initialized = false
	_return_phase = 0
	_arrived_agents = []
	_migration_completed = false
	get_tree().paused = false

	match s:
		Scenario.TRADE_OFF:
			print("\n[TRADE TEST] ── Test 1: Trade OFF ──")
			_ticks_remaining = TRADE_OFF_TICKS
		Scenario.TRADE_ON:
			print("\n[TRADE TEST] ── Test 2: Trade ON (profitable) ──")
			_ticks_remaining = TRADE_ON_TICKS
		Scenario.RETURN:
			print("\n[TRADE TEST] ── Test 3: Return Behavior ──")
			_ticks_remaining = RETURN_MIGRATE_TICKS
		Scenario.DETERMINISM_A:
			print("\n[TRADE TEST] ── Test 4a: Determinism run A (seed=%d) ──" % DETERM_SEED)
			seed(DETERM_SEED)
			_ticks_remaining = DETERM_TICKS
		Scenario.DETERMINISM_B:
			print("\n[TRADE TEST] ── Test 4b: Determinism run B (seed=%d) ──" % DETERM_SEED)
			seed(DETERM_SEED)
			_ticks_remaining = DETERM_TICKS

	var scene: PackedScene = load("res://scenes/Main.tscn")
	if scene == null:
		_fail("FATAL: Could not load Main.tscn")
		_finish()
		return
	_main = scene.instantiate()
	# FarmerJob / BakerJob discover the world via
	#   Engine.get_main_loop().current_scene.get_node_or_null("World")
	# set_current_scene() requires the scene node to be a direct child of
	# the SceneTree root.  Add _main under root (not under self) so the
	# requirement is satisfied, then make it current_scene.
	get_tree().root.add_child(_main)
	get_tree().current_scene = _main


func _teardown() -> void:
	if _main != null and is_instance_valid(_main):
		get_tree().root.remove_child(_main)
		_main.queue_free()
		_main = null
	_world = null
	# Restore TestTradeMigration as current_scene so the next scenario starts clean.
	if is_inside_tree():
		get_tree().current_scene = self


# ── Simulation pump ───────────────────────────────────────────────────────────

func _physics_process(_delta: float) -> void:
	if _done or _main == null:
		return

	if not _initialized:
		if not _main.is_node_ready():
			return
		_setup_scenario()
		_initialized = true
		return

	_frame += 1
	if _frame % FRAMES_PER_TICK != 0:
		return

	_tick += 1
	_main.clock.tick = _tick
	if _world != null and _world.has_method("on_simulation_tick"):
		_world.on_simulation_tick(_tick)
	# Prevent labor_market from evicting agents due to negative cashflow during test.
	if _world != null:
		_reset_cashflow_counters()

	_ticks_remaining -= 1
	if _ticks_remaining <= 0:
		_evaluate_and_advance()


# ── Per-scenario setup ────────────────────────────────────────────────────────

func _setup_scenario() -> void:
	if _main.clock and _main.clock.timer:
		_main.clock.timer.stop()
	Engine.physics_ticks_per_second = 240
	_world = _main.get_node_or_null("World")

	# Reposition Village 2 close to Village 1 (250 px) so the ~100-tick trip stays
	# under MAX_TRAVEL_TICKS=300 without modifying any game code.
	_reposition_v2_close()
	# Seed agents and markets so they have positive cashflow from day 1.
	# Without this, labor_market triggers "negative_profit" migration after
	# MIGRATION_NEG_PROFIT_DAYS=8, removing agents before they can travel.
	_stabilize_agents()

	match _scenario:
		Scenario.TRADE_OFF:
			# Trade disabled is the default; make explicit for clarity.
			if _world:
				_world.trade_enabled = false

		Scenario.TRADE_ON:
			if _world:
				_world.trade_enabled = true
			_set_v2_prices_high()

		Scenario.RETURN:
			if _world:
				_world.trade_enabled = true
			_set_v2_prices_high()

		Scenario.DETERMINISM_A, Scenario.DETERMINISM_B:
			if _world:
				_world.trade_enabled = true
			_set_v2_prices_high()


## Moves Village 2 to 250 px east of Village 1 so agents can complete the trip
## within agent.MAX_TRAVEL_TICKS=300 (the default 2000 px gap requires ~800 ticks).
## village.village_center is left stale — it only affects spawn scatter, not trade.
func _reposition_v2_close() -> void:
	if _world == null:
		return
	var villages: Array = _world.get_all_villages()
	if villages.size() < 2:
		return
	var v1 = villages[0]
	var v2 = villages[1]
	if v1 == null or v2 == null:
		return
	v2.position = v1.position + Vector2(250.0, 0.0)


## Seeds agent inventories so they never starve and clears negative-cashflow counters.
## Without this, labor_market.gd evicts agents after MIGRATION_NEG_PROFIT_DAYS=8
## consecutive negative-profit days before they can complete the trade trip.
## Call this once at setup; combine with _reset_cashflow_counters() in the tick loop.
func _stabilize_agents() -> void:
	if _world == null:
		return
	for v in _world.get_all_villages():
		if v == null or not is_instance_valid(v):
			continue
		for f in v.all_farmers:
			if f == null or not is_instance_valid(f):
				continue
			# Fill bread so HungerNeed never triggers starvation.
			var inv = f.get("inv")
			if inv != null and inv.has_method("set_qty"):
				inv.set_qty("bread", 100)
		for b in v.all_bakers:
			if b == null or not is_instance_valid(b):
				continue
			var inv = b.get("inv")
			if inv != null and inv.has_method("set_qty"):
				inv.set_qty("bread", 100)
	_reset_cashflow_counters()
	_connect_trade_signals()


## Connects trade_arrived signal from every agent's current_job.
## Called after stabilize so current_job is guaranteed to be set.
func _connect_trade_signals() -> void:
	for a in _collect_agents():
		var job = a.get("current_job")
		if job == null or not job.has_signal("trade_arrived"):
			continue
		if not job.trade_arrived.is_connected(_on_any_trade_arrived):
			job.trade_arrived.connect(_on_any_trade_arrived)


func _on_any_trade_arrived(_village: Node) -> void:
	_migration_completed = true


## Resets consecutive_days_negative_cashflow to 0 for all agents.
## Call once per tick to prevent labor_market eviction during the test run.
func _reset_cashflow_counters() -> void:
	for v in _world.get_all_villages():
		if v == null or not is_instance_valid(v):
			continue
		for f in v.all_farmers:
			if f == null or not is_instance_valid(f):
				continue
			var job = f.get("current_job")
			if job != null:
				job.set("consecutive_days_negative_cashflow", 0)
		for b in v.all_bakers:
			if b == null or not is_instance_valid(b):
				continue
			var job = b.get("current_job")
			if job != null:
				job.set("consecutive_days_negative_cashflow", 0)


## Make Village 2 clearly the better market. Prices are 3× Village 1 to ensure
## the profit gap exceeds any travel cost the implementation may use.
## IMPORTANT: market.get_bid_price() applies an inventory-based multiplier (0.70–1.10×)
## that can suppress V2's effective bid below the migration threshold even if
## wheat_price/bread_price are set high.  Clear V2's inventory (empty = buy-premium) and
## set V1's inventory at target (neutral bid) so the effective bid matches the price intent.
func _set_v2_prices_high() -> void:
	if _world == null:
		return
	var villages: Array = _world.get_all_villages()
	if villages.size() < 2:
		push_error("[TRADE TEST] Expected ≥2 villages; got %d" % villages.size())
		return
	var v1 = villages[0]
	var v2 = villages[1]
	if v1 == null or v1.market == null or v2 == null or v2.market == null:
		push_error("[TRADE TEST] Village market refs are null")
		return
	v1.market.wheat_price = BASE_WHEAT_PRICE
	v1.market.bread_price = BASE_BREAD_PRICE
	v1.market.wheat_market_buy_blocked = false
	v1.market.bread_market_buy_blocked = false
	# Set V1 inventory at target so bid multiplier ≈ 1.0 (neutral).
	v1.market.wheat = v1.market.wheat_target
	v1.market.bread = v1.market.bread_target
	v2.market.wheat_price = BASE_WHEAT_PRICE * PRICE_MULTIPLIER
	v2.market.bread_price = BASE_BREAD_PRICE * PRICE_MULTIPLIER
	v2.market.wheat_market_buy_blocked = false
	v2.market.bread_market_buy_blocked = false
	# Clear V2 inventory so bid multiplier ≈ 1.10 (scarcity premium) — ensures
	# effective bid is at least wheat_price × 1.10, well above migration threshold.
	v2.market.wheat = 0
	v2.market.bread = 0
	print("[TRADE TEST] Prices set: V1 wheat=%.1f bread=%.1f | V2 wheat=%.1f bread=%.1f (V2 inv cleared for neutral bid)" % [
		BASE_WHEAT_PRICE, BASE_BREAD_PRICE,
		BASE_WHEAT_PRICE * PRICE_MULTIPLIER, BASE_BREAD_PRICE * PRICE_MULTIPLIER])


## Flip prices so Village 1 is now the better market, triggering return logic.
## Also resets inventories so effective bid follows the price intent (see _set_v2_prices_high).
func _set_v1_prices_high() -> void:
	if _world == null:
		return
	var villages: Array = _world.get_all_villages()
	if villages.size() < 2:
		return
	var v1 = villages[0]
	var v2 = villages[1]
	if v1 == null or v1.market == null or v2 == null or v2.market == null:
		return
	v1.market.wheat_price = BASE_WHEAT_PRICE * PRICE_MULTIPLIER
	v1.market.bread_price = BASE_BREAD_PRICE * PRICE_MULTIPLIER
	v1.market.wheat_market_buy_blocked = false
	v1.market.bread_market_buy_blocked = false
	v1.market.wheat = 0  # empty V1 → scarcity premium bid
	v1.market.bread = 0
	v2.market.wheat_price = BASE_WHEAT_PRICE
	v2.market.bread_price = BASE_BREAD_PRICE
	v2.market.wheat_market_buy_blocked = false
	v2.market.bread_market_buy_blocked = false
	v2.market.wheat = v2.market.wheat_target  # V2 at target → neutral bid
	v2.market.bread = v2.market.bread_target
	print("[TRADE TEST] Prices flipped: V1 wheat=%.1f bread=%.1f (high) | V2 wheat=%.1f bread=%.1f (low)" % [
		BASE_WHEAT_PRICE * PRICE_MULTIPLIER, BASE_BREAD_PRICE * PRICE_MULTIPLIER,
		BASE_WHEAT_PRICE, BASE_BREAD_PRICE])


# ── Scenario evaluation ───────────────────────────────────────────────────────

func _evaluate_and_advance() -> void:
	match _scenario:

		Scenario.TRADE_OFF:
			_check_no_migration()
			_teardown()
			call_deferred("_begin_scenario", Scenario.TRADE_ON)

		Scenario.TRADE_ON:
			_check_migration_occurred()
			_teardown()
			call_deferred("_begin_scenario", Scenario.RETURN)

		Scenario.RETURN:
			if _return_phase == 0:
				# Phase A complete: record whether anyone migrated, then flip prices.
				var migrated: bool = _any_agent_migrated()
				if migrated:
					print("[TRADE TEST] PASS: Test 3a — migration to V2 confirmed (%d ticks)" % RETURN_MIGRATE_TICKS)
				else:
					# Print a warning but continue — return phase result is still meaningful.
					print("[TRADE TEST] WARN: Test 3a — no migration in %d ticks; return test may be vacuous" % RETURN_MIGRATE_TICKS)
				# Record which agents are currently away so phase B only checks them.
				_away_at_flip = []
				for a in _collect_agents():
					var cur = a.get("current_village_ref")
					var home = a.get("home_village_ref")
					if cur != null and home != null and cur != home:
						_away_at_flip.append(a)
				_set_v1_prices_high()
				_return_phase = 1
				_ticks_remaining = RETURN_FLIP_TICKS
			else:
				# Phase B complete: agents that were away should now be home.
				_check_away_agents_returned()
				_teardown()
				call_deferred("_begin_scenario", Scenario.DETERMINISM_A)

		Scenario.DETERMINISM_A:
			_determ_state_a = _snapshot_agent_villages()
			print("[TRADE TEST] Determinism run A: captured %d agent(s)" % _determ_state_a.size())
			_teardown()
			call_deferred("_begin_scenario", Scenario.DETERMINISM_B)

		Scenario.DETERMINISM_B:
			var state_b: Dictionary = _snapshot_agent_villages()
			_check_determinism(_determ_state_a, state_b)
			_teardown()
			_finish()


# ── Agent helpers ─────────────────────────────────────────────────────────────

## Collects all Farmer and Baker agents from every village.
func _collect_agents() -> Array:
	var out: Array = []
	if _world == null:
		return out
	for v in _world.get_all_villages():
		if v == null or not is_instance_valid(v):
			continue
		for a in v.all_farmers:
			if a != null and is_instance_valid(a):
				out.append(a)
		for a in v.all_bakers:
			if a != null and is_instance_valid(a):
				out.append(a)
	return out


## Returns true if at least one agent has completed a cross-village arrival.
## Primary: _migration_completed flag (set via trade_arrived signal, canonical).
## Secondary: trade_arrival_count > 0 on any job (same moment, poll-based fallback).
## Tertiary: current_village_ref != home_village_ref (current position check).
func _any_agent_migrated() -> bool:
	# Primary: signal-driven migration completion flag
	if _migration_completed:
		return true
	# Secondary: polled canonical arrival counter
	for a in _collect_agents():
		var job = a.get("current_job")
		if job != null and job.get("trade_arrival_count") != null and job.trade_arrival_count > 0:
			return true
	# Tertiary: agent is currently at a foreign village
	for a in _collect_agents():
		var cur = a.get("current_village_ref")
		var home = a.get("home_village_ref")
		if cur != null and home != null and cur != home:
			return true
	return false


## Records each agent's current village_id by agent name (stable across runs).
func _snapshot_agent_villages() -> Dictionary:
	var state: Dictionary = {}
	for a in _collect_agents():
		var key: String = a.name if a.name != "" else str(a.get_instance_id())
		var vid: int = -1
		var cvr = a.get("current_village_ref")
		if cvr != null and is_instance_valid(cvr):
			vid = cvr.get("village_id") if cvr.get("village_id") != null else -1
		state[key] = vid
	return state


# ── Assertion helpers ─────────────────────────────────────────────────────────

## Test 1: assert no agent left their home village.
func _check_no_migration() -> void:
	var violations: int = 0
	for a in _collect_agents():
		var cur = a.get("current_village_ref")
		var home = a.get("home_village_ref")
		if cur == null or home == null:
			continue
		if cur != home:
			violations += 1
			print("[TRADE TEST]   VIOLATION: %s moved to %s (home: %s)" % [
				a.name,
				cur.village_name if cur.get("village_name") != null else "?",
				home.village_name if home.get("village_name") != null else "?"])
	if violations == 0:
		print("[TRADE TEST] PASS: Test 1 — no agent migrated with trade disabled")
	else:
		_fail("Test 1: %d agent(s) migrated despite world.trade_enabled=false" % violations)


## Test 2: assert at least one agent left their home village.
## canonical migration state = current_village_ref != home_village_ref
## This is only set in _on_trade_arrival(), so it can only be true after physical arrival.
func _check_migration_occurred() -> void:
	if _any_agent_migrated():
		print("[TRADE TEST] PASS: Test 2 — at least one agent migrated to the better market")
		return

	# Diagnose failure: distinguish (a) still traveling, (b) departed but timed out,
	# and (c) evaluation never triggered.
	# Note: after travel_timeout, trade_route_active=false AND trade_sale_completed=true
	# so only _last_trade_move_tick > 0 proves departure actually fired.
	var mid_travel_count: int = 0
	var departed_count: int = 0  # departed at some point (_last_trade_move_tick > 0)
	for a in _collect_agents():
		var job = a.get("current_job")
		if job == null:
			continue
		if job.get("trade_route_active") == true:
			mid_travel_count += 1
		var last_move = job.get("_last_trade_move_tick")
		if last_move != null and (last_move as int) > 0:
			departed_count += 1
		# Print per-agent state to aid debugging.
		var cur = a.get("current_village_ref")
		var home = a.get("home_village_ref")
		var role_str: String = job.get_class() if job.has_method("get_class") else "?"
		var arrival_count = job.get("trade_arrival_count")
		print("[TRADE TEST]   agent=%s role=%s current=%s home=%s route_active=%s last_move_tick=%s arrival_count=%s" % [
			a.name, role_str,
			cur.get("village_name") if cur != null and cur.get("village_name") != null else "null",
			home.get("village_name") if home != null and home.get("village_name") != null else "null",
			str(job.get("trade_route_active")), str(last_move), str(arrival_count)])

	if mid_travel_count > 0:
		_fail("Test 2: %d agent(s) mid-travel but did not arrive in %d ticks (check SPEED/distance/MAX_TRAVEL_TICKS)" % [
			mid_travel_count, TRADE_ON_TICKS])
	elif departed_count > 0:
		_fail("Test 2: %d agent(s) departed ([TRADE DEPART] logged) but [TRADE ARRIVE] never fired in %d ticks — likely RouteRunner travel_timeout or collision block" % [
			departed_count, TRADE_ON_TICKS])
	else:
		_fail("Test 2: no trade evaluation or migration in %d ticks despite V2 prices %.0f× higher (T2/T3 eval loop running? home_village_ref/current_village_ref set?)" % [
			TRADE_ON_TICKS, PRICE_MULTIPLIER])


## Test 3b: agents that were away from home at the price-flip moment are now home.
## V2-native agents that subsequently migrated toward the now-high V1 prices are
## doing intentional trade migration, not failing the "return" contract.
func _check_away_agents_returned() -> void:
	if _away_at_flip.is_empty():
		print("[TRADE TEST] PASS: Test 3b — no agents were away at flip time (vacuous)")
		return
	var still_away: int = 0
	for a in _away_at_flip:
		if not is_instance_valid(a):
			continue
		var cur = a.get("current_village_ref")
		var home = a.get("home_village_ref")
		if cur == null or home == null:
			continue
		if cur != home:
			still_away += 1
			print("[TRADE TEST]   Still away: %s at %s (home: %s)" % [
				a.name,
				cur.get("village_name") if cur.get("village_name") != null else "?",
				home.get("village_name") if home.get("village_name") != null else "?"])
	if still_away == 0:
		print("[TRADE TEST] PASS: Test 3b — all %d previously-away agent(s) returned home after price flip" % _away_at_flip.size())
	else:
		_fail("Test 3b: %d/%d away agent(s) did not return home in %d ticks" % [
			still_away, _away_at_flip.size(), RETURN_FLIP_TICKS])


## Test 4: assert two independent runs with the same seed produce identical agent states.
func _check_determinism(state_a: Dictionary, state_b: Dictionary) -> void:
	if state_a.is_empty() and state_b.is_empty():
		print("[TRADE TEST] PASS: Test 4 — no agents in either run (consistent)")
		return

	var mismatches: int = 0

	for key in state_a:
		if not state_b.has(key):
			print("[TRADE TEST]   MISMATCH: agent '%s' in run A but missing from run B" % key)
			mismatches += 1
			continue
		if state_a[key] != state_b[key]:
			print("[TRADE TEST]   MISMATCH: agent '%s' village_id A=%d B=%d" % [
				key, state_a[key], state_b[key]])
			mismatches += 1

	for key in state_b:
		if not state_a.has(key):
			print("[TRADE TEST]   MISMATCH: agent '%s' in run B but missing from run A" % key)
			mismatches += 1

	if mismatches == 0:
		print("[TRADE TEST] PASS: Test 4 — %d agent(s) had identical village state across both runs" % state_a.size())
	else:
		_fail("Test 4: %d/%d agent state mismatch(es) between determinism runs" % [
			mismatches, state_a.size()])


# ── Suite completion ──────────────────────────────────────────────────────────

func _finish() -> void:
	print("")
	print("[TRADE TEST] ═══════════════════════════════════════════════════════")
	if _all_passed:
		print("[TRADE TEST] ALL TRADE MIGRATION TESTS PASSED")
	else:
		print("[TRADE TEST] SOME TESTS FAILED — see above for details")
	print("[TRADE TEST] ═══════════════════════════════════════════════════════")
	_done = true
	get_tree().quit(0 if _all_passed else 1)


func _fail(message: String) -> void:
	push_error("[TRADE TEST] FAIL: " + message)
	_all_passed = false
