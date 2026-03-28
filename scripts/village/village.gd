class_name Village
extends Node2D

# Force-load manager scripts so class_names resolve before village.gd
const _PopMgrClass = preload("res://scripts/managers/population_manager.gd")
const _FieldMgrClass = preload("res://scripts/managers/field_manager.gd")
const _EconStatsClass = preload("res://scripts/managers/economy_stats_manager.gd")

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

# ── Simulation systems ─────────────────────────────────────────────────────────
var audit = null          # EconomyAudit
var labor_market = null   # LaborMarket

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

# ── Career system state ────────────────────────────────────────────────────────
var pending_conversions: Array = []
var sim_failed: bool = false

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

# ── Convenience forwards → managers (keeps spawn code working) ────────────────
var MAX_FIELDS: int:
	get: return field_mgr.MAX_FIELDS if field_mgr else 10
var MAX_TOTAL_POP: int:
	get: return pop_mgr.MAX_TOTAL_POP if pop_mgr else 50
var field_assignment_map: Dictionary:
	get: return field_mgr.field_assignment_map if field_mgr else {}
var next_farmer_id: int:
	get: return pop_mgr.next_farmer_id if pop_mgr else 2
	set(v):
		if pop_mgr: pop_mgr.next_farmer_id = v
var next_baker_id: int:
	get: return pop_mgr.next_baker_id if pop_mgr else 2
	set(v):
		if pop_mgr: pop_mgr.next_baker_id = v


# ── Public API ────────────────────────────────────────────────────────────────

