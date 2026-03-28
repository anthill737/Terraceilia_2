extends Node

## Headless economy invariant validation: pumps Main.tscn like gameplay and
## asserts simulation state stays consistent (no negative balances, NaNs, etc.).
##
## Default: three RNG seeds in one process (42, 99999, 1337).
##
## Run: godot --headless --path <project> res://scenes/TestEconomy.tscn
##
## Optional args (after -- ):
##   --min-survival-days N   Fail if town goes extinct before calendar day N (0 = off).
##   --max-days N            Cap each seed run at N days (default 60).
##   --seeds A,B,C           Override seed list (comma-separated ints).

const TICKS_PER_DAY: int = 10
const FRAMES_PER_TICK: int = 6
const DEFAULT_MAX_DAYS: int = 60
const DEFAULT_SEEDS: Array[int] = [42, 99999, 1337]

var _max_days: int = DEFAULT_MAX_DAYS
var _seeds: Array[int] = DEFAULT_SEEDS.duplicate()
var _min_survival_days: int = 0

var _seed_run_index: int = 0
var _current_seed: int = 0

var _main: Node = null
var _tick: int = 0
var _frame: int = 0
var _initialized: bool = false
var _suite_done: bool = false


func _ready() -> void:
	# Main sets get_tree().paused = true on extinction; we must keep pumping between seeds.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_parse_user_args()
	print("[ECON TEST] ══════════════════════════════════════════════════════")
	print("[ECON TEST] Economy invariant suite | seeds=%s | max_days=%d | min_survival_days=%d" % [
		_seeds, _max_days, _min_survival_days])
	print("[ECON TEST] ══════════════════════════════════════════════════════")
	_start_seed_run(0)


func _start_seed_run(index: int) -> void:
	_seed_run_index = index
	if _seed_run_index >= _seeds.size():
		print("[ECON TEST] ══════════════════════════════════════════════════════")
		print("[ECON TEST] SUITE: PASS (all %d seeds OK)" % _seeds.size())
		print("[ECON TEST] ══════════════════════════════════════════════════════")
		_suite_done = true
		get_tree().quit(0)
		return

	_current_seed = _seeds[_seed_run_index]
	seed(_current_seed)
	_tick = 0
	_frame = 0
	_initialized = false
	get_tree().paused = false

	var scene: PackedScene = load("res://scenes/Main.tscn")
	if scene == null:
		push_error("[ECON TEST] FATAL: Could not load Main.tscn")
		get_tree().quit(1)
		return
	_main = scene.instantiate()
	add_child(_main)
	print("[ECON TEST] ── Seed run %d/%d (rng_seed=%d) ──" % [
		_seed_run_index + 1, _seeds.size(), _current_seed])


func _teardown_main() -> void:
	if _main != null and is_instance_valid(_main):
		remove_child(_main)
		_main.queue_free()
		_main = null


func _physics_process(_delta: float) -> void:
	if _suite_done:
		return
	if _main == null:
		return
	if not _initialized:
		# add_child(Main) from _physics_process: Main._ready may not have run yet.
		if not _main.is_node_ready():
			return
		if _main.clock and _main.clock.timer:
			_main.clock.timer.stop()
		Engine.physics_ticks_per_second = 240
		_initialized = true
		print("[ECON TEST] Clock stopped, physics=240/s, running...")
		return

	_frame += 1
	if _frame % FRAMES_PER_TICK != 0:
		return

	_tick += 1
	_main.clock.tick = _tick
	_main._on_tick(_tick)

	if not _verify_invariants(_tick):
		_suite_done = true
		get_tree().quit(1)
		return

	var day_index: int = _main.calendar.day_index if _main.calendar else _tick / TICKS_PER_DAY
	var max_ticks: int = _max_days * TICKS_PER_DAY
	var sim_failed: bool = _main.get("sim_failed") == true

	if sim_failed or _tick >= max_ticks:
		if not _verify_invariants(_tick):
			_suite_done = true
			get_tree().quit(1)
			return

		var reason: String = "sim_failed" if sim_failed else "max_ticks"
		print("[ECON TEST] Seed %d stopped: %s (calendar_day=%d tick=%d)" % [
			_current_seed, reason, day_index, _tick])

		if not _survival_requirement_met(sim_failed, day_index):
			push_error("[ECON TEST] FAIL: survival requirement not met (need min day %d, sim_failed=%s, day=%d)" % [
				_min_survival_days, sim_failed, day_index])
			_suite_done = true
			get_tree().quit(1)
			return

		print("[ECON TEST] Seed %d: PASS (invariants + survival OK)" % _current_seed)
		_teardown_main()
		# queue_free() is deferred; spawn next Main on idle so the tree is clean.
		call_deferred("_start_seed_run", _seed_run_index + 1)


func _survival_requirement_met(sim_failed: bool, day_index: int) -> bool:
	if _min_survival_days <= 0:
		return true
	if sim_failed:
		return day_index >= _min_survival_days
	var pm = _main.pop_mgr as PopulationManager
	var pop_n: int = pm.count() if pm else 0
	return pop_n > 0 and day_index >= _min_survival_days


