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
var housing: Housing = null   # houses: newcomers need an empty one

# ── Managers ──────────────────────────────────────────────────────────────────
var pop_mgr:    PopulationManager    = null
var field_mgr:  FieldManager         = null
var econ_stats: EconomyStatsManager  = null

# ── Population + field arrays — property getters delegate to managers ──────────
# This ensures pop_mgr, labor_market, and econ_stats all share the same arrays.
var all_farmers: Array:
	get: return pop_mgr.all_farmers if pop_mgr else []
var all_bakers: Array:
	get: return pop_mgr.all_bakers if pop_mgr else []
var all_woodworkers: Array:
	get: return pop_mgr.all_woodworkers if pop_mgr else []
var households: Array:
	get: return pop_mgr.households if pop_mgr else []
var all_fields: Array:
	get: return field_mgr.all_fields if field_mgr else []
var all_field_nodes: Array:
	get: return field_mgr.all_field_nodes if field_mgr else []

# ── Career system state ────────────────────────────────────────────────────────
var _labor_svc: LaborService = null
var sim_failed: bool = false

# ── Economy state ─────────────────────────────────────────────────────────────
var economy_config: Dictionary = {}
var event_bus: EventBus = null

# ── Trade service — owns flow counters + snapshot helper (Phase 6 extraction) ──
var trade_service: VillageTradeService = null

# ── Spawn infrastructure ───────────────────────────────────────────────────────
## Child service node that owns the three async spawn operations.
var spawn_service: VillageSpawnService = null
## Positional node used as market routing destination (Node2D in scene).
var market_node: Node2D = null
var lumber_yard: Node2D = null   # batch 3: where woodworkers cut firewood
## Calendar reference for HungerNeed binding during spawns.
var calendar = null      # Calendar
## ProsperityMeter reference for spawn log messages.
var prosperity_meter = null  # ProsperityMeter


# ── Configuration ─────────────────────────────────────────────────────────────
var _seed: int = 0
var _config: Dictionary = {}

# ── Village territory / spawn zone ────────────────────────────────────────────
## World-space anchor for spawn calculations. Initialised in initialize().
var village_center: Vector2 = Vector2.ZERO
## Maximum distance from village_center that new agents may spawn.
var spawn_radius: float = 220.0
## Minimum distance — prevents all pops from stacking exactly on the centre.
var inner_spawn_radius: float = 60.0

# ── Convenience forwards → managers (keeps spawn code working) ────────────────
var MAX_FIELDS: int:
	get: return field_mgr.MAX_FIELDS if field_mgr else 10
var MAX_TOTAL_POP: int:
	get: return Tuning.i("town_size_limit", pop_mgr.MAX_TOTAL_POP if pop_mgr else 50)
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

	# ── Territory anchor (used for local spawn positioning + debug draw) ──
	# Village nodes are placed at world offsets by WorldManager; the visual
	# activity area is centred roughly 400 px right and 300 px down from the
	# node origin, matching WorldManager.VILLAGE_CENTROID_OFFSET.
	village_center = global_position + Vector2(400.0, 300.0)
	queue_redraw()

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

	# ── Load config ──
	if config.is_empty():
		_load_economy_config()
	else:
		economy_config = config

	# ── Spawn service (child node; owns async farmer/baker/household spawning) ──
	spawn_service = VillageSpawnService.new()
	spawn_service.name = "SpawnService"
	add_child(spawn_service)
	spawn_service.setup(self)

	# ── Simulation systems ──
	var bus := EventBus.new()
	bus.name = "EventBus"
	add_child(bus)
	bus.process_mode = Node.PROCESS_MODE_PAUSABLE
	bus.village_label = name
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

	# ── Trade service ──
	trade_service = VillageTradeService.new()
	trade_service.name = "VillageTradeService"
	add_child(trade_service)
	trade_service.process_mode = Node.PROCESS_MODE_PAUSABLE
	trade_service.setup(self, market)

	# Wire calendar signals
	calendar.day_changed.connect(market.on_day_changed)
	calendar.day_changed.connect(_on_calendar_day_changed)

	# Stamp home village on initial agents so locality is trackable from birth.
	farmer.home_village_id = village_id
	baker.home_village_id = village_id
	household_agent.home_village_id = village_id

	# Bind village refs for trade evaluation (FarmerJob / BakerJob read these).
	farmer.home_village_ref = self
	farmer.current_village_ref = self
	baker.home_village_ref = self
	baker.current_village_ref = self
	household_agent.home_village_ref = self
	household_agent.current_village_ref = self

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
	labor_market.all_woodworkers = all_woodworkers
	labor_market.free_field_count = func() -> int: return _free_fields().size()
	labor_market.extend_shop = func(p, day: int) -> bool: return housing.start_shop_extension(p, day) if housing else false
	labor_market.rent_per_day = func() -> float: return housing.rent_per_day() if housing != null and housing.market != null else 0.0
	# ── Labor service ──
	_labor_svc = LaborService.new()
	_labor_svc.name = "LaborService"
	add_child(_labor_svc)
	_labor_svc.bind(pop_mgr, field_mgr, bus)
	labor_market.migrate_requested.connect(_labor_svc.handle_migrate_requested)
	labor_market.migrate_requested.connect(_note_leaver)
	labor_market.role_switch_requested.connect(_labor_svc.handle_role_switch_requested)
	labor_market.business_failed.connect(_on_business_failed)

	# Bind econ_stats to per-village arrays
	econ_stats.bind_agents(pop_mgr.all_farmers, pop_mgr.all_bakers, pop_mgr.households)
	econ_stats.bind_woodworkers(pop_mgr.all_woodworkers)
	# Batch 3: a lumber yard and the town's first woodworker.
	_build_lumber_yard()
	_spawn_first_woodworker()
	# A travelling merchant carries goods between this village and the other one.
	_spawn_merchant()
	# Houses: newcomers arrive only into an empty one; people build, buy and rent them.
	housing = Housing.new()
	housing.village = self
	housing.market = market
	housing.event_bus = event_bus
	# Troubles: blight, fire, frost, rats (scripts/village/shocks.gd).
	shocks = Shocks.new()
	shocks.village = self
	shocks.market = market
	shocks.event_bus = event_bus
	shocks.rng.seed = (rng.seed if rng else 1) + 7919
	recovery = Recovery.new()
	recovery.village = self
	# Drawing: ground, roads, buildings and houses under the people.
	var art := VillageArt.new()
	art.name = "VillageArt"
	art.village = self
	art.z_index = -1
	add_child(art)
	move_child(art, 0)
	for marker_path in ["MarketNode/MarketMarker", "Bakery/BakeryMarker", "House/HouseMarker",
			"HouseholdHome/HouseholdHomeMarker", "Field1/Field1Marker", "Field2/Field2Marker"]:
		var mk = get_node_or_null(marker_path)
		if mk:
			mk.visible = false
	if lumber_yard and lumber_yard.get_node_or_null("Marker"):
		lumber_yard.get_node("Marker").visible = false

	# Assign persistent identities
	_assign_new_identity(farmer)
	_assign_new_identity(baker)
	_assign_new_identity(household_agent)

	# Bootstrap market
	_apply_market_seed()

	event_bus.emit_log("Tick 0: START")