func initialize(seed_val: int, config: Dictionary) -> void:
	_seed = seed_val
	_config = config

	# Per-village deterministic RNG
	rng = RandomNumberGenerator.new()
	rng.seed = seed_val

	log_prefix = "[%s]" % village_name

	# ── Managers ──
	pop_mgr = PopulationManager.new()
	pop_mgr.name = "PopulationManager"
	add_child(pop_mgr)
	pop_mgr.process_mode = Node.PROCESS_MODE_PAUSABLE

	field_mgr = FieldManager.new()
	field_mgr.name = "FieldManager"
	add_child(field_mgr)
	field_mgr.process_mode = Node.PROCESS_MODE_PAUSABLE

	econ_stats = EconomyStatsManager.new()
	econ_stats.name = "EconomyStatsManager"
	add_child(econ_stats)
	econ_stats.process_mode = Node.PROCESS_MODE_PAUSABLE

	# ── Load config and AgentScene ──
	if config.is_empty():
		_load_economy_config()
	else:
		economy_config = config

	_resolve_agent_scene()

	# ── Simulation systems ──
	var bus := EventBus.new()
	bus.name = "EventBus"
	add_child(bus)
	bus.process_mode = Node.PROCESS_MODE_PAUSABLE
	bus.village_label = village_name
	event_bus = bus

	audit = EconomyAudit.new()
	audit.name = "EconomyAudit"
	add_child(audit)
	audit.process_mode = Node.PROCESS_MODE_PAUSABLE

	calendar = Calendar.new()
	calendar.name = "Calendar"
	add_child(calendar)
	calendar.process_mode = Node.PROCESS_MODE_PAUSABLE

	prosperity_meter = ProsperityMeter.new()
	prosperity_meter.name = "ProsperityMeter"
	add_child(prosperity_meter)
	prosperity_meter.process_mode = Node.PROCESS_MODE_PAUSABLE

	# Wire field manager to event bus
	field_mgr.bind(bus)

	# ── Get scene node references ──
	var house = get_node("House")
	var field1_node = get_node("Field1")
	var field2_node = get_node("Field2")
	market_node = get_node("MarketNode")
	var bakery = get_node("Bakery")
	var household_home = get_node("HouseholdHome")
	farmer = get_node("Farmer")
	baker = get_node("Baker")
	household_agent = get_node("HouseholdAgent")

	# Register initial entities with managers
	var field1_plot = field1_node as FieldPlot
	var field2_plot = field2_node as FieldPlot
	field_mgr.register_field(field1_node, field1_plot)
	field_mgr.register_field(field2_node, field2_plot)
	pop_mgr.register_farmer(farmer)
	pop_mgr.register_baker(baker)
	field_mgr.field_assignment_map[field1_node] = farmer
	field_mgr.field_assignment_map[field2_node] = farmer

	# ── Create market ──
	market = Market.new()
	market.name = "Market"
	add_child(market)
	market.process_mode = Node.PROCESS_MODE_PAUSABLE

	# Wire calendar signals
	calendar.day_changed.connect(market.on_day_changed)
	calendar.day_changed.connect(_on_calendar_day_changed)

	# Wire event_bus and market onto all base agents
	market.event_bus = bus
	farmer.event_bus = bus
	farmer.market = market
	farmer.econ_stats = econ_stats
	baker.event_bus = bus
	baker.market = market
	baker.econ_stats = econ_stats
	household_agent.event_bus = bus
	household_agent.market = market
	household_agent.econ_stats = econ_stats

	# Wire HungerNeed (must happen before set_role)
	var farmer_inv: Inventory = farmer.get_node("Inventory") as Inventory
	var farmer_hunger: HungerNeed = farmer.get_node("HungerNeed") as HungerNeed
	farmer_hunger.bind("Farmer", farmer_inv, bus, calendar)

	var baker_inv: Inventory = baker.get_node("Inventory") as Inventory
	var baker_hunger: HungerNeed = baker.get_node("HungerNeed") as HungerNeed
	baker_hunger.bind("Baker", baker_inv, bus, calendar)

	var household_inv: Inventory = household_agent.get_node("Inventory") as Inventory
	var household_hunger: HungerNeed = household_agent.get_node("HungerNeed") as HungerNeed
	household_hunger.bind("Household", household_inv, bus, calendar)

	# Wire FoodReserve (must happen before set_role)
	var farmer_food_reserve: FoodReserve = farmer.get_node("FoodReserve") as FoodReserve
	if farmer_food_reserve:
		farmer_food_reserve.bind(farmer_inv, farmer_hunger, market, farmer.get_node("Wallet") as Wallet, bus, "Farmer")
	var baker_food_reserve: FoodReserve = baker.get_node("FoodReserve") as FoodReserve
	if baker_food_reserve:
		baker_food_reserve.bind(baker_inv, baker_hunger, market, baker.get_node("Wallet") as Wallet, bus, "Baker")
	var household_food_reserve: FoodReserve = household_agent.get_node("FoodReserve") as FoodReserve
	if household_food_reserve:
		household_food_reserve.bind(household_inv, household_hunger, market, household_agent.get_node("Wallet") as Wallet, bus, "Household")

	# Activate roles
	farmer.set_role("Farmer")
	farmer.set_route_nodes(house, market_node)
	farmer.set_fields([field1_plot, field2_plot], [field1_node, field2_node])

	baker.set_role("Baker")
	baker.set_locations(bakery, market_node)

	household_agent.set_role("Household")
	household_agent.set_locations(household_home, market_node)

	# Register household for prosperity tracking
	pop_mgr.register_household(household_agent)
	household_agent.agent_died.connect(_on_household_died)

	# Bind prosperity meter
	prosperity_meter.bind_references(bus, market, households)

	# ── Labor market ──
	labor_market = LaborMarket.new()
	labor_market.name = "LaborMarket"
	add_child(labor_market)
	labor_market.process_mode = Node.PROCESS_MODE_PAUSABLE
	labor_market.bind(market, bus)
	labor_market.econ_stats = econ_stats
	labor_market.pop_mgr = pop_mgr
	labor_market.load_career_entry_config(economy_config)
	labor_market.field_count_ref = field_mgr.all_field_nodes if field_mgr else []
	labor_market.max_fields = MAX_FIELDS
	# Share the SAME array objects so labor_market always sees current population
	labor_market.all_farmers = all_farmers
	labor_market.all_bakers = all_bakers
	labor_market.all_households = households
	labor_market.migrate_requested.connect(_on_migrate_requested)
	labor_market.role_switch_requested.connect(_on_role_switch_requested)

	# Bind econ_stats to per-village arrays
	econ_stats.bind_agents(pop_mgr.all_farmers, pop_mgr.all_bakers, pop_mgr.households)

	# Assign persistent identities
	_assign_new_identity(farmer)
	_assign_new_identity(baker)
	_assign_new_identity(household_agent)

	# Bootstrap market
	_apply_market_seed()

	event_bus.log("%s Tick 0: START" % log_prefix)