func _parse_user_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < args.size():
		var a: String = args[i]
		if a.begins_with("--min-survival-days="):
			_min_survival_days = int(a.get_slice("=", 1))
		elif a == "--min-survival-days" and i + 1 < args.size():
			_min_survival_days = int(args[i + 1])
			i += 1
		elif a.begins_with("--max-days="):
			_max_days = maxi(1, int(a.get_slice("=", 1)))
		elif a == "--max-days" and i + 1 < args.size():
			_max_days = maxi(1, int(args[i + 1]))
			i += 1
		elif a.begins_with("--seeds="):
			_parse_seeds_csv(a.substr("--seeds=".length()))
		elif a == "--seeds" and i + 1 < args.size():
			_parse_seeds_csv(args[i + 1])
			i += 1
		i += 1


func _parse_seeds_csv(tail: String) -> void:
	_seeds.clear()
	for part in tail.split(","):
		var s: String = part.strip_edges()
		if s.is_valid_int():
			_seeds.append(int(s))
	if _seeds.is_empty():
		_seeds = DEFAULT_SEEDS.duplicate()


func _verify_invariants(tick: int) -> bool:
	var m = _main.market as Market
	if m == null or not is_instance_valid(m):
		push_error("[ECON TEST] tick=%d: market missing or invalid" % tick)
		return false

	if not _check_market(m, tick):
		return false

	var pops: Array = _collect_pops()
	for agent in pops:
		if agent == null or not is_instance_valid(agent):
			push_error("[ECON TEST] tick=%d: stale agent ref in population arrays" % tick)
			return false
		if not _check_agent(agent as Node, tick):
			return false

	return true


func _check_market(m: Market, tick: int) -> bool:
	if is_nan(m.money) or m.money < -0.001:
		push_error("[ECON TEST] tick=%d: market.money=%s" % [tick, m.money])
		return false
	if m.seeds < 0 or m.wheat < 0 or m.bread < 0:
		push_error("[ECON TEST] tick=%d: negative market inv seeds=%d wheat=%d bread=%d" % [
			tick, m.seeds, m.wheat, m.bread])
		return false
	if m.wheat > m.wheat_capacity or m.bread > m.bread_capacity:
		push_error("[ECON TEST] tick=%d: market over capacity wheat=%d/%d bread=%d/%d" % [
			tick, m.wheat, m.wheat_capacity, m.bread, m.bread_capacity])
		return false
	if is_nan(m.wheat_price) or is_nan(m.bread_price):
		push_error("[ECON TEST] tick=%d: NaN price wheat=%s bread=%s" % [tick, m.wheat_price, m.bread_price])
		return false
	if m.wheat_price < m.WHEAT_PRICE_FLOOR - 0.001 or m.wheat_price > m.WHEAT_PRICE_CEILING + 0.001:
		push_error("[ECON TEST] tick=%d: wheat_price out of band %.4f" % [tick, m.wheat_price])
		return false
	if m.bread_price < m.BREAD_PRICE_FLOOR - 0.001 or m.bread_price > m.BREAD_PRICE_CEILING + 0.001:
		push_error("[ECON TEST] tick=%d: bread_price out of band %.4f" % [tick, m.bread_price])
		return false
	return true


func _check_agent(agent: Node, tick: int) -> bool:
	var w: Wallet = agent.get_node_or_null("Wallet") as Wallet
	if w == null:
		push_error("[ECON TEST] tick=%d: %s no Wallet" % [tick, agent.name])
		return false
	if is_nan(w.money) or w.money < -0.001:
		push_error("[ECON TEST] tick=%d: %s wallet money=%s" % [tick, agent.name, w.money])
		return false

	var inv: Inventory = agent.get_node_or_null("Inventory") as Inventory
	if inv == null:
		push_error("[ECON TEST] tick=%d: %s no Inventory" % [tick, agent.name])
		return false
	for item in inv.items.keys():
		var q: Variant = inv.items[item]
		if int(q) < 0:
			push_error("[ECON TEST] tick=%d: %s negative %s=%s" % [tick, agent.name, item, q])
			return false

	var hunger: HungerNeed = agent.get_node_or_null("HungerNeed") as HungerNeed
	if hunger:
		if hunger.hunger_days < 0:
			push_error("[ECON TEST] tick=%d: %s hunger_days=%d" % [tick, agent.name, hunger.hunger_days])
			return false
		if hunger.hunger_days > hunger.hunger_max_days + 10:
			push_error("[ECON TEST] tick=%d: %s hunger_days absurd %d" % [tick, agent.name, hunger.hunger_days])
			return false
	return true


func _collect_pops() -> Array:
	var out: Array = []
	var pm = _main.pop_mgr as PopulationManager
	if pm == null:
		return out
	for x in pm.all_farmers:
		out.append(x)
	for x in pm.all_bakers:
		out.append(x)
	for x in pm.households:
		out.append(x)
	return out