## Canonical tick entry-point.  World connects SimulationClock.ticked → tick_sim.
func tick_sim(tick: int) -> void:
	receive_tick(tick)


## Legacy alias kept for backward compatibility with world.gd drafts.
func tick(_delta: float) -> void:
	pass


func receive_tick(tick: int) -> void:
	"""Called by the world's SimulationClock for each simulation tick."""

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
	for w in all_woodworkers:
		if w and is_instance_valid(w):
			w.set_tick(tick)
	for h in households:
		if h and is_instance_valid(h):
			h.set_tick(tick)

	if prosperity_meter and calendar.day_index != _prosperity_day:
		_prosperity_day = calendar.day_index   # once a day (it ran 10 times a day)
		# Count everyone, not just households. With households only, a village whose
		# households had all left read as "nobody has food saved", scored about 0.58 against
		# the growth bar (0.70, from config/economy_config.json), and could never get a
		# newcomer again.
		var everyone: Array = []
		for grp in [households, all_farmers, all_bakers, all_woodworkers]:
			for a in grp:
				if a != null and is_instance_valid(a):
					everyone.append(a)
		prosperity_meter.households = everyone
		prosperity_meter.update_prosperity(calendar.day_index)

		var suppress_spawn: bool = (
			labor_market != null and
			labor_market.should_suppress_spawn() and
			households.size() > 0
		)

		if event_bus and calendar.day_index % 5 == 0:
			event_bus.emit_log("[SPAWN CHECK] day=%d prosperity=%.3f threshold=%.2f suppress=%s households=%d" % [
				calendar.day_index,
				prosperity_meter.prosperity_score,
				prosperity_meter.PROSPERITY_THRESHOLD_TO_GROW,
				suppress_spawn,
				households.size()
			])

		if prosperity_meter.should_spawn_household(calendar.day_index) and not suppress_spawn \
				and (housing == null or housing.free_slots() > 0 or not Tuning.on("arrival_needs_free_house", true)) and room_for_newcomer():
			_welcome_newcomer()
			prosperity_meter.record_spawn(calendar.day_index)

	if farmer != null and is_instance_valid(farmer) and baker != null and is_instance_valid(baker):
		audit.audit(farmer, baker, market, event_bus, tick)


## Who comes to town (docs/WHO_ARRIVES.md). The town's own state decides who the next
## newcomer is, instead of a limit on how many people may be without work:
##   - a job is waiting (an employer wanted a hand in the last few days, found nobody, and
##     nobody in town is free): someone comes looking for work, with a newcomer's purse;
##   - no job is waiting: the person who comes has the means to open a shop of their own
##     (the savings a shop takes plus its fee), because a town with nothing to offer a
##     worker still has room for someone who makes work.
## The other gates are unchanged: the town is doing well (prosperity), a house stands
## empty, bread and firewood are not scarce. Dev switch arrivals_follow_jobs; off is the
## old rule (nobody comes while more than MAX_IDLE_FOR_ARRIVAL people lack work).
const MAX_IDLE_FOR_ARRIVAL: int = 1
var _prosperity_day: int = -1
## Newcomers so far, by what brought them (tests and the long-run rows).
var arrivals := {"for_work": 0, "with_means": 0}

