class_name VillageSpawnService
extends Node

## VillageSpawnService — Phase 6 extraction from village.gd
##
## Owns the three async spawn operations (farmer, baker, household).
## Must be added as a child of the Village node before calling setup(),
## so that get_tree() / await process_frame work correctly.
##
## Shared helpers that are also used by labor conversion (_fixup_node_name,
## _assign_field_to_farmer, _assign_new_identity, _on_household_died) remain
## in Village.gd — this service calls them via _village.

# Village node set by setup().  Typed as Node to avoid circular class refs.
var _village: Node = null

# Agent PackedScene loaded once in setup().
var _agent_scene: PackedScene = null


# ── Setup ─────────────────────────────────────────────────────────────────────

func setup(village: Node) -> void:
	_village = village
	_load_agent_scene()


func _load_agent_scene() -> void:
	var path := "res://scenes/Agent.tscn"
	if ResourceLoader.exists(path):
		_agent_scene = load(path)
	else:
		push_error("VillageSpawnService: AgentScene not found at " + path)


# ── Public spawn API ──────────────────────────────────────────────────────────

func spawn_farmer_at(pos: Vector2, initial_field_node: Node2D = null) -> Node:
	if _agent_scene == null:
		if _village.event_bus:
			_village.event_bus.emit_log("[ERROR] Cannot spawn farmer: AgentScene not loaded")
		return null

	var total_pop: int = _village.get_total_population()
	if total_pop >= Tuning.i("town_size_limit", _village.pop_mgr.MAX_TOTAL_POP):
		var msg := "[POP] Spawn blocked — cap reached (%d/%d)" % [total_pop, Tuning.i("town_size_limit", _village.pop_mgr.MAX_TOTAL_POP)]
		print(msg)
		if _village.event_bus:
			_village.event_bus.emit_log(msg)
		return null

	var f: Agent = _agent_scene.instantiate() as Agent
	if f == null:
		push_error("AgentScene instantiate() returned null")
		return null
	f.name = "Farmer_%d" % _village.pop_mgr.next_farmer_id
	_village.pop_mgr.next_farmer_id += 1
	f.home_village_id = _village.village_id
	f.home_village_ref = _village
	f.current_village_ref = _village
	f.position = _village.to_local(pos)
	_village.add_child(f)

	_village._fixup_node_name(f, "Farmer")

	await get_tree().process_frame

	_village._assign_new_identity(f)

	f.market = _village.market
	f.event_bus = _village.event_bus
	f.econ_stats = _village.econ_stats
	f.set_role("Farmer")
	# Connect trade signals so this village is notified when the farmer arrives at or
	# returns to any village. Signals are defined on JobBase and owned by the job node;
	# Godot auto-disconnects when the job is freed (e.g., on role change or removal).
	if f.current_job:
		f.current_job.trade_arrived.connect(_village._on_agent_trade_arrived)
		f.current_job.trade_return_arrived.connect(_village._on_agent_trade_return_arrived)

	var f_hunger: HungerNeed = f.get_node("HungerNeed") as HungerNeed
	var f_inv: Inventory = f.get_node("Inventory") as Inventory
	if f_hunger and f_inv:
		f_hunger.bind(f.name, f_inv, _village.event_bus, _village.calendar)

	var f_reserve: FoodReserve = f.get_node("FoodReserve") as FoodReserve
	if f_reserve:
		f_reserve.bind(f_inv, f_hunger, _village.market, f.get_node("Wallet") as Wallet, _village.event_bus, f.name)

	var home := Node2D.new()
	home.name = f.name + "_Home"
	home.position = _village.to_local(pos)
	home.set_meta("village_id", _village.village_id)
	var home_marker := ColorRect.new()
	home_marker.name = "HomeMarker"
	home_marker.offset_left = -12.0
	home_marker.offset_top = -12.0
	home_marker.offset_right = 12.0
	home_marker.offset_bottom = 12.0
	home_marker.color = Color(0.2, 0.5, 1, 0.6)
	home.add_child(home_marker)
	_village.add_child(home)

	if initial_field_node != null and is_instance_valid(initial_field_node):
		_village._assign_field_to_farmer(initial_field_node, f)

	f.set_route_nodes(home, _village.market_node)

	_village.all_farmers.append(f)

	# Absorb orphaned fields that have no assigned farmer yet
	var absorbed: int = 0
	for fn in _village.all_field_nodes:
		if is_instance_valid(fn) and _village.field_mgr.field_assignment_map.get(fn, null) == null:
			_village._assign_field_to_farmer(fn, f)
			absorbed += 1

	if _village.event_bus:
		var msg: String = "PLACED: %s at (%d, %d)" % [f.name, int(pos.x), int(pos.y)]
		if absorbed > 0:
			msg += " → absorbed %d unassigned field(s)" % absorbed
		_village.event_bus.emit_log(msg)

	return f


