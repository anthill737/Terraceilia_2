class_name Village
extends Node2D

# ── Village identity ───────────────────────────────────────────────────────────
var village_id: int = 0
var village_name: String = "Village"

# ── RNG (per-village, seeded via initialize()) ────────────────────────────────
var rng: RandomNumberGenerator = null

# ── Core references ───────────────────────────────────────────────────────────
var market: Market = null
var farmer: Agent = null
var baker: Agent = null
var household_agent: Agent = null

# ── Managers ──────────────────────────────────────────────────────────────────
var pop_mgr = null       # PopulationManager
var field_mgr = null     # FieldManager
var econ_stats = null    # EconomyStatsManager

# ── Convenience arrays (populated by managers) ────────────────────────────────
var all_farmers: Array = []
var all_bakers: Array = []
var households: Array = []
var all_fields: Array = []
var all_field_nodes: Array = []

# ── Economy state ─────────────────────────────────────────────────────────────
var economy_config: Dictionary = {}
var event_bus: EventBus = null

# ── Spawn infrastructure ───────────────────────────────────────────────────────
## Scene used to instantiate all agent types (Farmer, Baker, Household).
var AgentScene: PackedScene = null
## Positional node used as market routing destination (Node2D in scene).
var market_node: Node2D = null
## Calendar reference for HungerNeed binding during spawns.
var calendar = null      # Calendar
## ProsperityMeter reference for spawn log messages.
var prosperity_meter = null  # ProsperityMeter

# ── Logging ───────────────────────────────────────────────────────────────────
var log_prefix: String = "[Village]"

# ── Configuration ─────────────────────────────────────────────────────────────
var _seed: int = 0
var _config: Dictionary = {}


# ── Public API ────────────────────────────────────────────────────────────────

func initialize(seed: int, config: Dictionary) -> void:
	pass


func tick(delta: float) -> void:
	pass


func get_market() -> Market:
	return null


func get_population_summary() -> Dictionary:
	return {}


func get_econ_snapshot() -> Dictionary:
	return {}


# ── Spawn helpers (relocated from main.gd) ────────────────────────────────────

func get_total_population() -> int:
	return pop_mgr.count() if pop_mgr else 0


func _resolve_agent_scene() -> void:
	if AgentScene != null:
		return
	var path := "res://scenes/Agent.tscn"
	if ResourceLoader.exists(path):
		AgentScene = load(path)
	else:
		push_error("Village: AgentScene not found at " + path)


func _assign_new_identity(pop: Node) -> void:
	if pop_mgr:
		pop_mgr.assign_identity(pop)


func _fixup_node_name(node: Node, role_prefix: String) -> void:
	var n: String = node.name
	if n.begins_with("@") or "CharacterBody2D@" in n:
		var fixed: String = "%s_%d" % [role_prefix, pop_mgr._next_person_id]
		var msg: String = "[NAME FIXUP] %s → %s (auto-generated name corrected)" % [n, fixed]
		node.name = fixed
		print(msg)
		if event_bus:
			event_bus.log(msg)


func _assign_field_to_farmer(field_node: Node2D, new_farmer: Node) -> void:
	if field_mgr:
		field_mgr.assign_field(field_node, new_farmer)