func room_for_newcomer() -> bool:
	if labor_market == null or Tuning.on("arrivals_follow_jobs", true):
		return true
	return labor_market.idle_count <= Tuning.i("arrival_max_idle", MAX_IDLE_FOR_ARRIVAL)


## True when the next newcomer is someone with the means to open a shop: no job is waiting.
func newcomer_has_means() -> bool:
	if labor_market == null or not Tuning.on("arrivals_follow_jobs", true):
		return false
	return not labor_market.job_waiting(calendar.day_index if calendar else 0)


## What it takes to open a shop: the savings and the fee (LaborMarket).
func means_purse() -> float:
	return Tuning.f("shop_savings_needed", LaborMarket.SAVINGS_BUFFER_REQUIRED) + Tuning.f("shop_opening_fee", LaborMarket.STARTUP_COST)


func _welcome_newcomer() -> void:
	var with_means: bool = newcomer_has_means()
	var day: int = calendar.day_index if calendar else 0
	var h = await spawn_household_at(get_spawn_point_for_role("household"))
	if h == null or not is_instance_valid(h):
		return
	if not with_means:
		arrivals.for_work += 1
		if event_bus and Tuning.on("arrivals_follow_jobs", true):
			event_bus.emit_log("[ARRIVAL] day=%d %s comes looking for work (a job was waiting)" % [day, h.name])
		return
	arrivals.with_means += 1
	var purse: float = means_purse()
	if h.wallet != null and h.wallet.money < purse:
		Village.note_brought(h, purse - h.wallet.money)
		h.wallet.credit(purse - h.wallet.money)
	h.set_meta("came_with_means", true)
	if h.has_method("log_event"):
		h.log_event("Came to town with $%.0f to set up a shop." % purse)
	if event_bus:
		event_bus.emit_log("[ARRIVAL] day=%d %s comes with $%.0f to set up in town (no job was waiting)" % [day, h.name, purse])


func get_market() -> Market:
	return market


## Returns a lightweight snapshot of this village's market for trade evaluation.
## Delegates to VillageTradeService. FarmerJob / BakerJob call this on all villages.
func get_trade_snapshot() -> Dictionary:
	if trade_service == null:
		return {}
	return trade_service.get_trade_snapshot()


## Records goods exported by an agent belonging to this village (sold abroad).
## Delegates to VillageTradeService.
func record_trade_export(good: String, qty: int) -> void:
	if trade_service:
		trade_service.record_trade_export(good, qty)


## Records goods imported into this village (sold here by a visiting foreign agent).
## Delegates to VillageTradeService.
func record_trade_import(good: String, qty: int) -> void:
	if trade_service:
		trade_service.record_trade_import(good, qty)


## Returns a summary of cumulative trade flow for this village.
## Delegates to VillageTradeService.
func get_trade_flow_summary() -> Dictionary:
	if trade_service == null:
		return {}
	return trade_service.get_trade_flow_summary()


## Resets all trade flow counters to zero. Delegates to VillageTradeService.
func reset_trade_flow_counters() -> void:
	if trade_service:
		trade_service.reset_trade_flow_counters()


func get_population_summary() -> Dictionary:
	return {
		"farmers":    all_farmers.size(),
		"bakers":     all_bakers.size(),
		"woodworkers": all_woodworkers.size(),
		"households": households.size(),
		"total":      pop_mgr.count() if pop_mgr else 0,
		"fields":     all_field_nodes.size(),
		"max_fields": MAX_FIELDS,
	}