func receive_tick(tick: int) -> void:
	"""Called by the world's SimulationClock for each simulation tick."""
	if sim_failed:
		return

	calendar.set_tick(tick)
	field_mgr.tick_all()

	if market:
		market.set_tick(tick)
	for f in all_farmers:
		if f and is_instance_valid(f):
			f.set_tick(tick)
	for b in all_bakers:
		if b and is_instance_valid(b):
			b.set_tick(tick)
	for h in households:
		if h and is_instance_valid(h):
			h.set_tick(tick)

	if prosperity_meter:
		prosperity_meter.update_prosperity(calendar.day_index)

		var suppress_spawn: bool = (
			labor_market != null and
			labor_market.should_suppress_spawn() and
			households.size() > 0
		)

		if event_bus and calendar.day_index % 5 == 0:
			event_bus.log("%s[SPAWN CHECK] day=%d prosperity=%.3f threshold=%.2f suppress=%s households=%d" % [
				log_prefix,
				calendar.day_index,
				prosperity_meter.prosperity_score,
				prosperity_meter.PROSPERITY_THRESHOLD_TO_GROW,
				suppress_spawn,
				households.size()
			])

		if prosperity_meter.should_spawn_household(calendar.day_index) and not suppress_spawn:
			var spawn_pos = Vector2(rng.randf_range(100, 700), rng.randf_range(100, 500))
			spawn_household_at(spawn_pos)
			prosperity_meter.record_spawn(calendar.day_index)

	if farmer != null and is_instance_valid(farmer) and baker != null and is_instance_valid(baker):
		audit.audit(farmer, baker, market, event_bus, tick)


func get_market() -> Market:
	return market


func get_population_summary() -> Dictionary:
	return {
		"farmers": all_farmers.size(),
		"bakers": all_bakers.size(),
		"households": households.size(),
		"total": pop_mgr.count() if pop_mgr else 0
	}


func get_econ_snapshot() -> Dictionary:
	if market == null:
		return {}
	return {
		"wheat_price": market.get_bid_price("wheat") if market.has_method("get_bid_price") else 0.0,
		"bread_price": market.get_bid_price("bread") if market.has_method("get_bid_price") else 0.0,
		"wheat": market.wheat if market.get("wheat") != null else 0,
		"bread": market.bread if market.get("bread") != null else 0,
	}


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

	if agent_node.is_in_group("households"):
		agent_node.remove_from_group("households")
	if agent_node.is_in_group("agents"):
		agent_node.remove_from_group("agents")

	agent_node.queue_free()


# ============================================================================
# LABOR MARKET — Career mobility, migration, role conversion
# ============================================================================

func _on_calendar_day_changed(day: int) -> void:
	if sim_failed:
		return

	if event_bus:
		event_bus.log("%s[LAND STATUS] fields=%d/%d" % [log_prefix, all_field_nodes.size(), MAX_FIELDS])
		event_bus.log("%s[POP STATUS] total=%d/%d (H=%d F=%d B=%d)" % [
			log_prefix, pop_mgr.count(), MAX_TOTAL_POP,
			households.size(), all_farmers.size(), all_bakers.size()])

	if labor_market:
		labor_market.update_daily(day)

	for f in all_farmers:
		if f and is_instance_valid(f):
			f.on_day_changed(day)
	for b in all_bakers:
		if b and is_instance_valid(b):
			b.on_day_changed(day)
	for h in households:
		if h and is_instance_valid(h):
			h.on_day_changed(day)

	_roll_global_cashflow()

	if not sim_failed and pop_mgr.count() == 0 and day > (labor_market.STARTUP_GRACE_DAYS if labor_market else 5):
		sim_failed = true
		if event_bus:
			event_bus.log("%s[SIM FAIL] Population extinct on day %d" % [log_prefix, day])

	var still_pending: Array = []
	for entry in pending_conversions:
		var h = entry["household"]
		var role: String = entry["role"]
		var days_left: int = entry["days_remaining"] - 1
		if not is_instance_valid(h):
			continue
		if days_left <= 0:
			_perform_role_conversion(h, role)
		else:
			entry["days_remaining"] = days_left
			still_pending.append(entry)
	pending_conversions = still_pending