func spawn_baker_at(pos: Vector2) -> Node:
	if _agent_scene == null:
		if _village.event_bus:
			_village.event_bus.emit_log("[ERROR] Cannot spawn baker: AgentScene not loaded")
		return null

	var total_pop: int = _village.get_total_population()
	if total_pop >= Tuning.i("town_size_limit", _village.pop_mgr.MAX_TOTAL_POP):
		var msg := "[POP] Spawn blocked — cap reached (%d/%d)" % [total_pop, Tuning.i("town_size_limit", _village.pop_mgr.MAX_TOTAL_POP)]
		print(msg)
		if _village.event_bus:
			_village.event_bus.emit_log(msg)
		return null

	var b: Agent = _agent_scene.instantiate() as Agent
	if b == null:
		push_error("AgentScene instantiate() returned null")
		return null
	b.name = "Baker_%d" % _village.pop_mgr.next_baker_id
	_village.pop_mgr.next_baker_id += 1
	b.home_village_id = _village.village_id
	b.home_village_ref = _village
	b.current_village_ref = _village
	b.position = _village.to_local(pos)
	_village.add_child(b)

	_village._fixup_node_name(b, "Baker")

	await get_tree().process_frame

	_village._assign_new_identity(b)

	b.market = _village.market
	b.event_bus = _village.event_bus
	b.econ_stats = _village.econ_stats
	b.set_role("Baker")
	# Connect trade signals so this village is notified when the baker arrives at or
	# returns to any village. Signals are defined on JobBase and owned by the job node;
	# Godot auto-disconnects when the job is freed (e.g., on role change or removal).
	if b.current_job:
		b.current_job.trade_arrived.connect(_village._on_agent_trade_arrived)
		b.current_job.trade_return_arrived.connect(_village._on_agent_trade_return_arrived)

	var b_hunger: HungerNeed = b.get_node("HungerNeed") as HungerNeed
	var b_inv: Inventory = b.get_node("Inventory") as Inventory
	if b_hunger and b_inv:
		b_hunger.bind(b.name, b_inv, _village.event_bus, _village.calendar)

	var b_reserve: FoodReserve = b.get_node("FoodReserve") as FoodReserve
	if b_reserve:
		b_reserve.bind(b_inv, b_hunger, _village.market, b.get_node("Wallet") as Wallet, _village.event_bus, b.name)

	var bakery_spot := Node2D.new()
	bakery_spot.name = b.name + "_Bakery"
	bakery_spot.position = _village.to_local(pos)
	bakery_spot.set_meta("village_id", _village.village_id)
	var bakery_marker := ColorRect.new()
	bakery_marker.name = "BakeryMarker"
	bakery_marker.offset_left = -12.0
	bakery_marker.offset_top = -12.0
	bakery_marker.offset_right = 12.0
	bakery_marker.offset_bottom = 12.0
	bakery_marker.color = Color(1, 0.8, 0.2, 0.6)
	bakery_spot.add_child(bakery_marker)
	_village.add_child(bakery_spot)

	b.set_locations(bakery_spot, _village.market_node)

	_village.all_bakers.append(b)

	if _village.event_bus:
		_village.event_bus.emit_log("PLACED: %s at (%d, %d)" % [b.name, int(pos.x), int(pos.y)])

	return b


func spawn_household_at(pos: Vector2) -> Node:
	if _agent_scene == null:
		push_error("Cannot spawn household: AgentScene not loaded")
		return null

	var total_pop: int = _village.get_total_population()
	if total_pop >= Tuning.i("town_size_limit", _village.pop_mgr.MAX_TOTAL_POP):
		var msg := "[POP] Spawn blocked — cap reached (%d/%d)" % [total_pop, Tuning.i("town_size_limit", _village.pop_mgr.MAX_TOTAL_POP)]
		print(msg)
		if _village.event_bus:
			_village.event_bus.emit_log(msg)
		return null

	var h: Agent = _agent_scene.instantiate() as Agent
	if h == null:
		push_error("AgentScene instantiate() returned null")
		return null

	h.name = "Household_%d" % _village.pop_mgr.next_household_id
	_village.pop_mgr.next_household_id += 1
	h.home_village_id = _village.village_id
	h.home_village_ref = _village
	h.current_village_ref = _village
	h.position = _village.to_local(pos)
	_village.add_child(h)

	_village._fixup_node_name(h, "Household")

	await get_tree().process_frame

	_village._assign_new_identity(h)

	h.market = _village.market
	h.event_bus = _village.event_bus
	h.econ_stats = _village.econ_stats
	h.set_role("Household")

	var spawned_hunger: HungerNeed = h.get_node("HungerNeed") as HungerNeed
	var spawned_inv: Inventory = h.get_node("Inventory") as Inventory
	if spawned_hunger and spawned_inv:
		spawned_hunger.bind(h.name, spawned_inv, _village.event_bus, _village.calendar)

	var home := Node2D.new()
	home.name = h.name + "_Home"
	home.position = _village.to_local(pos)
	home.set_meta("village_id", _village.village_id)
	_village.add_child(home)

	h.set_locations(home, _village.market_node)

	_village.households.append(h)

	# Connect to village's _on_household_died so labor conversion can check
	# and disconnect it via the same callable (village._on_household_died).
	h.agent_died.connect(_village._on_household_died)

	if _village.event_bus:
		var prosperity_val: float = _village.prosperity_meter.prosperity_score if _village.prosperity_meter else 0.0
		_village.event_bus.emit_log("POP GROWTH: spawning %s (prosperity=%.3f)" % [h.name, prosperity_val])

	return h