func get_econ_snapshot() -> Dictionary:
	var snap: Dictionary = {
		"day":         calendar.day_index if calendar else 0,
		"wheat_price": market.wheat_price if market else 0.0,   # shelf prices, as firewood shows
		"bread_price": market.bread_price if market else 0.0,
		"wheat":       market.wheat if market else 0,
		"bread":       market.bread if market else 0,
		"wheat_cap":   market.wheat_capacity if market else 999999999,
		"bread_cap":   market.bread_capacity if market else 999999999,
		"prosperity_score":      prosperity_meter.prosperity_score if prosperity_meter else 0.0,
		"prosperity_wealth":     (prosperity_meter.prosperity_inputs.get("wealth_health", 0.0)
		                          if prosperity_meter else 0.0),
		"prosperity_food":       (prosperity_meter.prosperity_inputs.get("food_security", 0.0)
		                          if prosperity_meter else 0.0),
		"prosperity_starvation": (prosperity_meter.prosperity_inputs.get("starvation_pressure", 0.0)
		                          if prosperity_meter else 0.0),
	}
	# Baseline farmer — first valid farmer in this village
	var f: Node = farmer if (farmer != null and is_instance_valid(farmer)) else (
		all_farmers[0] if all_farmers.size() > 0 and is_instance_valid(all_farmers[0]) else null)
	if f != null:
		var f_inv  := f.get_node_or_null("Inventory")      as Inventory
		var f_hngr := f.get_node_or_null("HungerNeed")     as HungerNeed
		var f_wlt  := f.get_node_or_null("Wallet")         as Wallet
		var f_cap  := f.get_node_or_null("InventoryCapacity") as InventoryCapacity
		snap["baseline_farmer"] = {
			"cash":        f_wlt.money       if f_wlt  else 0.0,
			"seeds":       f_inv.get_qty("seeds") if f_inv  else 0,
			"wheat":       f_inv.get_qty("wheat") if f_inv  else 0,
			"bread":       f_inv.get_qty("bread") if f_inv  else 0,
			"hunger_days": f_hngr.hunger_days     if f_hngr else 0,
			"hunger_max":  f_hngr.hunger_max_days if f_hngr else 5,
			"status":      f.get_status_text()    if f.has_method("get_status_text") else "",
			"inv_total":   f_cap.current_total()  if f_cap  else 0,
			"inv_max":     f_cap.max_items        if f_cap  else 0,
		}
	# Baseline baker — first valid baker in this village
	var b: Node = baker if (baker != null and is_instance_valid(baker)) else (
		all_bakers[0] if all_bakers.size() > 0 and is_instance_valid(all_bakers[0]) else null)
	if b != null:
		var b_inv  := b.get_node_or_null("Inventory")      as Inventory
		var b_hngr := b.get_node_or_null("HungerNeed")     as HungerNeed
		var b_wlt  := b.get_node_or_null("Wallet")         as Wallet
		var b_cap  := b.get_node_or_null("InventoryCapacity") as InventoryCapacity
		snap["baseline_baker"] = {
			"cash":        b_wlt.money       if b_wlt  else 0.0,
			"wheat":       b_inv.get_qty("wheat") if b_inv  else 0,
			"flour":       b_inv.get_qty("flour") if b_inv  else 0,
			"bread":       b_inv.get_qty("bread") if b_inv  else 0,
			"hunger_days": b_hngr.hunger_days     if b_hngr else 0,
			"hunger_max":  b_hngr.hunger_max_days if b_hngr else 5,
			"status":      b.get_status_text()    if b.has_method("get_status_text") else "",
			"inv_total":   b_cap.current_total()  if b_cap  else 0,
			"inv_max":     b_cap.max_items        if b_cap  else 0,
		}
	return snap


# ── Spawn helpers (relocated from main.gd) ────────────────────────────────────

func get_total_population() -> int:
	return pop_mgr.count() if pop_mgr else 0



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
			event_bus.emit_log(msg)


func _assign_field_to_farmer(field_node: Node2D, new_farmer: Node) -> void:
	if field_mgr:
		field_mgr.assign_field(field_node, new_farmer)


func spawn_field_at(pos: Vector2, assign_to: Node = null, skip_auto_assign: bool = false) -> Node2D:
	if all_field_nodes.size() >= field_mgr.MAX_FIELDS:
		var msg := "[LAND] Spawn blocked — cap reached (%d/%d)" % [all_field_nodes.size(), field_mgr.MAX_FIELDS]
		print(msg)
		if event_bus:
			event_bus.emit_log(msg)
		return null

	var field_node = Node2D.new()
	field_node.name = "Field%d" % field_mgr.next_field_id
	field_mgr.next_field_id += 1
	field_node.set_script(load("res://scripts/field_plot.gd"))
	field_node.position = to_local(pos)

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
		event_bus.emit_log("PLACED: %s at (%d, %d)" % [field_node.name, int(pos.x), int(pos.y)])

	if not skip_auto_assign:
		if assign_to != null and is_instance_valid(assign_to):
			_assign_field_to_farmer(field_node, assign_to)
		elif all_farmers.size() >= 1 and is_instance_valid(all_farmers[0]):
			# Auto-assign to first available farmer (village context has no popup UI)
			_assign_field_to_farmer(field_node, all_farmers[0])

	return field_node


func spawn_farmer_at(pos: Vector2, initial_field_node: Node2D = null) -> Node:
	return await spawn_service.spawn_farmer_at(pos, initial_field_node)


func spawn_baker_at(pos: Vector2) -> Node:
	return await spawn_service.spawn_baker_at(pos)


func spawn_household_at(pos: Vector2) -> Node:
	return await spawn_service.spawn_household_at(pos)


## Anyone who starves to death (any trade). What they had in their purse goes to the town;
## a house they owned passes to the town the next morning (Housing). Their hands are free
## to be taken on by someone else.
var starved_deaths: int = 0
var starved_with_food: int = 0   # died holding coins for a loaf while the market had bread