func _on_migrate_requested(agent: Node, reason: String) -> void:
	if not is_instance_valid(agent):
		return
	if event_bus:
		event_bus.log("%s[MIGRATION] %s leaving (reason: %s)" % [log_prefix, agent.name, reason])

	var h_idx := households.find(agent)
	if h_idx != -1:
		households.remove_at(h_idx)
		agent.remove_from_group("households")
		agent.remove_from_group("agents")

	var f_idx := all_farmers.find(agent)
	if f_idx != -1:
		all_farmers.remove_at(f_idx)
		for fn in all_field_nodes:
			if is_instance_valid(fn) and field_assignment_map.get(fn, null) == agent:
				field_assignment_map[fn] = null
		if agent.has_method("clear_fields_for_removal"):
			agent.clear_fields_for_removal()

	var b_idx := all_bakers.find(agent)
	if b_idx != -1:
		all_bakers.remove_at(b_idx)

	pending_conversions = pending_conversions.filter(func(e): return is_instance_valid(e["household"]) and e["household"] != agent)

	if agent.has_method("log_event"):
		agent.log_event("Left town — %s." % reason)
	var _migrated_name: String = agent.name
	agent.queue_free()
	if event_bus:
		event_bus.log("%s[MIGRATE CONFIRM] %s removed (reason: %s)" % [log_prefix, _migrated_name, reason])


func _on_role_switch_requested(household: Node, new_role: String) -> void:
	if not is_instance_valid(household):
		return

	for entry in pending_conversions:
		if entry["household"] == household:
			return

	var training_days: int = LaborMarket.BAKER_TRAINING_DAYS if new_role == "baker" else LaborMarket.FARMER_TRAINING_DAYS
	if event_bus:
		event_bus.log("%s[MOBILITY] %s: training to become %s (%d days)" % [log_prefix, household.name, new_role, training_days])
	if household.has_method("log_event"):
		household.log_event("Started training to become a %s (%d days to go)." % [new_role.capitalize(), training_days])

	pending_conversions.append({"household": household, "role": new_role, "days_remaining": training_days})


func _perform_role_conversion(household: Node, role: String) -> void:
	if not is_instance_valid(household):
		return

	var from_role: String = household.current_role if household.get("current_role") else "?"
	var pop_id: String = household.person_name if household.get("person_name") and household.person_name != "" else household.name

	if role == "farmer" and all_field_nodes.size() >= MAX_FIELDS:
		var block_line := "%s[CONVERT] pop=%s from=%s to=%s allowed=0 block=land_cap fields=%d/%d" % [
			log_prefix, pop_id, from_role, role, all_field_nodes.size(), MAX_FIELDS]
		if event_bus: event_bus.log(block_line)
		return

	var pos: Vector2 = household.global_position
	var wallet_money: float = 0.0
	var hw: Wallet = household.get_node_or_null("Wallet") as Wallet
	if hw:
		wallet_money = hw.money

	if household is Agent and (household as Agent).current_job != null:
		var ag: Agent = household as Agent
		var old_role: String = ag.current_role
		var ce = ag.get_node_or_null("CareerEvaluator")
		var u_cur: float = ce.utility_current if ce else 0.0
		var u_best: float = maxf(ce.utility_farmer, ce.utility_baker) if ce else 0.0
		var conv_delta: float = u_best - u_cur
		var conv_ratio: float = u_best / maxf(0.01, absf(u_cur))
		if event_bus:
			event_bus.log("%s[CONVERT] pop=%s from=%s to=%s allowed=1 block=none" % [log_prefix, pop_id, old_role, role])
		ag.log_event("Switched from %s to %s — utility gain %.2f, ratio %.2f; had $%.0f." % [
			old_role, role.capitalize(), conv_delta, conv_ratio, wallet_money])
		if event_bus:
			event_bus.log("%s[MOBILITY] %s → in-place conversion to %s at (%.0f, %.0f) with $%.2f" % [
				log_prefix, ag.name, role, pos.x, pos.y, wallet_money])

		var h_idx := households.find(ag)
		if h_idx != -1:
			households.remove_at(h_idx)
		if ag.agent_died.is_connected(_on_household_died):
			ag.agent_died.disconnect(_on_household_died)

		if role == "farmer":
			var field_pos := Vector2(
				clamp(pos.x + rng.randf_range(-150.0, 150.0), 50.0, 750.0),
				clamp(pos.y + rng.randf_range(-150.0, 150.0), 50.0, 550.0)
			)
			var pre_field := spawn_field_at(field_pos, null, true)
			if pre_field == null:
				households.append(ag)
				if not ag.agent_died.is_connected(_on_household_died):
					ag.agent_died.connect(_on_household_died)
				if event_bus:
					event_bus.log("%s[MOBILITY] Farmer conversion aborted — field spawn returned null" % log_prefix)
				return

			ag.set_role("Farmer")
			ag.name = "Farmer_%d" % next_farmer_id
			next_farmer_id += 1
			_fixup_node_name(ag, "Farmer")

			if ag.hunger and ag.inv:
				ag.hunger.bind(ag.name, ag.inv, event_bus, calendar)
			if ag.food_reserve:
				ag.food_reserve.bind(ag.inv, ag.hunger, market, ag.wallet, event_bus, ag.name)

			var home := Node2D.new()
			home.name = ag.name + "_Home"
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

			_assign_field_to_farmer(pre_field, ag)
			ag.set_route_nodes(home, market_node)
			all_farmers.append(ag)

			if event_bus:
				event_bus.log("%s[LAND] New field for farmer %s at (%.0f, %.0f)" % [
					log_prefix, ag.name, field_pos.x, field_pos.y])

		elif role == "baker":
			ag.set_role("Baker")
			ag.name = "Baker_%d" % next_baker_id
			next_baker_id += 1
			_fixup_node_name(ag, "Baker")

			if ag.hunger and ag.inv:
				ag.hunger.bind(ag.name, ag.inv, event_bus, calendar)

			var bakery_spot := Node2D.new()
			bakery_spot.name = ag.name + "_Bakery"
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

			ag.set_locations(bakery_spot, market_node)
			all_bakers.append(ag)