func spawn_field_at(pos: Vector2, assign_to: Node = null, skip_auto_assign: bool = false) -> Node2D:
	if all_field_nodes.size() >= field_mgr.MAX_FIELDS:
		var msg := "[LAND] Spawn blocked — cap reached (%d/%d)" % [all_field_nodes.size(), field_mgr.MAX_FIELDS]
		print(msg)
		if event_bus:
			event_bus.log(msg)
		return null

	var field_node = Node2D.new()
	field_node.name = "Field%d" % field_mgr.next_field_id
	field_mgr.next_field_id += 1
	field_node.set_script(load("res://scripts/field_plot.gd"))
	field_node.global_position = pos

	var marker = ColorRect.new()
	marker.name = "FieldMarker"
	marker.offset_left = -15.0
	marker.offset_top = -15.0
	marker.offset_right = 15.0
	marker.offset_bottom = 15.0
	marker.color = Color(0.4, 0.3, 0.1, 1)
	field_node.add_child(marker)

	var name_label = Label.new()
	name_label.name = "FieldLabel"
	name_label.text = field_node.name
	name_label.position = Vector2(-20, 18)
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.add_theme_color_override("font_color", Color(0.8, 0.7, 0.4))
	field_node.add_child(name_label)

	add_child(field_node)
	field_mgr.register_field(field_node, field_node)

	if event_bus:
		event_bus.log("PLACED: %s at (%d, %d)" % [field_node.name, int(pos.x), int(pos.y)])

	if not skip_auto_assign:
		if assign_to != null and is_instance_valid(assign_to):
			_assign_field_to_farmer(field_node, assign_to)
		elif all_farmers.size() >= 1 and is_instance_valid(all_farmers[0]):
			# Auto-assign to first available farmer (village context has no popup UI)
			_assign_field_to_farmer(field_node, all_farmers[0])

	return field_node


func spawn_farmer_at(pos: Vector2, initial_field_node: Node2D = null) -> Node:
	if AgentScene == null:
		if event_bus:
			event_bus.log("[ERROR] Cannot spawn farmer: AgentScene not loaded")
		return null

	var total_pop := get_total_population()
	if total_pop >= pop_mgr.MAX_TOTAL_POP:
		var msg := "[POP] Spawn blocked — cap reached (%d/%d)" % [total_pop, pop_mgr.MAX_TOTAL_POP]
		print(msg)
		if event_bus:
			event_bus.log(msg)
		return null

	var f: Agent = AgentScene.instantiate() as Agent
	if f == null:
		push_error("AgentScene instantiate() returned null")
		return null
	f.name = "Farmer_%d" % pop_mgr.next_farmer_id
	pop_mgr.next_farmer_id += 1
	f.global_position = pos
	add_child(f)

	_fixup_node_name(f, "Farmer")

	await get_tree().process_frame

	_assign_new_identity(f)

	f.market = market
	f.event_bus = event_bus
	f.econ_stats = econ_stats
	f.set_role("Farmer")

	var f_hunger: HungerNeed = f.get_node("HungerNeed") as HungerNeed
	var f_inv: Inventory = f.get_node("Inventory") as Inventory
	if f_hunger and f_inv:
		f_hunger.bind(f.name, f_inv, event_bus, calendar)

	var f_reserve: FoodReserve = f.get_node("FoodReserve") as FoodReserve
	if f_reserve:
		f_reserve.bind(f_inv, f_hunger, market, f.get_node("Wallet") as Wallet, event_bus, f.name)

	var home := Node2D.new()
	home.name = f.name + "_Home"
	home.global_position = pos
	var home_marker := ColorRect.new()
	home_marker.name = "HomeMarker"
	home_marker.offset_left = -12.0
	home_marker.offset_top = -12.0
	home_marker.offset_right = 12.0
	home_marker.offset_bottom = 12.0
	home_marker.color = Color(0.2, 0.5, 1, 0.6)
	home.add_child(home_marker)
	add_child(home)

	if initial_field_node != null and is_instance_valid(initial_field_node):
		_assign_field_to_farmer(initial_field_node, f)

	f.set_route_nodes(home, market_node)

	all_farmers.append(f)

	# Absorb orphaned fields
	var absorbed: int = 0
	for fn in all_field_nodes:
		if is_instance_valid(fn) and field_mgr.field_assignment_map.get(fn, null) == null:
			_assign_field_to_farmer(fn, f)
			absorbed += 1

	if event_bus:
		var msg: String = "PLACED: %s at (%d, %d)" % [f.name, int(pos.x), int(pos.y)]
		if absorbed > 0:
			msg += " → absorbed %d unassigned field(s)" % absorbed
		event_bus.log(msg)

	return f