func _on_household_died(agent_node: Node) -> void:
	if not is_instance_valid(agent_node) or agent_node.is_queued_for_deletion():
		return
	starved_deaths += 1
	if market and agent_node.get_cash() >= market.bread_price and market.bread > 0:
		starved_with_food += 1
	if event_bus:
		event_bus.emit_log("[DEATH] day=%d %s starved ($%.1f, market bread %d at $%.2f)" % [
			calendar.day_index if calendar else -1, agent_node.name, agent_node.get_cash(),
			market.bread if market else -1, market.bread_price if market else 0.0])
	if prosperity_meter and calendar:
		prosperity_meter.record_starvation_event(calendar.day_index)
	if recovery:
		recovery.owner_gone(agent_node)   # their shop stands empty; the people who worked there are first in line
	if labor_market:
		labor_market._release_hands(agent_node, "employer died")
	var w = agent_node.get("wallet")
	if market and w != null and w.money > 0.0:
		market.money += w.money
		w.debit(w.money)
	_labor_svc.handle_migrate_requested(agent_node, "starved")


## Every person's death is heard, whatever trade they changed to.
func _listen_for_deaths() -> void:
	for grp in [households, all_farmers, all_bakers, all_woodworkers]:
		for a in grp:
			if a != null and is_instance_valid(a) and not a.agent_died.is_connected(_on_household_died):
				a.agent_died.connect(_on_household_died)


# ============================================================================
# LABOR MARKET — Career mobility, migration, role conversion
# ============================================================================

func _on_calendar_day_changed(day: int) -> void:

	if event_bus:
		event_bus.emit_log("[LAND STATUS] fields=%d/%d" % [all_field_nodes.size(), MAX_FIELDS])
		event_bus.emit_log("[POP STATUS] total=%d/%d (H=%d F=%d B=%d W=%d)" % [
			pop_mgr.count(), MAX_TOTAL_POP,
			households.size(), all_farmers.size(), all_bakers.size(), all_woodworkers.size()])

	_listen_for_deaths()
	if shocks:
		shocks.on_day(day)
	if housing:
		housing.start_new_builds(day)   # before employers hire (housing.gd)
	if labor_market:
		labor_market.update_daily(day)
	if recovery:
		recovery.on_day(day)   # empty shops are taken over; going without moves people

	for f in all_farmers:
		if f and is_instance_valid(f):
			f.on_day_changed(day)
	for b in all_bakers:
		if b and is_instance_valid(b):
			b.on_day_changed(day)
	for w in all_woodworkers:
		if w and is_instance_valid(w):
			w.on_day_changed(day)
	for h in households:
		if h and is_instance_valid(h):
			h.on_day_changed(day)

	_roll_global_cashflow()

	if housing:
		housing.on_day(day)

	if not sim_failed and pop_mgr.count() == 0 and day > (labor_market.STARTUP_GRACE_DAYS if labor_market else 5):
		sim_failed = true
		if event_bus:
			event_bus.emit_log("[SIM FAIL] Population extinct on day %d" % day)

	if _labor_svc:
		_labor_svc.tick_day(Callable(self, "_perform_role_conversion"))