# ============================================================================
# LOGGING + STATS
# ============================================================================

func log_population_snapshot() -> void:
	var line := "%s[POP SNAPSHOT] H=%d F=%d B=%d Total=%d" % [
		log_prefix, households.size(), all_farmers.size(), all_bakers.size(),
		pop_mgr.count() if pop_mgr else 0]
	print(line)
	if event_bus:
		event_bus.log(line)


func _roll_global_cashflow() -> void:
	if econ_stats:
		econ_stats.roll_daily()


func global_role_rolling_7d_sum(role: String) -> float:
	return econ_stats.role_rolling_7d_sum(role) if econ_stats else 0.0


func global_role_rolling_7d_avg(role: String) -> float:
	return econ_stats.role_rolling_7d_avg(role) if econ_stats else 0.0


# ============================================================================
# CONFIG
# ============================================================================

func _load_economy_config() -> void:
	var config_path := "res://config/economy_config.json"
	if FileAccess.file_exists(config_path):
		var file := FileAccess.open(config_path, FileAccess.READ)
		if file:
			var json_text := file.get_as_text()
			file.close()
			var json := JSON.new()
			if json.parse(json_text) == OK:
				economy_config = json.data
			else:
				push_error("Village: Failed to parse economy config: " + json.get_error_message())
	else:
		push_error("Village: Economy config not found at " + config_path)


func _apply_market_seed() -> void:
	if market == null or market.market_seeded:
		return
	var seed_cfg: Dictionary = economy_config.get("market_seed", {})
	var seed_wheat: int = int(seed_cfg.get("initial_market_wheat", 40))
	var seed_bread: int = int(seed_cfg.get("initial_market_bread", 20))
	var seed_seeds: int = int(seed_cfg.get("initial_market_seeds", 0))
	market.seed_market(seed_wheat, seed_bread, seed_seeds)


# ============================================================================
# SPAWN POSITIONING
# ============================================================================

func _get_next_farmer_position() -> Vector2:
	var base_x := 80.0
	var base_y := 480.0
	var offset := all_farmers.size() * 40
	var col := offset % 200
	@warning_ignore("integer_division")
	var row := (offset / 200) * 60
	return Vector2(base_x + col, base_y + row)


func _get_next_baker_position() -> Vector2:
	var base_x := 350.0
	var base_y := 410.0
	var offset := all_bakers.size() * 40
	var col := offset % 200
	@warning_ignore("integer_division")
	var row := (offset / 200) * 60
	return Vector2(base_x + col, base_y + row)