func spawn_baker_at(pos: Vector2) -> Node:
	if AgentScene == null:
		if event_bus:
			event_bus.log("[ERROR] Cannot spawn baker: AgentScene not loaded")
		return null

	var total_pop := get_total_population()
	if total_pop >= pop_mgr.MAX_TOTAL_POP:
		var msg := "[POP] Spawn blocked — cap reached (%d/%d)" % [total_pop, pop_mgr.MAX_TOTAL_POP]
		print(msg)
		if event_bus:
			event_bus.log(msg)
		return null

	var b: Agent = AgentScene.instantiate() as Agent
	if b == null:
		push_error("AgentScene instantiate() returned null")
		return null
	b.name = "Baker_%d" % pop_mgr.next_baker_id
	pop_mgr.next_baker_id += 1
	b.global_position = pos
	add_child(b)

	_fixup_node_name(b, "Baker")

	await get_tree().process_frame

	_assign_new_identity(b)

	b.market = market
	b.event_bus = event_bus
	b.econ_stats = econ_stats
	b.set_role("Baker")

	var b_hunger: HungerNeed = b.get_node("HungerNeed") as HungerNeed
	var b_inv: Inventory = b.get_node("Inventory") as Inventory
	if b_hunger and b_inv:
		b_hunger.bind(b.name, b_inv, event_bus, calendar)

	var bakery_spot := Node2D.new()
	bakery_spot.name = b.name + "_Bakery"
	bakery_spot.global_position = pos
	var bakery_marker := ColorRect.new()
	bakery_marker.name = "BakeryMarker"
	bakery_marker.offset_left = -12.0
	bakery_marker.offset_top = -12.0
	bakery_marker.offset_right = 12.0
	bakery_marker.offset_bottom = 12.0
	bakery_marker.color = Color(1, 0.8, 0.2, 0.6)
	bakery_spot.add_child(bakery_marker)
	add_child(bakery_spot)

	b.set_locations(bakery_spot, market_node)

	all_bakers.append(b)

	if event_bus:
		event_bus.log("PLACED: %s at (%d, %d)" % [b.name, int(pos.x), int(pos.y)])

	return b


func spawn_household_at(pos: Vector2) -> Node:
	if AgentScene == null:
		push_error("Cannot spawn household: AgentScene not loaded")
		return null

	var total_pop := get_total_population()
	if total_pop >= pop_mgr.MAX_TOTAL_POP:
		var msg := "[POP] Spawn blocked — cap reached (%d/%d)" % [total_pop, pop_mgr.MAX_TOTAL_POP]
		print(msg)
		if event_bus:
			event_bus.log(msg)
		return null

	var h: Agent = AgentScene.instantiate() as Agent
	if h == null:
		push_error("AgentScene instantiate() returned null")
		return null

	h.name = "Household_%d" % pop_mgr.next_household_id
	pop_mgr.next_household_id += 1
	h.global_position = pos
	add_child(h)

	_fixup_node_name(h, "Household")

	await get_tree().process_frame

	_assign_new_identity(h)

	h.market = market
	h.event_bus = event_bus
	h.econ_stats = econ_stats
	h.set_role("Household")

	var spawned_hunger: HungerNeed = h.get_node("HungerNeed") as HungerNeed
	var spawned_inv: Inventory = h.get_node("Inventory") as Inventory
	if spawned_hunger and spawned_inv:
		spawned_hunger.bind(h.name, spawned_inv, event_bus, calendar)

	var home := Node2D.new()
	home.name = h.name + "_Home"
	home.global_position = pos
	add_child(home)

	h.set_locations(home, market_node)

	households.append(h)

	h.agent_died.connect(_on_household_died)

	if event_bus:
		var prosperity_val: float = prosperity_meter.prosperity_score if prosperity_meter else 0.0
		event_bus.log("POP GROWTH: spawning %s (prosperity=%.3f)" % [h.name, prosperity_val])

	return h


func _on_household_died(agent_node: Node) -> void:
	var idx := households.find(agent_node)
	if idx != -1:
		households.remove_at(idx)