func _perform_role_conversion(household: Node, role: String, free: bool = false) -> void:
	if not is_instance_valid(household):
		return

	var from_role: String = household.current_role if household.get("current_role") else "?"
	var pop_id: String = household.person_name if household.get("person_name") and household.person_name != "" else household.name

	if role == "farmer" and all_field_nodes.size() >= MAX_FIELDS and _free_fields().is_empty():
		var block_line := "[CONVERT] pop=%s from=%s to=%s allowed=0 block=land_cap fields=%d/%d" % [
			pop_id, from_role, role, all_field_nodes.size(), MAX_FIELDS]
		if event_bus: event_bus.emit_log(block_line)
		return

	# Batch 3: opening a business costs STARTUP_COST coins, paid to the town market.
	if role != "household" and not free and market != null:
		var purse: Wallet = household.get_node_or_null("Wallet") as Wallet
		if purse == null or purse.money < Tuning.f("shop_opening_fee", LaborMarket.STARTUP_COST):
			if event_bus:
				event_bus.emit_log("[CONVERT] pop=%s from=%s to=%s allowed=0 block=startup_cost cash=%.1f" % [
					pop_id, from_role, role, purse.money if purse else 0.0])
			return

	var pos: Vector2 = household.global_position
	var wallet_money: float = 0.0
	var hw: Wallet = household.get_node_or_null("Wallet") as Wallet
	if hw:
		wallet_money = hw.money

	if household is Agent and (household as Agent).current_job != null:
		var ag: Agent = household as Agent
		var old_role: String = ag.current_role
		if recovery and old_role.to_lower() != role:
			recovery.owner_gone(ag, false)   # closing or changing trade leaves the old shop empty
		var ce = ag.get_node_or_null("CareerEvaluator")
		var u_cur: float = ce.utility_current if ce else 0.0
		var u_best: float = maxf(ce.utility_farmer, ce.utility_baker) if ce else 0.0
		var conv_delta: float = u_best - u_cur
		var conv_ratio: float = u_best / maxf(0.01, absf(u_cur))
		if event_bus:
			event_bus.emit_log("[CONVERT] pop=%s from=%s to=%s allowed=1 block=none" % [pop_id, old_role, role])
		ag.log_event("Switched from %s to %s — utility gain %.2f, ratio %.2f; had $%.0f." % [
			old_role, role.capitalize(), conv_delta, conv_ratio, wallet_money])
		if event_bus:
			event_bus.emit_log("[MOBILITY] %s → in-place conversion to %s at (%.0f, %.0f) with $%.2f" % [
				ag.name, role, pos.x, pos.y, wallet_money])

		var h_idx: int = households.find(ag)
		if h_idx != -1:
			households.remove_at(h_idx)
		for k in ["employer", "servant", "builds_house", "hired_builder", "cottager", "garden"]:
			if ag.has_meta(k):
				ag.remove_meta(k)
		ag.set_meta("purse_given", true)   # they have a purse already; none is minted
		ag.home_village_ref = self
		ag.current_village_ref = self
		ag.market = market
		# A farmer or baker changing trade (docs/ECONOMY_BATCH1.md): leave the old trade's list,
		# give up the fields (another farmer can take them over), and keep what they own.
		# Batch 3: everyone keeps what they own when they change what they do.
		var kept_items: Dictionary = ag.inv.items.duplicate() if ag.inv else {}
		all_woodworkers.erase(ag)
		if all_farmers.has(ag) or all_bakers.has(ag):
			if all_farmers.has(ag):
				all_farmers.erase(ag)
				for fn in all_field_nodes:
					if is_instance_valid(fn) and field_assignment_map.get(fn, null) == ag:
						field_assignment_map[fn] = null
				ag.clear_fields_for_removal()
			all_bakers.erase(ag)
		if ag.agent_died.is_connected(_on_household_died):
			ag.agent_died.disconnect(_on_household_died)
		# Ensure converted agent retains the correct home village.
		ag.home_village_id = village_id

		if role == "farmer":
			# Use village-local spawn helper so the new field stays inside the
			# correct village territory regardless of world offset.
			var field_pos := get_spawn_point_for_role("farmer")
			# Take over a field nobody works before ploughing a new one.
			var free_fields := _free_fields()
			var pre_field: Node2D = free_fields[0] if not free_fields.is_empty() else spawn_field_at(field_pos, null, true)
			if pre_field == null:
				households.append(ag)
				if not ag.agent_died.is_connected(_on_household_died):
					ag.agent_died.connect(_on_household_died)
				if event_bus:
					event_bus.emit_log("[MOBILITY] Farmer conversion aborted — field spawn returned null")
				return

			ag.set_role("Farmer")
			_restore_items(ag, kept_items)
			_pay_startup(ag, free)
			ag.name = "Farmer_%d" % next_farmer_id
			next_farmer_id += 1
			_fixup_node_name(ag, "Farmer")

			if ag.hunger and ag.inv:
				ag.hunger.bind(ag.name, ag.inv, event_bus, calendar)
			if ag.food_reserve:
				ag.food_reserve.bind(ag.inv, ag.hunger, market, ag.wallet, event_bus, ag.name)

			var home := Node2D.new()
			home.name = ag.name + "_Home"
			home.position = to_local(pos)
			home.set_meta("village_id", village_id)
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
				event_bus.emit_log("[LAND] New field for farmer %s at (%.0f, %.0f)" % [
					ag.name, field_pos.x, field_pos.y])

		elif role == "baker":
			ag.set_role("Baker")
			_restore_items(ag, kept_items)
			_pay_startup(ag, free)
			ag.name = "Baker_%d" % next_baker_id
			next_baker_id += 1
			_fixup_node_name(ag, "Baker")

			if ag.hunger and ag.inv:
				ag.hunger.bind(ag.name, ag.inv, event_bus, calendar)
			if ag.food_reserve:
				ag.food_reserve.bind(ag.inv, ag.hunger, market, ag.wallet, event_bus, ag.name)

			var bakery_spot := Node2D.new()
			bakery_spot.name = ag.name + "_Bakery"
			bakery_spot.position = to_local(pos)
			bakery_spot.set_meta("village_id", village_id)
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

		elif role == "woodworker":
			ag.set_role("Woodworker")
			_restore_items(ag, kept_items)
			_pay_startup(ag, free)
			ag.name = "Woodworker_%d" % pop_mgr.next_woodworker_id
			pop_mgr.next_woodworker_id += 1
			_fixup_node_name(ag, "Woodworker")
			_rebind_needs(ag)
			var w_home := _make_spot(ag.name + "_Home", pos, Color(0.6, 0.4, 0.2, 0.6))
			if ag.current_job is WoodworkerJob:
				(ag.current_job as WoodworkerJob).yard_location = lumber_yard
			ag.set_locations(w_home, market_node)
			all_woodworkers.append(ag)
			if not ag.agent_died.is_connected(_on_household_died):
				ag.agent_died.connect(_on_household_died)

		elif role == "merchant":
			ag.set_role("Merchant")
			_restore_items(ag, kept_items)
			ag.name = "Merchant_%d" % village_id
			_fixup_node_name(ag, "Merchant")
			_rebind_needs(ag)
			var m_home := _make_spot(ag.name + "_Home", pos, Color(0.3, 0.7, 1.0, 0.6))
			ag.set_locations(m_home, market_node)
			households.append(ag)
			if not ag.agent_died.is_connected(_on_household_died):
				ag.agent_died.connect(_on_household_died)

		elif role == "household":
			# Batch 3: a business that failed. Its owner stays in town as a household looking
			# for work, with their coins, bread and firewood. The stock of the old trade
			# (seeds, wheat, flour) is left behind. They may open a business again at once.
			ag.set_role("Household")
			_restore_items(ag, kept_items)
			if ag.inv:
				for k in ["seeds", "wheat", "flour"]:
					ag.inv.items.erase(k)
			ag.name = "Household_%d" % pop_mgr.next_household_id
			pop_mgr.next_household_id += 1
			_fixup_node_name(ag, "Household")
			_rebind_needs(ag)
			var h_home := _make_spot(ag.name + "_Home", pos, Color(0.2, 0.5, 1, 0.6))
			ag.set_locations(h_home, market_node)
			households.append(ag)
			if not ag.agent_died.is_connected(_on_household_died):
				ag.agent_died.connect(_on_household_died)
			ag.switch_cooldown_days = 0
			ag.days_in_role = LaborMarket.MIN_TENURE_DAYS
		if recovery:
			recovery.shop_opened(ag)   # a new owner fills an empty shop of that trade, if one stands


## Batch 3: the opening fee, from the new owner's purse to the town market's.
func _pay_startup(ag: Agent, free: bool) -> void:
	if free or market == null or ag.wallet == null:
		return
	var fee: float = minf(Tuning.f("shop_opening_fee", LaborMarket.STARTUP_COST), ag.wallet.money)
	ag.wallet.debit(fee)
	market.money += fee
	ag.log_event("Paid $%.0f to the town market to open the business." % fee)
	if event_bus:
		event_bus.emit_log("[STARTUP] %s paid $%.0f to the market to open a business" % [ag.name, fee])


func _rebind_needs(ag: Agent) -> void:
	if ag.hunger and ag.inv:
		ag.hunger.bind(ag.name, ag.inv, event_bus, calendar)
	if ag.food_reserve:
		ag.food_reserve.bind(ag.inv, ag.hunger, market, ag.wallet, event_bus, ag.name)


func _make_spot(spot_name: String, global_pos: Vector2, colour: Color, half: float = 12.0) -> Node2D:
	var spot := Node2D.new()
	spot.name = spot_name
	spot.position = to_local(global_pos)
	spot.set_meta("village_id", village_id)
	var marker := ColorRect.new()
	marker.name = "Marker"
	marker.offset_left = -half
	marker.offset_top = -half
	marker.offset_right = half
	marker.offset_bottom = half
	marker.color = colour
	spot.add_child(marker)
	add_child(spot)
	return spot


## Batch 3: one lumber yard per village, a short walk from the market. Its wood never runs out.
func _build_lumber_yard() -> void:
	if lumber_yard != null or market_node == null:
		return
	lumber_yard = _make_spot("LumberYard", market_node.global_position + Vector2(140, -120), Color(0.35, 0.22, 0.1, 0.8), 20.0)


## Batch 3: the town starts with one woodworker, the way it starts with one farmer and one
## baker. They arrive as a household and are set up with an owner's purse.
func _spawn_first_woodworker() -> void:
	if spawn_service == null:
		return
	var h = await spawn_household_at(get_spawn_point_for_role("household"))
	if h == null or not is_instance_valid(h):
		return
	_perform_role_conversion(h, "woodworker", true)
	var owner_purse: float = Tuning.f("owner_start_coins", WoodworkerJob.OWNER_CASH)
	if h.wallet and h.wallet.money < owner_purse:
		Village.note_brought(h, owner_purse - h.wallet.money)
		h.wallet.credit(owner_purse - h.wallet.money)
	if h.inv:
		h.inv.items["bread"] = maxi(2, h.inv.get_qty("bread"))
		h.inv.items["firewood"] = maxi(6, h.inv.get_qty("firewood"))


## What this village's merchant has done so far (tests and the HUD).
var trade_stats := {"trips": 0, "units": 0, "profit": 0.0}
var shocks: Shocks = null
## Empty shops and who takes them over, for every trade (scripts/village/recovery.gd).
var recovery: Recovery = null

## The town's books (tests): coins that came in from outside (a newcomer's purse, a new owner's
## or merchant's purse) and coins carried away by people who left. Everything else only moves
## between people and the market, so people's coins plus the market's purse change by exactly
## coins_brought minus coins_taken (across both towns, since merchants carry coins between them).
var coins_brought: float = 0.0
var coins_taken: float = 0.0

static func note_brought(agent, amount: float) -> void:
	if agent == null or amount == 0.0:
		return
	var v = agent.get("home_village_ref")
	if v != null and is_instance_valid(v):
		v.coins_brought += amount


func _note_leaver(agent: Node, reason: String) -> void:
	if recovery and reason != "dev start":
		recovery.owner_gone(agent)   # a shop owner leaving town leaves the shop
	if reason != "starved" and agent != null and is_instance_valid(agent) and agent.has_method("get_cash"):
		coins_taken += agent.get_cash()


## Merchants are switched off for now (Anthony, 2026-11-13). The code stays; dev mode (F1,
## Switches) or `--set merchants=true` brings them back.
func _spawn_merchant() -> void:
	if spawn_service == null or not Tuning.on("merchants", false):
		return
	var h = await spawn_household_at(get_spawn_point_for_role("household"))
	if h == null or not is_instance_valid(h):
		return
	_perform_role_conversion(h, "merchant", true)
	if h.inv:
		h.inv.items["bread"] = maxi(3, h.inv.get_qty("bread"))
		h.inv.items["firewood"] = maxi(4, h.inv.get_qty("firewood"))


## Batch 3: a business closed (broke after a losing streak). Its owner becomes a household.
func _on_business_failed(p: Node) -> void:
	_perform_role_conversion(p, "household", true)


## Fields with no farmer assigned.
func _free_fields() -> Array:
	var out: Array = []
	for fn in all_field_nodes:
		if is_instance_valid(fn) and field_assignment_map.get(fn, null) == null:
			out.append(fn)
	return out


## After a farmer or baker changes trade the new job's starting kit replaces their stock; give
## them back what they owned instead. A farmer keeps the kit's seeds if they had none (seeds
## are still the market's bottomless supply, see docs/ECONOMY_BATCH1.md).
func _restore_items(ag: Agent, kept: Dictionary) -> void:
	if kept.is_empty() or ag.inv == null:
		return
	var kit: Dictionary = ag.inv.items.duplicate()
	ag.inv.items = kept.duplicate()
	for k in kit:
		if not ag.inv.items.has(k):
			ag.inv.items[k] = 0
	if kit.has("seeds") and int(ag.inv.items.get("seeds", 0)) < 5:
		ag.inv.items["seeds"] = kit["seeds"]


# ============================================================================
# LOGGING + STATS
# ============================================================================

func log_population_snapshot() -> void:
	var line := "[POP SNAPSHOT] H=%d F=%d B=%d W=%d Total=%d" % [
		households.size(), all_farmers.size(), all_bakers.size(), all_woodworkers.size(),
		pop_mgr.count() if pop_mgr else 0]
	print("[%s] %s" % [name, line])
	if event_bus:
		event_bus.emit_log(line)


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

## Returns a world-space point within this village's spawn zone.
## All auto-spawns (growth, conversion, replacement) must call this so no
## agent ever appears outside the correct village territory.
func get_spawn_point_for_role(role: String) -> Vector2:
	var angle := rng.randf() * TAU
	var r := rng.randf_range(inner_spawn_radius, spawn_radius)
	# Slight role bias (visual clustering only — does not affect economy)
	match role:
		"farmer":
			# Bias toward the left/field side of the village area
			angle = rng.randf_range(PI * 0.6, PI * 1.4)
		"baker":
			# Bias toward the centre-right (bakery side)
			angle = rng.randf_range(-PI * 0.3, PI * 0.3)
		_:
			pass  # households and unknown roles use full circle
	return village_center + Vector2(cos(angle), sin(angle)) * r



# ============================================================================
# TRADE SIGNAL HANDLERS
# ============================================================================

## Called when any agent spawned by this village emits trade_arrived.
## Fires after the agent's current_village_ref and all context refs are updated,
## so runtime truth is already consistent when this handler runs.
## If the agent arrived HERE, we have an opportunity to update village-level
## agent-presence tracking (currently logged for observability only).
func _on_agent_trade_arrived(arrived_village: Node) -> void:
	if arrived_village == self:
		if event_bus:
			event_bus.emit_log("[TRADE ARRIVE] village=%s: agent arrived (village notified via signal)" % village_name)


## Called when any agent spawned by this village emits trade_return_arrived.
## Fires after current_village_ref is switched back to home, so the agent is
## already registered as home before this handler runs.
## Currently a no-op aside from logging — home tracking is via current_village_ref.
func _on_agent_trade_return_arrived(home_village: Node) -> void:
	if home_village == self:
		if event_bus:
			event_bus.emit_log("[TRADE RETURN ARRIVE] village=%s: agent returned home (village notified via signal)" % village_name)


# ============================================================================
# DEBUG VISUALIZATION
# ============================================================================

func _draw() -> void:
	"""Draw territory indicators for visual debugging.
	Shows spawn radius circle, inner exclusion zone, centre dot, and name label.
	All coordinates are local space (village origin = (0,0))."""
	if village_center == Vector2.ZERO:
		return

	var local_center := to_local(village_center)

	# The ground, roads and buildings are drawn by VillageArt; only the name is drawn here.
	# Village name label above the radius circle
	var font := ThemeDB.fallback_font
	if font:
		draw_string(font, local_center + Vector2(0, -spawn_radius - 12),
			village_name, HORIZONTAL_ALIGNMENT_CENTER, -1, 16,
			Color(0.65, 0.88, 1.0, 0.80))
