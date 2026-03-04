extends Node

# Force-load manager scripts so their class_names are resolved before main.gd
const _PopMgrClass = preload("res://scripts/managers/population_manager.gd")
const _FieldMgrClass = preload("res://scripts/managers/field_manager.gd")
const _EconStatsClass = preload("res://scripts/managers/economy_stats_manager.gd")
const _TradeMgrClass = preload("res://scripts/managers/trade_manager.gd")

var farmer: Agent = null
var baker: Agent = null
var market: Market = null
var household_agent: Agent = null
var clock: SimulationClock = null
var bus: EventBus = null
var audit: EconomyAudit = null
var calendar: Calendar = null
var prosperity_meter: ProsperityMeter = null

# ── Managers ──────────────────────────────────────────────────────────────────
var pop_mgr: PopulationManager = null
var field_mgr: FieldManager = null
var econ_stats: EconomyStatsManager = null
var trade_mgr = null

# ── Convenience forwards → managers (keeps all existing code working) ─────────
var MAX_FIELDS: int:
	get: return field_mgr.MAX_FIELDS if field_mgr else 10
var MAX_TOTAL_POP: int:
	get: return pop_mgr.MAX_TOTAL_POP if pop_mgr else 50
var all_fields: Array:
	get: return field_mgr.all_fields if field_mgr else []
var all_field_nodes: Array:
	get: return field_mgr.all_field_nodes if field_mgr else []
var field_assignment_map: Dictionary:
	get: return field_mgr.field_assignment_map if field_mgr else {}
var next_field_id: int:
	get: return field_mgr.next_field_id if field_mgr else 3
	set(v):
		if field_mgr: field_mgr.next_field_id = v
var all_farmers: Array:
	get: return pop_mgr.all_farmers if pop_mgr else []
var all_bakers: Array:
	get: return pop_mgr.all_bakers if pop_mgr else []
var households: Array:
	get: return pop_mgr.households if pop_mgr else []
var next_farmer_id: int:
	get: return pop_mgr.next_farmer_id if pop_mgr else 2
	set(v):
		if pop_mgr: pop_mgr.next_farmer_id = v
var next_baker_id: int:
	get: return pop_mgr.next_baker_id if pop_mgr else 2
	set(v):
		if pop_mgr: pop_mgr.next_baker_id = v

var AgentScene: PackedScene = null
var spawn_info_label: Label = null

# Placement mode state
enum PlaceMode { NONE, FIELD, FARMER, BAKER, HOUSEHOLD }
var place_mode: PlaceMode = PlaceMode.NONE
var placement_cursor: ColorRect = null  # Ghost preview at mouse
var place_mode_label: Label = null      # Status text showing current mode

# Household management
var market_node: Node2D = null
var event_bus: EventBus = null
var economy_config: Dictionary = {}

# Labor market (occupational mobility + migration)
var labor_market: LaborMarket = null
var pending_conversions: Array = []  # [{household, role, days_remaining}]

# UI Labels
var farmer_money_label: Label
var farmer_seeds_label: Label
var farmer_wheat_label: Label
var farmer_bread_label: Label
var farmer_days_until_starve_label: Label
var farmer_starving_label: Label
var farmer_status_label: Label
var market_money_label: Label
var market_seeds_label: Label
var market_wheat_label: Label
var market_wheat_cap_label: Label
var market_bread_label: Label
var market_bread_cap_label: Label
var wheat_price_label: Label
var bread_price_label: Label
var baker_money_label: Label
var baker_wheat_label: Label
var baker_flour_label: Label
var baker_bread_label: Label
var baker_food_bread_label: Label
var baker_days_until_starve_label: Label
var baker_starving_label: Label
var baker_status_label: Label
var household_money_label: Label
var household_bread_label: Label
var household_bread_consumed_label: Label
var household_hunger_label: Label
var household_starving_label: Label
var household_status_label: Label
var farmer_inventory_label: Label
var baker_inventory_label: Label
var household_inventory_label: Label
var event_log: RichTextLabel
var export_log_button: Button
var jump_to_bottom_button: Button
var sim_speed_label: Label
var prosperity_score_label: Label
var wealth_score_label: Label
var food_score_label: Label
var starvation_score_label: Label
var trade_score_label: Label
var population_info_label: Label
var total_pop_label: Label

# Economy HUD bar (replaces scrollable sidebar cards)
var eco_sim_label: Label        = null   # Day · Speed
var eco_village_label: Label    = null   # Pop + Fields
var eco_market_label: Label     = null   # Wheat/Bread prices + inventory
var eco_prosperity_label: Label = null   # Prosperity score + inputs
var eco_farmer_label: Label     = null   # Baseline farmer compact stats
var eco_baker_label: Label      = null   # Baseline baker compact stats
var _current_speed: float = 1.0          # Tracks sim speed for eco bar

# Pause control
var _is_paused: bool = false
var _pause_btn: Button = null

# Simulation failure state
var sim_failed: bool = false
var _sim_fail_banner: PanelContainer = null

# Camera
var _camera: Camera2D = null

# Pop Inspector
var selected_pop: Node = null
var pop_inspector_panel: Control = null
var pop_inspector_title: Label = null
var pop_inspector_role: Label = null
var pop_inspector_body: RichTextLabel = null
var pop_history_label: RichTextLabel = null

# Forwarded to managers (kept for backward compat)
var _next_person_id: int:
	get: return pop_mgr._next_person_id if pop_mgr else 1
	set(v):
		if pop_mgr: pop_mgr._next_person_id = v

var log_lines: Array[String] = []
var log_buffer: Array[String] = []  # Full log for export (not trimmed)
var user_at_bottom: bool = true  # Track if user is at bottom for sticky auto-scroll
const MAX_LOG_LINES: int = 200
const SCROLL_THRESHOLD: int = 50  # Pixels from bottom to consider "at bottom"


func _ready() -> void:
	# Keep main node + UI alive (responsive) while simulation is paused
	process_mode = Node.PROCESS_MODE_ALWAYS
	var ui_node := get_node_or_null("UI")
	if ui_node != null:
		ui_node.process_mode = Node.PROCESS_MODE_ALWAYS

	# ── Create managers (before anything else accesses forwarded properties) ──
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

	# Camera (world view with zoom/pan)
	var cam := Camera2D.new()
	cam.name = "WorldCamera"
	cam.set_script(preload("res://scripts/camera_controller.gd"))
	cam.position = Vector2(300, 400)
	cam.zoom = Vector2(1.5, 1.5)
	add_child(cam)
	cam.make_current()
	_camera = cam

	# Load economy config
	_load_economy_config()
	
	# Load the unified Agent.tscn used for all spawns
	_resolve_agent_scene()
	
	# Create simulation systems
	# All simulation nodes are marked PAUSABLE so get_tree().paused = true stops them.
	# (Main node itself is PROCESS_MODE_ALWAYS so _input/_process keep working for UI.)
	clock = SimulationClock.new()
	clock.name = "SimulationClock"
	add_child(clock)
	clock.process_mode = Node.PROCESS_MODE_PAUSABLE
	clock.ticked.connect(_on_tick)
	clock.speed_changed.connect(_on_speed_changed)
	
	bus = EventBus.new()
	bus.name = "EventBus"
	add_child(bus)
	bus.process_mode = Node.PROCESS_MODE_PAUSABLE
	bus.event_logged.connect(_on_event_logged)
	
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
	
	# Store EventBus reference for spawn function
	event_bus = bus

	# Wire managers now that event_bus exists
	field_mgr.bind(bus)
	
	# Get references to scene nodes
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
	
	# Create market instance
	market = Market.new()
	market.name = "Market"
	add_child(market)
	market.process_mode = Node.PROCESS_MODE_PAUSABLE

	# Wire calendar day_changed to market for daily price adjustments
	calendar.day_changed.connect(market.on_day_changed)
	# Wire calendar day_changed to labor market handler
	calendar.day_changed.connect(_on_calendar_day_changed)
	
	# Wire event bus and market to all initial agents
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
	
	# Wire HungerNeed components (must happen before set_role)
	var farmer_inv: Inventory = farmer.get_node("Inventory") as Inventory
	var farmer_hunger: HungerNeed = farmer.get_node("HungerNeed") as HungerNeed
	farmer_hunger.bind("Farmer", farmer_inv, bus, calendar)
	
	var baker_inv: Inventory = baker.get_node("Inventory") as Inventory
	var baker_hunger: HungerNeed = baker.get_node("HungerNeed") as HungerNeed
	baker_hunger.bind("Baker", baker_inv, bus, calendar)
	
	var household_inv: Inventory = household_agent.get_node("Inventory") as Inventory
	var household_hunger: HungerNeed = household_agent.get_node("HungerNeed") as HungerNeed
	household_hunger.bind("Household", household_inv, bus, calendar)
	
	# Bind food reserves (must happen before set_role so job activate() sees them)
	var farmer_food_reserve: FoodReserve = farmer.get_node("FoodReserve") as FoodReserve
	if farmer_food_reserve:
		farmer_food_reserve.bind(farmer_inv, farmer_hunger, market, farmer.get_node("Wallet") as Wallet, bus, "Farmer")
	var baker_food_reserve: FoodReserve = baker.get_node("FoodReserve") as FoodReserve
	if baker_food_reserve:
		baker_food_reserve.bind(baker_inv, baker_hunger, market, baker.get_node("Wallet") as Wallet, bus, "Baker")
	var household_food_reserve: FoodReserve = household_agent.get_node("FoodReserve") as FoodReserve
	if household_food_reserve:
		household_food_reserve.bind(household_inv, household_hunger, market, household_agent.get_node("Wallet") as Wallet, bus, "Household")
	
	# Activate roles — creates job components, sets sprite colors, adds to groups
	farmer.set_role("Farmer")
	farmer.set_route_nodes(house, market_node)
	farmer.set_fields([field1_plot, field2_plot], [field1_node, field2_node])
	
	baker.set_role("Baker")
	baker.set_locations(bakery, market_node)
	
	household_agent.set_role("Household")
	household_agent.set_locations(household_home, market_node)
	
	# Register baseline household for prosperity tracking
	pop_mgr.register_household(household_agent)
	
	# Connect death signal
	household_agent.agent_died.connect(_on_household_died)
	
	# Bind prosperity meter references
	prosperity_meter.bind_references(bus, market, households)
	
	# Initialize labor market
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
	# Connect labor market signals
	labor_market.migrate_requested.connect(_on_migrate_requested)
	labor_market.role_switch_requested.connect(_on_role_switch_requested)
	
	# Initialize trade manager (external import/export counterparty)
	trade_mgr = _TradeMgrClass.new()
	trade_mgr.name = "TradeManager"
	add_child(trade_mgr)
	trade_mgr.process_mode = Node.PROCESS_MODE_PAUSABLE
	trade_mgr.market = market
	trade_mgr.event_bus = bus
	trade_mgr.load_config(economy_config)

	# Assign persistent identities to the initial scene pops
	_assign_new_identity(farmer)
	_assign_new_identity(baker)
	_assign_new_identity(household_agent)

	# Get UI label references
	get_ui_labels()
	
	# Initial UI update
	update_ui()
	
	# Build spawn toolbar and economy HUD bar
	_build_spawn_toolbar()
	_build_economy_bar()

	# Bootstrap: seed market with initial inventory (exactly once per new run)
	_apply_market_seed()

	# Log startup
	bus.log("Tick 0: START")


func _process(_delta: float) -> void:
	update_ui()
	_update_spawn_info()
	_update_placement_cursor()
	_update_camera()


func _on_tick(tick: int) -> void:
	if sim_failed:
		return
	# Update calendar
	calendar.set_tick(tick)
	
	# Tick all field plots via manager
	field_mgr.tick_all()
	
	# Update tick for all agents (dynamic tracking)
	if market:
		market.set_tick(tick)
	for f in all_farmers:
		if f and is_instance_valid(f):
			f.set_tick(tick)
	for b in all_bakers:
		if b and is_instance_valid(b):
			b.set_tick(tick)
	
	# Tick all households
	for h in households:
		if h and is_instance_valid(h):
			h.set_tick(tick)
	
	# Update prosperity meter
	if prosperity_meter:
		prosperity_meter.update_prosperity(calendar.day_index)
		
		# [SCARCITY GUARD] Suppress pop growth during food scarcity — but NEVER when
		# population is already zero (we need at least one household to create demand).
		var suppress_spawn: bool = (
			labor_market != null and
			labor_market.should_suppress_spawn() and
			households.size() > 0
		)
		
		# Log spawn decision every 5 days to aid debugging
		if event_bus and calendar.day_index % 5 == 0:
			event_bus.log("[SPAWN CHECK] day=%d prosperity=%.3f threshold=%.2f suppress=%s households=%d" % [
				calendar.day_index,
				prosperity_meter.prosperity_score,
				prosperity_meter.PROSPERITY_THRESHOLD_TO_GROW,
				suppress_spawn,
				households.size()
			])
		
		if prosperity_meter.should_spawn_household(calendar.day_index) and not suppress_spawn:
			var spawn_pos = Vector2(randf_range(100, 700), randf_range(100, 500))
			spawn_household_at(spawn_pos)
	
	# Bread emergency liquidity override
	if market:
		market.check_bread_emergency(all_bakers)

	# Run audit checks — skip if either base agent has been freed by migration
	if farmer != null and is_instance_valid(farmer) and baker != null and is_instance_valid(baker):
		audit.audit(farmer, baker, market, bus, tick)


func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_pos


func _world_to_screen(world_pos: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform() * world_pos


func _update_camera() -> void:
	if _camera == null:
		return
	var positions: Array[Vector2] = []
	var all_entities: Array = []
	for f in all_farmers:
		if f and is_instance_valid(f):
			positions.append((f as Node2D).global_position)
			all_entities.append(f)
	for b in all_bakers:
		if b and is_instance_valid(b):
			positions.append((b as Node2D).global_position)
			all_entities.append(b)
	for h in households:
		if h and is_instance_valid(h):
			positions.append((h as Node2D).global_position)
			all_entities.append(h)
	for fn in all_field_nodes:
		if fn and is_instance_valid(fn):
			all_entities.append(fn)
	if not positions.is_empty():
		var centroid := Vector2.ZERO
		for p in positions:
			centroid += p
		centroid /= float(positions.size())
		_camera.update_centroid(centroid)
	if not all_entities.is_empty():
		_camera.update_bounds(all_entities)


func _load_economy_config() -> void:
	"""Load economy configuration from JSON file."""
	var config_path = "res://config/economy_config.json"
	if FileAccess.file_exists(config_path):
		var file = FileAccess.open(config_path, FileAccess.READ)
		if file:
			var json_text = file.get_as_text()
			file.close()
			var json = JSON.new()
			var parse_result = json.parse(json_text)
			if parse_result == OK:
				economy_config = json.data
				print("Main: Loaded economy config from ", config_path)
			else:
				push_error("Main: Failed to parse economy config: " + json.get_error_message())
	else:
		print("Main: Economy config not found at ", config_path, " - using defaults")


func _apply_market_seed() -> void:
	if market == null or market.market_seeded:
		return
	var seed_cfg: Dictionary = economy_config.get("market_seed", {})
	var seed_wheat: int = int(seed_cfg.get("initial_market_wheat", 40))
	var seed_bread: int = int(seed_cfg.get("initial_market_bread", 20))
	var seed_seeds: int = int(seed_cfg.get("initial_market_seeds", 0))
	market.seed_market(seed_wheat, seed_bread, seed_seeds)


func _resolve_agent_scene() -> void:
	"""Load the unified Agent.tscn used for all new spawns and role conversions."""
	if AgentScene != null:
		return
	var path := "res://scenes/Agent.tscn"
	if ResourceLoader.exists(path):
		AgentScene = load(path)
		print("Main: AgentScene loaded from ", path)
	else:
		push_error("FATAL: AgentScene not found at " + path)


func _build_spawn_toolbar() -> void:
	"""Build the top toolbar row inside LeftColumn (proper container child)."""
	var toolbar = PanelContainer.new()
	toolbar.name = "SpawnToolbar"

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.15, 0.92)
	style.border_color = Color(0.4, 0.4, 0.5, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	toolbar.add_theme_stylebox_override("panel", style)

	var vbox_outer = VBoxContainer.new()
	vbox_outer.add_theme_constant_override("separation", 4)
	toolbar.add_child(vbox_outer)

	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	vbox_outer.add_child(hbox)

	var title = Label.new()
	title.text = "BUILD"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.85, 0.85, 0.65))
	hbox.add_child(title)

	hbox.add_child(VSeparator.new())

	var field_btn = _create_toolbar_button("Field", Color(0.4, 0.3, 0.1), "Click to place a farm field")
	field_btn.pressed.connect(func(): _enter_placement_mode(PlaceMode.FIELD))
	hbox.add_child(field_btn)

	var farmer_btn = _create_toolbar_button("Farmer", Color(0.2, 0.8, 0.2), "Click to place a new farmer")
	farmer_btn.pressed.connect(func(): _enter_placement_mode(PlaceMode.FARMER))
	hbox.add_child(farmer_btn)

	var baker_btn = _create_toolbar_button("Baker", Color(0.8, 0.6, 0.2), "Click to place a new baker")
	baker_btn.pressed.connect(func(): _enter_placement_mode(PlaceMode.BAKER))
	hbox.add_child(baker_btn)

	var household_btn = _create_toolbar_button("Household", Color(0.8, 0.2, 0.8), "Click to place a new household")
	household_btn.pressed.connect(func(): _enter_placement_mode(PlaceMode.HOUSEHOLD))
	hbox.add_child(household_btn)

	hbox.add_child(VSeparator.new())

	var speed_down = Button.new()
	speed_down.text = "<<"
	speed_down.tooltip_text = "Slow down simulation"
	speed_down.pressed.connect(func(): clock.decrease_speed())
	hbox.add_child(speed_down)

	var speed_label = Label.new()
	speed_label.text = "Speed: 1.0x"
	speed_label.name = "ToolbarSpeedLabel"
	speed_label.add_theme_font_size_override("font_size", 18)
	hbox.add_child(speed_label)
	sim_speed_label = speed_label

	var speed_up = Button.new()
	speed_up.text = ">>"
	speed_up.tooltip_text = "Speed up simulation"
	speed_up.pressed.connect(func(): clock.increase_speed())
	hbox.add_child(speed_up)

	hbox.add_child(VSeparator.new())

	spawn_info_label = Label.new()
	spawn_info_label.text = ""
	spawn_info_label.add_theme_font_size_override("font_size", 18)
	spawn_info_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	hbox.add_child(spawn_info_label)
	_update_spawn_info()

	hbox.add_child(VSeparator.new())

	_pause_btn = Button.new()
	_pause_btn.text = "⏸ Pause"
	_pause_btn.tooltip_text = "Pause / resume simulation  [P]"
	_pause_btn.custom_minimum_size = Vector2(100, 34)
	var pb_style := StyleBoxFlat.new()
	pb_style.bg_color = Color(0.18, 0.18, 0.23, 0.92)
	pb_style.border_color = Color(0.82, 0.72, 0.28, 0.85)
	pb_style.set_border_width_all(2)
	pb_style.set_corner_radius_all(4)
	pb_style.set_content_margin_all(5)
	_pause_btn.add_theme_stylebox_override("normal", pb_style)
	var pb_hover := pb_style.duplicate() as StyleBoxFlat
	pb_hover.bg_color = Color(0.26, 0.26, 0.32, 0.95)
	_pause_btn.add_theme_stylebox_override("hover", pb_hover)
	_pause_btn.pressed.connect(_toggle_pause)
	hbox.add_child(_pause_btn)

	# Center camera button
	var center_btn := Button.new()
	center_btn.text = "Center"
	center_btn.tooltip_text = "Recenter camera on town  [Space]"
	center_btn.custom_minimum_size = Vector2(80, 34)
	center_btn.pressed.connect(_recenter_camera)
	hbox.add_child(center_btn)

	# Second row: placement mode status
	place_mode_label = Label.new()
	place_mode_label.text = ""
	place_mode_label.add_theme_font_size_override("font_size", 18)
	place_mode_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.5))
	vbox_outer.add_child(place_mode_label)

	# Insert toolbar into LeftColumn at index 0 (above WorldSpacer)
	var left_column = get_node("UI/HUDRoot/Layout/LeftColumn")
	left_column.add_child(toolbar)
	left_column.move_child(toolbar, 0)

	# WorldSpacer gets the click receiver and placement cursor
	var world_spacer = get_node("UI/HUDRoot/Layout/LeftColumn/WorldSpacer")

	var click_receiver := Control.new()
	click_receiver.name = "WorldClickReceiver"
	click_receiver.set_anchors_preset(Control.PRESET_FULL_RECT)
	click_receiver.mouse_filter = Control.MOUSE_FILTER_IGNORE
	world_spacer.add_child(click_receiver)

	placement_cursor = ColorRect.new()
	placement_cursor.name = "PlacementCursor"
	placement_cursor.size = Vector2(30, 30)
	placement_cursor.position = Vector2(-100, -100)
	placement_cursor.color = Color(1, 1, 1, 0.4)
	placement_cursor.visible = false
	placement_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	world_spacer.add_child(placement_cursor)


func _build_economy_bar() -> void:
	"""Build the economy HUD strip as a proper container child of LeftColumn."""
	var bar := PanelContainer.new()
	bar.name = "EcoBar"

	var bar_style := StyleBoxFlat.new()
	bar_style.bg_color = Color(0.07, 0.07, 0.10, 0.93)
	bar_style.border_color = Color(0.28, 0.28, 0.42, 0.85)
	bar_style.set_border_width_all(1)
	bar_style.set_corner_radius_all(5)
	bar_style.content_margin_left   = 10
	bar_style.content_margin_right  = 10
	bar_style.content_margin_top    = 6
	bar_style.content_margin_bottom = 6
	bar.add_theme_stylebox_override("panel", bar_style)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 0)
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bar.add_child(hbox)

	eco_sim_label        = _add_eco_section(hbox, "SIM",        Color(0.65, 0.75, 1.00), false)
	eco_village_label    = _add_eco_section(hbox, "VILLAGE",    Color(0.40, 0.90, 0.50), false)
	eco_market_label     = _add_eco_section(hbox, "MARKET",     Color(0.95, 0.65, 0.25), true)
	eco_prosperity_label = _add_eco_section(hbox, "PROSPERITY", Color(1.00, 0.85, 0.25), false)
	eco_farmer_label     = _add_eco_section(hbox, "FARMER",     Color(0.20, 1.00, 0.20), true)
	eco_baker_label      = _add_eco_section(hbox, "BAKER",      Color(1.00, 0.75, 0.20), true)

	# Insert into LeftColumn at index 1 (after toolbar, before WorldSpacer)
	var left_column := get_node("UI/HUDRoot/Layout/LeftColumn")
	left_column.add_child(bar)
	left_column.move_child(bar, 1)


func _add_eco_section(hbox: HBoxContainer, title_text: String, accent: Color, expand: bool) -> Label:
	"""Add one labelled section to the economy bar and return its content Label."""
	if hbox.get_child_count() > 0:
		var sep := VSeparator.new()
		var sep_style := StyleBoxFlat.new()
		sep_style.bg_color = Color(0.30, 0.30, 0.45, 0.55)
		sep_style.content_margin_top    = 5
		sep_style.content_margin_bottom = 5
		sep.add_theme_stylebox_override("separator", sep_style)
		hbox.add_child(sep)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",  10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top",   3)
	margin.add_theme_constant_override("margin_bottom", 3)
	if expand:
		margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 1)
	margin.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = title_text
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.add_theme_color_override("font_color", accent)
	vbox.add_child(title_lbl)

	var content_lbl := Label.new()
	content_lbl.text = "..."
	content_lbl.add_theme_font_size_override("font_size", 18)
	content_lbl.add_theme_color_override("font_color", Color(0.93, 0.93, 0.93))
	vbox.add_child(content_lbl)

	return content_lbl


func _create_toolbar_button(text: String, color: Color, tooltip: String) -> Button:
	"""Create a styled toolbar button with a color indicator."""
	var btn = Button.new()
	btn.text = text
	btn.tooltip_text = tooltip
	btn.custom_minimum_size = Vector2(70, 30)
	
	# Style the button
	var normal_style = StyleBoxFlat.new()
	normal_style.bg_color = Color(0.2, 0.2, 0.25, 0.9)
	normal_style.border_color = color
	normal_style.set_border_width_all(2)
	normal_style.set_corner_radius_all(4)
	normal_style.set_content_margin_all(4)
	btn.add_theme_stylebox_override("normal", normal_style)
	
	var hover_style = normal_style.duplicate()
	hover_style.bg_color = Color(0.3, 0.3, 0.35, 0.95)
	btn.add_theme_stylebox_override("hover", hover_style)
	
	var pressed_style = normal_style.duplicate()
	pressed_style.bg_color = color.lerp(Color.BLACK, 0.5)
	btn.add_theme_stylebox_override("pressed", pressed_style)
	
	return btn


func _update_spawn_info() -> void:
	if spawn_info_label:
		spawn_info_label.text = "Fields: %d | Farmers: %d | Bakers: %d | Pop: %d" % [
			all_fields.size(), all_farmers.size(), all_bakers.size(), households.size()
		]


func _input(event: InputEvent) -> void:
	# ── Keyboard shortcuts (run before GUI so hotkeys always work) ────────────
	if clock != null and not sim_failed:
		if event.is_action_pressed("speed_up"):
			clock.increase_speed()
			get_viewport().set_input_as_handled()
			return
		elif event.is_action_pressed("speed_down"):
			clock.decrease_speed()
			get_viewport().set_input_as_handled()
			return

	# Right-click cancel placement (must run in _input so it takes priority over camera pan)
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		if place_mode != PlaceMode.NONE:
			_cancel_placement()
			get_viewport().set_input_as_handled()
			return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_P and not event.ctrl_pressed and not event.alt_pressed:
			_toggle_pause()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_SPACE and not event.ctrl_pressed and not event.alt_pressed:
			_recenter_camera()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_ESCAPE and place_mode != PlaceMode.NONE:
			_cancel_placement()
			get_viewport().set_input_as_handled()
			return


func _unhandled_input(event: InputEvent) -> void:
	# Runs AFTER GUI buttons/panels have had a chance to consume clicks.

	# Left-click: pop selection + placement (only reaches here if no GUI ate it)
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var screen_pos: Vector2 = event.position

		# Find the closest pop within 20 screen-px of the click
		var best_pop: Node = null
		var best_dist: float = 20.0
		for group_name: String in ["farmers", "bakers", "households"]:
			for pop: Node in get_tree().get_nodes_in_group(group_name):
				if not is_instance_valid(pop):
					continue
				var pop2d := pop as Node2D
				if pop2d == null:
					continue
				var pop_screen: Vector2 = _world_to_screen(pop2d.global_position)
				var d: float = screen_pos.distance_to(pop_screen)
				if d < best_dist:
					best_dist = d
					best_pop = pop

		if best_pop != null:
			select_pop(best_pop)
			get_viewport().set_input_as_handled()
			return

		# Nothing was clicked — handle placement if active
		if place_mode != PlaceMode.NONE:
			var world_pos: Vector2 = _screen_to_world(screen_pos)
			_place_entity_at(world_pos)
			get_viewport().set_input_as_handled()


func _on_world_click(_event: InputEvent) -> void:
	pass  # Superseded by _input() above; kept so old signal connections don't crash


func _on_speed_changed(new_speed: float) -> void:
	_current_speed = new_speed
	if sim_speed_label and not _is_paused:
		sim_speed_label.text = "Speed: %.1fx" % new_speed


func _recenter_camera() -> void:
	if _camera == null:
		return
	var positions: Array[Vector2] = []
	for f in all_farmers:
		if f and is_instance_valid(f):
			positions.append((f as Node2D).global_position)
	for b in all_bakers:
		if b and is_instance_valid(b):
			positions.append((b as Node2D).global_position)
	for h in households:
		if h and is_instance_valid(h):
			positions.append((h as Node2D).global_position)
	if positions.is_empty():
		_camera.recenter(Vector2(300, 400))
		return
	var centroid := Vector2.ZERO
	for p in positions:
		centroid += p
	centroid /= float(positions.size())
	_camera.recenter(centroid)


func _toggle_pause() -> void:
	if sim_failed:
		return
	_is_paused = !_is_paused
	get_tree().paused = _is_paused

	# Update pause button appearance
	if _pause_btn != null:
		if _is_paused:
			_pause_btn.text = "▶ Resume"
			var s := StyleBoxFlat.new()
			s.bg_color        = Color(0.28, 0.14, 0.02, 0.95)
			s.border_color    = Color(1.00, 0.60, 0.10, 0.95)
			s.set_border_width_all(2)
			s.set_corner_radius_all(4)
			s.set_content_margin_all(5)
			_pause_btn.add_theme_stylebox_override("normal", s)
			var sh := s.duplicate() as StyleBoxFlat
			sh.bg_color = Color(0.36, 0.20, 0.04, 1.0)
			_pause_btn.add_theme_stylebox_override("hover", sh)
		else:
			_pause_btn.text = "⏸ Pause"
			var s := StyleBoxFlat.new()
			s.bg_color        = Color(0.18, 0.18, 0.23, 0.92)
			s.border_color    = Color(0.82, 0.72, 0.28, 0.85)
			s.set_border_width_all(2)
			s.set_corner_radius_all(4)
			s.set_content_margin_all(5)
			_pause_btn.add_theme_stylebox_override("normal", s)
			var sh := s.duplicate() as StyleBoxFlat
			sh.bg_color = Color(0.26, 0.26, 0.32, 0.95)
			_pause_btn.add_theme_stylebox_override("hover", sh)

	# Update speed label
	if sim_speed_label != null:
		sim_speed_label.text = "PAUSED" if _is_paused else "Speed: %.1fx" % _current_speed


func _trigger_sim_failure(day: int, tick: int) -> void:
	sim_failed = true
	get_tree().paused = true

	var fail_line: String = "[SIM FAIL] Town extinct day=%d tick=%d" % [day, tick]
	print(fail_line)
	if event_bus:
		event_bus.log(fail_line)

	log_population_snapshot()

	var m_bread: int = market.bread if market else -1
	var m_wheat: int = market.wheat if market else -1
	var m_seeds: int = market.seeds if market else -1

	var hyst_bread_sell: bool = not market.can_producer_sell("bread") if market else false
	var hyst_bread_prod: bool = not market.can_producer_produce("bread") if market else false
	var hyst_wheat_sell: bool = not market.can_producer_sell("wheat") if market else false
	var hyst_wheat_prod: bool = not market.can_producer_produce("wheat") if market else false

	var training: int = pending_conversions.size()

	if event_bus:
		event_bus.log(
			"[SIM FAIL SNAPSHOT] day=%d tick=%d total=%d market(bread=%d wheat=%d seeds=%d) hysteresis(bread_sell=%s bread_prod=%s wheat_sell=%s wheat_prod=%s) training=%d" % [
				day, tick, pop_mgr.count(),
				m_bread, m_wheat, m_seeds,
				hyst_bread_sell, hyst_bread_prod, hyst_wheat_sell, hyst_wheat_prod,
				training
			])

	_show_sim_fail_banner(day)

	if _pause_btn != null:
		_pause_btn.text = "EXTINCT"
		_pause_btn.disabled = true


func _show_sim_fail_banner(day: int) -> void:
	if _sim_fail_banner != null:
		return
	var ui_node := get_node_or_null("UI")
	if ui_node == null:
		return

	_sim_fail_banner = PanelContainer.new()
	_sim_fail_banner.name = "SimStatusBanner"

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.55, 0.05, 0.05, 0.95)
	style.border_color = Color(1.0, 0.2, 0.2, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	_sim_fail_banner.add_theme_stylebox_override("panel", style)

	var label := Label.new()
	label.text = "TOWN EXTINCT — Simulation paused  (day %d)" % day
	label.add_theme_font_size_override("font_size", 28)
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.85))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sim_fail_banner.add_child(label)

	_sim_fail_banner.layout_mode = 1
	_sim_fail_banner.anchors_preset = Control.PRESET_CENTER_TOP
	_sim_fail_banner.anchor_left = 0.5
	_sim_fail_banner.anchor_right = 0.5
	_sim_fail_banner.anchor_top = 0.0
	_sim_fail_banner.offset_top = 60
	_sim_fail_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	ui_node.add_child(_sim_fail_banner)


func _on_event_logged(msg: String) -> void:
	log_lines.append(msg)
	log_buffer.append(msg)  # Keep full log for export
	
	# Trim display log to max lines
	while log_lines.size() > MAX_LOG_LINES:
		log_lines.pop_front()
	
	# Update event log display
	if event_log:
		event_log.clear()
		for line in log_lines:
			event_log.append_text(line + "\n")
		
		# Only auto-scroll if user is at bottom
		if user_at_bottom:
			event_log.scroll_to_line(event_log.get_line_count())


func _on_log_scroll(_value: float) -> void:
	# Check if user scrolled away from bottom
	if event_log:
		var vscroll = event_log.get_v_scroll_bar()
		if vscroll:
			var max_scroll = vscroll.max_value - vscroll.page
			var current_scroll = vscroll.value
			# User is at bottom if within threshold pixels
			user_at_bottom = (max_scroll - current_scroll) <= SCROLL_THRESHOLD


func _on_jump_to_bottom() -> void:
	# Re-enable auto-scroll and scroll to bottom
	user_at_bottom = true
	if event_log:
		event_log.scroll_to_line(event_log.get_line_count())


func export_log() -> void:
	print("export_log() called - buffer size: ", log_buffer.size())
	
	# Create a snapshot of the buffer to avoid modification during iteration
	var log_snapshot = log_buffer.duplicate()
	
	var dir = DirAccess.open("user://")
	if not dir:
		print("ERROR: Could not open user:// directory")
		if event_log:
			event_log.append_text("[ERROR] Could not access user directory\n")
		return
	
	print("Opened user:// directory")
	
	if not dir.dir_exists("logs"):
		print("Creating logs directory")
		var err = dir.make_dir("logs")
		if err != OK:
			print("ERROR: Failed to create logs directory: ", err)
			if event_log:
				event_log.append_text("[ERROR] Failed to create logs directory\n")
			return
	
	var datetime = Time.get_datetime_dict_from_system()
	var filename = "economy_log_%04d-%02d-%02d_%02d-%02d-%02d.txt" % [
		datetime.year, datetime.month, datetime.day,
		datetime.hour, datetime.minute, datetime.second
	]
	var path = "user://logs/" + filename
	print("Attempting to save to: ", path)
	
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		print("File opened successfully, writing ", log_snapshot.size(), " lines...")
		for line in log_snapshot:
			file.store_line(line)
		file.close()
		print("File closed successfully")
		
		# Convert user:// path to absolute file system path
		var abs_path = ProjectSettings.globalize_path(path)
		print("Absolute path: ", abs_path)
		
		# Update event log directly to avoid recursion
		if event_log:
			event_log.append_text("[EXPORT] Log saved to: %s\n" % abs_path)
			event_log.append_text("[EXPORT] (%d lines written)\n" % log_snapshot.size())
	else:
		var err = FileAccess.get_open_error()
		print("ERROR: Failed to open file for writing: ", err)
		if event_log:
			event_log.append_text("[ERROR] Failed to export log (Error: %d)\n" % err)


# ── Node-name fixup guard ────────────────────────────────────────────────────

func _fixup_node_name(node: Node, role_prefix: String) -> void:
	var n: String = node.name
	if n.begins_with("@") or "CharacterBody2D@" in n:
		var fixed: String = "%s_%d" % [role_prefix, pop_mgr._next_person_id]
		var msg: String = "[NAME FIXUP] %s → %s (auto-generated name corrected)" % [n, fixed]
		node.name = fixed
		print(msg)
		if event_bus:
			event_bus.log(msg)


# ── Identity helpers (delegate to PopulationManager) ─────────────────────────

func _new_person_id() -> int:
	return pop_mgr.new_person_id()


func _assign_new_identity(pop: Node) -> void:
	pop_mgr.assign_identity(pop)


func _transfer_identity_data(to_pop: Node, pid: int, pname: String,
		events: Array, new_role: String,
		skill_f: float = 0.25, skill_b: float = 0.25) -> void:
	pop_mgr.transfer_identity_data(to_pop, pid, pname, events, new_role, skill_f, skill_b)


# ── Global cashflow helpers (delegate to EconomyStatsManager) ─────────────────

func _roll_global_cashflow() -> void:
	econ_stats.roll_daily()


func global_role_rolling_7d_sum(role: String) -> float:
	return econ_stats.role_rolling_7d_sum(role)


func global_role_rolling_7d_avg(role: String) -> float:
	return econ_stats.role_rolling_7d_avg(role)


func get_ui_labels() -> void:
	var log_vbox = get_node_or_null("UI/HUDRoot/Layout/Sidebar/SidebarVBox/LogPanel/LogVBox")
	if log_vbox:
		event_log = log_vbox.get_node_or_null("EventLog")
		export_log_button = log_vbox.get_node_or_null("ExportLogButton")
		if export_log_button:
			export_log_button.pressed.connect(export_log)
		if log_vbox.has_node("JumpToBottomButton"):
			jump_to_bottom_button = log_vbox.get_node("JumpToBottomButton")
			jump_to_bottom_button.pressed.connect(_on_jump_to_bottom)

	# Connect scroll detection for sticky auto-scroll
	if event_log:
		var vscroll = event_log.get_v_scroll_bar()
		if vscroll:
			vscroll.value_changed.connect(_on_log_scroll)

	# Selected-pop panel — anchored to the bottom of the screen
	pop_inspector_panel = get_node_or_null("UI/PopInspector")
	if pop_inspector_panel:
		pop_inspector_title = pop_inspector_panel.get_node_or_null("ContentRow/NameCol/PopInspectorTitle")
		pop_inspector_role  = pop_inspector_panel.get_node_or_null("ContentRow/NameCol/PopInspectorRole")
		pop_inspector_body  = pop_inspector_panel.get_node_or_null("ContentRow/StatCol/PopInspectorBody")
		var close_btn = pop_inspector_panel.get_node_or_null("ContentRow/CloseCol/PopInspectorClose")
		if close_btn:
			close_btn.pressed.connect(_on_inspector_close)

		# ── Scrollable life-events history (added below the stat body) ──────────
		var stat_col := pop_inspector_panel.get_node_or_null("ContentRow/StatCol") as VBoxContainer
		if stat_col != null and pop_inspector_body != null:
			# Auto-size to content height — no scrollbar on the stat block
			pop_inspector_body.fit_content = true
			pop_inspector_body.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

			var hsep_hist := HSeparator.new()
			stat_col.add_child(hsep_hist)

			var scroll := ScrollContainer.new()
			scroll.name = "HistoryScroll"
			scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
			scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			stat_col.add_child(scroll)

			pop_history_label = RichTextLabel.new()
			pop_history_label.name = "LifeHistory"
			pop_history_label.bbcode_enabled = true
			pop_history_label.fit_content = true
			pop_history_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			pop_history_label.add_theme_font_size_override("normal_font_size", 16)
			pop_history_label.add_theme_color_override("default_color", Color(0.72, 0.72, 0.72, 1.0))
			scroll.add_child(pop_history_label)

		# Dark semi-transparent panel background
		var panel_style := StyleBoxFlat.new()
		panel_style.bg_color = Color(0.07, 0.07, 0.10, 0.93)
		panel_style.border_color = Color(0.28, 0.28, 0.42, 0.75)
		panel_style.set_border_width_all(1)
		panel_style.content_margin_left   = 14
		panel_style.content_margin_right  = 14
		panel_style.content_margin_top    = 10
		panel_style.content_margin_bottom = 10
		pop_inspector_panel.add_theme_stylebox_override("panel", panel_style)

	# Connect pop_clicked for the initial scene agents
	if is_instance_valid(farmer):
		farmer.pop_clicked.connect(select_pop)
	if is_instance_valid(baker):
		baker.pop_clicked.connect(select_pop)
	if is_instance_valid(household_agent):
		household_agent.pop_clicked.connect(select_pop)


func update_ui() -> void:
	_update_eco_bar()
	update_inspector()


func _update_eco_bar() -> void:
	"""Refresh all six economy-bar section labels."""
	# SIM
	if eco_sim_label and calendar:
		eco_sim_label.text = "Day %d\n%.1f×" % [calendar.day_index, _current_speed]

	# VILLAGE
	if eco_village_label:
		var _f: int = get_tree().get_nodes_in_group("farmers").size()
		var _b: int = get_tree().get_nodes_in_group("bakers").size()
		var _h: int = get_tree().get_nodes_in_group("households").size()
		eco_village_label.text = "Pop: %d  H:%d F:%d B:%d\nFields: %d/%d" % [
			_h + _f + _b, _h, _f, _b,
			all_field_nodes.size(), MAX_FIELDS
		]

	# MARKET
	if eco_market_label and market:
		eco_market_label.text = (
			"Wheat %d/%d · $%.2f\nBread %d/%d · $%.2f" % [
				market.wheat, market.wheat_capacity, market.wheat_price,
				market.bread, market.bread_capacity, market.bread_price
			]
		)

	# PROSPERITY
	if eco_prosperity_label and prosperity_meter:
		var w: float = prosperity_meter.prosperity_inputs.get("wealth_health",       0.0)
		var f: float = prosperity_meter.prosperity_inputs.get("food_security",       0.0)
		var s: float = prosperity_meter.prosperity_inputs.get("starvation_pressure", 0.0)
		var t: float = prosperity_meter.prosperity_inputs.get("trade_activity",      0.0)
		eco_prosperity_label.text = "★ %.2f\nW:%.2f F:%.2f S:%.2f T:%.2f" % [
			prosperity_meter.prosperity_score, w, f, s, t
		]

	# FARMER (baseline)
	if eco_farmer_label:
		if farmer and is_instance_valid(farmer):
			var fh: HungerNeed        = farmer.get_node("HungerNeed")        as HungerNeed
			var fi: Inventory         = farmer.get_node("Inventory")         as Inventory
			var fw: Wallet            = farmer.get_node("Wallet")            as Wallet
			var fc: InventoryCapacity = farmer.get_node("InventoryCapacity") as InventoryCapacity
			eco_farmer_label.text = "$%.0f  S:%d W:%d Br:%d  ♥%d/%d\n%s  Inv:%d/%d" % [
				fw.money,
				fi.get_qty("seeds"), fi.get_qty("wheat"), fi.get_qty("bread"),
				fh.hunger_days, fh.hunger_max_days,
				farmer.get_status_text(),
				fc.current_total(), fc.max_items
			]
		else:
			eco_farmer_label.text = "(none)"

	# BAKER (baseline)
	if eco_baker_label:
		if baker and is_instance_valid(baker):
			var bh: HungerNeed        = baker.get_node("HungerNeed")        as HungerNeed
			var bi: Inventory         = baker.get_node("Inventory")         as Inventory
			var bw: Wallet            = baker.get_node("Wallet")            as Wallet
			var bc: InventoryCapacity = baker.get_node("InventoryCapacity") as InventoryCapacity
			eco_baker_label.text = "$%.0f  W:%d Fl:%d Br:%d  ♥%d/%d\n%s  Inv:%d/%d" % [
				bw.money,
				bi.get_qty("wheat"), bi.get_qty("flour"), bi.get_qty("bread"),
				bh.hunger_days, bh.hunger_max_days,
				baker.get_status_text(),
				bc.current_total(), bc.max_items
			]
		else:
			eco_baker_label.text = "(none)"


func get_total_population() -> int:
	return pop_mgr.count()


func log_population_snapshot() -> void:
	var h: int = get_tree().get_nodes_in_group("households").size()
	var f: int = get_tree().get_nodes_in_group("farmers").size()
	var b: int = get_tree().get_nodes_in_group("bakers").size()
	var line: String = "[POP SNAPSHOT] H=%d F=%d B=%d Total=%d" % [h, f, b, pop_mgr.count()]
	print(line)
	if event_bus:
		event_bus.log(line)


# ============================================================================
# POP INSPECTOR — click-to-inspect any agent
# ============================================================================

func select_pop(pop: Node) -> void:
	"""Called when any pop emits pop_clicked. Opens the inspector panel."""
	selected_pop = pop
	update_inspector()


func _on_inspector_close() -> void:
	selected_pop = null
	if pop_inspector_panel:
		pop_inspector_panel.visible = false


func update_inspector() -> void:
	"""Refresh the inspector panel. Called every UI update tick."""
	if pop_inspector_panel == null:
		return
	# Clear selection if the selected pop was freed (migration/conversion/starvation)
	if selected_pop == null or not is_instance_valid(selected_pop):
		selected_pop = null
		pop_inspector_panel.visible = false
		return
	pop_inspector_panel.visible = true
	if not selected_pop.has_method("get_inspector_data"):
		if pop_inspector_body:
			pop_inspector_body.text = "(no inspector data available)"
		return
	var d: Dictionary = selected_pop.get_inspector_data()

	if pop_inspector_title:
		pop_inspector_title.text = d.get("person_name", d.get("name", "?"))
	if pop_inspector_role:
		pop_inspector_role.text = d.get("role", "?")

	if not pop_inspector_body:
		return

	var cash: float   = d.get("cash", 0.0)
	var bread: int    = d.get("bread", 0)
	var hunger_str: String = d.get("hunger", "?")
	var starving: bool = d.get("starving", false)
	var surv: bool    = d.get("survival", false)
	var state: String = d.get("state", "?")

	var starve_tag: String = "  [color=red]☠ STARVING[/color]" if starving else ""
	var surv_tag: String   = "  [color=orange][SURVIVAL][/color]" if surv else ""

	# Wealth tier — its own dedicated line with icon + colour
	var wealth: String = d.get("wealth_tier", "")
	var wealth_col: String
	var wealth_icon: String
	match wealth:
		"Poor":
			wealth_col  = "#aaaaaa"
			wealth_icon = "▪"
		"Working":
			wealth_col  = "#e8b800"
			wealth_icon = "◆"
		"Wealthy":
			wealth_col  = "#33dd33"
			wealth_icon = "★"
		_:
			wealth_col  = "#888888"
			wealth_icon = "·"
	var wealth_line: String = "[color=%s][b]%s %s[/b][/color]%s" % [
		wealth_col, wealth_icon, wealth, surv_tag
	] if wealth != "" else ""

	# Line 1: core vitals
	var line1: String = "[b]$%.0f[/b]    Bread: [b]%d[/b]    Hunger: [b]%s[/b]%s" % [
		cash, bread, hunger_str, starve_tag
	]

	# Line 2: wealth tier (prominent)  +  survival flag
	var line2: String = wealth_line

	# Line 3: current state (dim)
	var line3: String = "[color=#aaaaaa]%s[/color]" % state

	# Line 4: role-specific extras (compact inline)
	var extras: Array[String] = []
	if d.has("seeds"):
		extras.append("Seeds:%d" % d.get("seeds"))
	if d.has("wheat"):
		extras.append("Wheat:%d" % d.get("wheat"))
	if d.has("flour"):
		extras.append("Flour:%d" % d.get("flour"))
	if d.has("fields"):
		extras.append("Fields:%d" % d.get("fields"))
	if d.has("bread_consumed") and d.get("bread_consumed", 0) > 0:
		extras.append("Consumed:%d" % d.get("bread_consumed"))
	if d.get("neg_cashflow_days", 0) > 0:
		extras.append("[color=#ff8844]NegCash:%dd[/color]" % d.get("neg_cashflow_days"))
	if d.get("failed_food_days", 0) > 0:
		extras.append("[color=#ff8844]FailFood:%dd[/color]" % d.get("failed_food_days"))
	if d.has("training_days"):
		extras.append("[color=#88ccff]Training:%dd[/color]" % d.get("training_days"))

	var lines: Array[String] = [line1]
	if wealth_line != "":
		lines.append(line2)
	lines.append(line3)
	if extras.size() > 0:
		lines.append("[color=#888888]" + "   ".join(extras) + "[/color]")

	# ── Skills display ───────────────────────────────────────────────────────
	var sk_f: float = d.get("skill_farmer", -1.0)
	if sk_f >= 0.0:
		var sk_b: float    = d.get("skill_baker",  0.0)
		var dir: int       = d.get("days_in_role", 0)
		var prod_m: float  = d.get("prod_mult",    1.0)
		var pm_col: String = "#88cc88" if prod_m >= 1.0 else "#cc8888"
		# Build a 5-block visual bar for each skill
		var f_fill: int  = roundi(sk_f * 5.0)
		var b_fill: int  = roundi(sk_b * 5.0)
		var f_bar: String = "█".repeat(f_fill) + "░".repeat(5 - f_fill)
		var b_bar: String = "█".repeat(b_fill) + "░".repeat(5 - b_fill)
		lines.append(
			"[color=#6688aa]Farmer: [%s] %.2f   Baker: [%s] %.2f   (%dd in role)[/color]" %
			[f_bar, sk_f, b_bar, sk_b, dir])
		lines.append(
			"[color=#6688aa]Productivity: [color=%s]×%.2f[/color][/color]" %
			[pm_col, prod_m])

	# ── Career utility display (full instrumentation) ───────────────────────
	var rec_role: String = d.get("recommended_role", "")
	if rec_role != "":
		var u_f: float = d.get("utility_farmer", 0.0)
		var u_b: float = d.get("utility_baker", 0.0)
		var u_c: float = d.get("utility_current", 0.0)
		var uf_col: String = "#88ccaa" if u_f >= u_c else "#888888"
		var ub_col: String = "#88ccaa" if u_b >= u_c else "#888888"
		var uc_col: String = "#aaaacc"
		lines.append(
			"[color=#6688aa]U: [color=%s]Farmer=%.1f[/color]  [color=%s]Baker=%.1f[/color]  [color=%s]Current=%.1f[/color][/color]" %
			[uf_col, u_f, ub_col, u_b, uc_col, u_c])
		var rec_col: String = "#55cc88" if rec_role != d.get("role", "") else "#888888"
		lines.append(
			"[color=#556688]Recommended: [color=%s]%s[/color][/color]" %
			[rec_col, rec_role])

	# ── Detailed career eval breakdown (from last_career_eval dict) ──────
	var lce: Dictionary = d.get("last_career_eval", {})
	if not lce.is_empty():
		var rpf: float = lce.get("role_profit_7d_avg_farmer", 0.0)
		var rpb: float = lce.get("role_profit_7d_avg_baker", 0.0)
		lines.append(
			"[color=#556688]Role 7d avg: Farmer=$%.2f  Baker=$%.2f[/color]" % [rpf, rpb])
		var ei_f: float = lce.get("income_farmer", 0.0) * lce.get("sf_farmer", 1.0)
		var ei_b: float = lce.get("income_baker", 0.0) * lce.get("sf_baker", 1.0)
		lines.append(
			"[color=#556688]Expected income: F=$%.2f  B=$%.2f  (pop avg=$%.2f)[/color]" % [
				ei_f, ei_b, lce.get("pop_cashflow_7d_avg", 0.0)])
		lines.append(
			"[color=#556688]Skill factors: F=×%.2f  B=×%.2f  Risk=%.2f[/color]" % [
				lce.get("sf_farmer", 1.0), lce.get("sf_baker", 1.0), lce.get("risk", 0.0)])
		lines.append(
			"[color=#556688]Switch cost: F=%.1f  B=%.1f[/color]" % [
				lce.get("switch_cost_farmer", 0.0), lce.get("switch_cost_baker", 0.0)])
		var du_f: float = lce.get("diag_U_farmer", 0.0)
		var du_b: float = lce.get("diag_U_baker", 0.0)
		lines.append(
			"[color=#556688]Diag U (simple): F=%.2f  B=%.2f[/color]" % [du_f, du_b])
		var scar_b: float = lce.get("scarcity_bread", 0.0)
		var scar_w: float = lce.get("scarcity_wheat", 0.0)
		var scar_col: String = "#cc5555" if scar_b > 0.0 or scar_w > 0.0 else "#556688"
		lines.append(
			"[color=%s]Scarcity: bread=%.2f wheat=%.2f[/color]" % [scar_col, scar_b, scar_w])
		var sbf: float = lce.get("scarcity_bonus_farmer", 0.0)
		var sbb: float = lce.get("scarcity_bonus_baker", 0.0)
		if sbf > 0.0 or sbb > 0.0:
			lines.append(
				"[color=#aa7744]Scarcity bonus: F=+%.2f  B=+%.2f[/color]" % [sbf, sbb])

	# ── Gate status ──────────────────────────────────────────────────────
	var eval_day_val: int = d.get("last_eval_day", -1)
	if eval_day_val >= 0:
		var g_tenure: int = d.get("gate_tenure", 0)
		var g_cooldown: int = d.get("gate_cooldown", 0)
		var g_cash: float = d.get("gate_savings_cash", 0.0)
		var g_bread: int = d.get("gate_food_bread", 0)
		var g_ftarget: int = d.get("gate_food_target", 3)
		var g_freq: int = ceili(g_ftarget * (2.0 / 3.0))
		var tenure_col: String = "#55cc88" if g_tenure >= 14 else "#cc5555"
		var cd_col: String = "#55cc88" if g_cooldown == 0 else "#cc5555"
		var sav_col: String = "#55cc88" if g_cash >= 200.0 else "#cc5555"
		var food_col: String = "#55cc88" if g_bread >= g_freq else "#cc5555"
		var fields_now: int = all_field_nodes.size()
		var lc_col: String = "#55cc88" if fields_now < MAX_FIELDS else "#cc5555"
		lines.append("[color=#556688]── Gates ──[/color]")
		lines.append(
			"[color=%s]Tenure: %d/14d[/color]  [color=%s]Cooldown: %dd[/color]  [color=%s]Savings: $%.0f/$200[/color]" %
			[tenure_col, g_tenure, cd_col, g_cooldown, sav_col, g_cash])
		lines.append(
			"[color=%s]Food: %d/%d[/color]  [color=%s]Land: %d/%d[/color]  [color=#556688]Eval day: %d[/color]" %
			[food_col, g_bread, g_freq, lc_col, fields_now, MAX_FIELDS, eval_day_val])

	# ── Last career decision ─────────────────────────────────────────────
	var lcd: String = d.get("last_career_decision", "")
	if lcd != "":
		var lcd_col: String = "#ccaa55" if "blocked" in lcd else "#55cc88"
		lines.append("[color=%s]Last decision: %s[/color]" % [lcd_col, lcd])

	# ── Cashflow diagnostics ─────────────────────────────────────────────────
	var cf_income: float = d.get("cashflow_income", -1.0)
	if cf_income >= 0.0:
		var cf_expense: float = d.get("cashflow_expense", 0.0)
		var cf_net: float     = cf_income - cf_expense
		var cf_avg: float     = d.get("cashflow_7d_avg",  0.0)
		var cf_sum: float     = d.get("cashflow_7d_sum",  0.0)
		var cf_len: int       = d.get("cashflow_7d_len",  0)
		var pop_role: String  = d.get("role", "")
		var r_avg: float      = global_role_rolling_7d_avg(pop_role)
		var r_sum: float      = global_role_rolling_7d_sum(pop_role)
		var delta: float      = cf_avg - r_avg
		# Each metric gets its OWN color — today's red doesn't bleed into 7d avg
		var net_col: String   = "#55cc88" if cf_net  >= 0.0 else "#cc5555"
		var avg_col: String   = "#55cc88" if cf_avg  >= 0.0 else "#cc5555"
		var d_col: String     = "#55cc88" if delta   >= 0.0 else "#cc5555"
		# Don't show 7d stats until there are at least 2 completed days of data
		var has_7d: bool      = cf_len >= 2
		var d_days: String    = "%d" % cf_len if has_7d else "n/a"
		var avg_str: String   = "[color=%s]$%.2f/d[/color]" % [avg_col, cf_avg] if has_7d else "n/a"
		lines.append(
			"[color=#6688bb]₢ Today: +$%.2f  -$%.2f  = [color=%s]$%.2f[/color]   7d(%s): avg %s[/color]" %
			[cf_income, cf_expense, net_col, cf_net, d_days, avg_str])
		if has_7d:
			lines.append(
				"[color=#445577]%s role 7d avg: $%.2f/d   Δ vs role: [color=%s]%+.2f[/color][/color]" %
				[pop_role, r_avg, d_col, delta])

	pop_inspector_body.text = "\n".join(lines)

	# ── Scrollable life history ────────────────────────────────────────────────
	if pop_history_label != null:
		var events: Array = []
		if selected_pop.has_method("log_event"):
			events = selected_pop.life_events
		if events.is_empty():
			pop_history_label.text = "[color=#444444](no events yet)[/color]"
		else:
			var start: int = max(0, events.size() - 200)
			var hist_lines: Array[String] = []
			for i: int in range(start, events.size()):
				hist_lines.append("[color=#888888]" + events[i] + "[/color]")
			pop_history_label.text = "\n".join(hist_lines)


func spawn_household_at(pos: Vector2) -> Node:
	"""Spawn a new household using unified Agent.tscn + set_role()."""

	if AgentScene == null:
		push_error("Cannot spawn household: AgentScene not loaded")
		return null

	# Hard population cap
	var total_pop := get_total_population()
	if total_pop >= MAX_TOTAL_POP:
		print("[POP] Spawn blocked — cap reached (%d/%d)" % [total_pop, MAX_TOTAL_POP])
		if event_bus:
			event_bus.log("[POP] Spawn blocked — cap reached (%d/%d)" % [total_pop, MAX_TOTAL_POP])
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

	# Wire HungerNeed
	var spawned_hunger: HungerNeed = h.get_node("HungerNeed") as HungerNeed
	var spawned_inv: Inventory = h.get_node("Inventory") as Inventory
	if spawned_hunger and spawned_inv:
		spawned_hunger.bind(h.name, spawned_inv, event_bus, calendar)

	# Create home
	var home := Node2D.new()
	home.name = h.name + "_Home"
	home.global_position = pos
	add_child(home)

	h.set_locations(home, market_node)

	# Register
	households.append(h)

	h.agent_died.connect(_on_household_died)

	if event_bus:
		event_bus.log("POP GROWTH: spawning %s (prosperity=%.3f)" % [h.name, prosperity_meter.prosperity_score])

	h.pop_clicked.connect(select_pop)

	return h


## Handle household starvation death - remove from all simulation lists.
## Accepts both old HouseholdAgent and new Agent (from agent_died signal).
func _on_household_died(agent_node: Node) -> void:
	var idx := households.find(agent_node)
	if idx != -1:
		households.remove_at(idx)

	if agent_node.is_in_group("households"):
		agent_node.remove_from_group("households")
	if agent_node.is_in_group("agents"):
		agent_node.remove_from_group("agents")

	# Old HouseholdAgent queue_frees itself; new Agent does not — safe to call either way
	agent_node.queue_free()


# ============================================================================
# LABOR MARKET - Occupational mobility, migration, and role conversion
# ============================================================================

## Called once per game day when the calendar emits day_changed.
func _on_calendar_day_changed(day: int) -> void:
	if sim_failed:
		return
	# Daily village-capacity status (always visible in log to aid debugging)
	print("[LAND STATUS] fields=%d/%d" % [all_field_nodes.size(), MAX_FIELDS])
	print("[POP STATUS] total=%d/%d (households=%d farmers=%d bakers=%d)" % [
		pop_mgr.count(), MAX_TOTAL_POP,
		households.size(), all_farmers.size(), all_bakers.size()])
	
	# Update labor market EMA signals
	if labor_market:
		labor_market.update_daily(day)

	# Run external trade (imports/exports) after price update, before agents act
	if trade_mgr:
		trade_mgr.on_day_changed(day)

	# Propagate day change to all agents
	for f in all_farmers:
		if f and is_instance_valid(f):
			f.on_day_changed(day)
	for b in all_bakers:
		if b and is_instance_valid(b):
			b.on_day_changed(day)
	for h in households:
		if h and is_instance_valid(h):
			h.on_day_changed(day)
	
	# Aggregate global cashflow after all pop rollovers
	_roll_global_cashflow()

	# Extinction detection — PopulationManager.count() is the ONLY authority
	if not sim_failed and pop_mgr.count() == 0 and day > (labor_market.STARTUP_GRACE_DAYS if labor_market else 5):
		_trigger_sim_failure(day, clock.tick if clock else 0)

	# Process pending role conversions (decrement countdown, spawn when ready)
	var still_pending: Array = []
	for entry in pending_conversions:
		var h = entry["household"]
		var role: String = entry["role"]
		var days_left: int = entry["days_remaining"] - 1
		if not is_instance_valid(h):
			continue  # Household already removed (e.g. starved during training)
		if days_left <= 0:
			_perform_role_conversion(h, role)
		else:
			entry["days_remaining"] = days_left
			still_pending.append(entry)
	pending_conversions = still_pending


## Handle a migrate_requested signal from LaborMarket.
## Removes the agent from tracking arrays and eliminates it from the world.
func _on_migrate_requested(agent: Node, reason: String) -> void:
	if not is_instance_valid(agent):
		return
	if event_bus:
		event_bus.log("[MIGRATION] %s leaving (reason: %s)" % [agent.name, reason])
	
	# Remove from households if it's a household agent
	var h_idx := households.find(agent)
	if h_idx != -1:
		households.remove_at(h_idx)
		agent.remove_from_group("households")
		agent.remove_from_group("agents")
	
	# Remove from farmers if it's a farmer
	var f_idx := all_farmers.find(agent)
	if f_idx != -1:
		all_farmers.remove_at(f_idx)
		# Step 1: Remove fields from registry
		for fn in all_field_nodes:
			if is_instance_valid(fn) and field_assignment_map.get(fn, null) == agent:
				field_assignment_map[fn] = null
		# Step 2: Bulk-clear farmer's field references (no per-field rebuild)
		if agent.has_method("clear_fields_for_removal"):
			agent.clear_fields_for_removal()
	
	# Remove from bakers if it's a baker
	var b_idx := all_bakers.find(agent)
	if b_idx != -1:
		all_bakers.remove_at(b_idx)
	
	# Also remove from pending_conversions if present
	pending_conversions = pending_conversions.filter(func(e): return is_instance_valid(e["household"]) and e["household"] != agent)
	
	if agent.has_method("log_event"):
		agent.log_event("Migrated: reason=%s" % reason)
	var _migrated_name: String = agent.name
	agent.queue_free()
	print("[MIGRATE CONFIRM] %s removed from simulation (reason: %s)" % [_migrated_name, reason])
	if event_bus:
		event_bus.log("[MIGRATE CONFIRM] %s removed from simulation (reason: %s)" % [_migrated_name, reason])


## Handle a role_switch_requested signal from LaborMarket.
## Queues a pending conversion that will resolve after a training delay.
func _on_role_switch_requested(household: Node, new_role: String) -> void:
	if not is_instance_valid(household):
		return
	
	# Skip if this household is already queued for conversion
	for entry in pending_conversions:
		if entry["household"] == household:
			return
	
	var training_days: int = LaborMarket.BAKER_TRAINING_DAYS if new_role == "baker" else LaborMarket.FARMER_TRAINING_DAYS
	if event_bus:
		event_bus.log("[MOBILITY] %s: training to become %s (%d days)" % [household.name, new_role, training_days])
	if household.has_method("log_event"):
		household.log_event("Training started: → %s (%d days)" % [new_role.capitalize(), training_days])

	pending_conversions.append({"household": household, "role": new_role, "days_remaining": training_days})


## Perform the actual role conversion.
## New-style Agent: in-place set_role() — identity, wallet, skills persist automatically.
## Old-style subclass: falls back to despawn + spawn + transfer.
func _perform_role_conversion(household: Node, role: String) -> void:
	if not is_instance_valid(household):
		return

	var from_role: String = household.current_role if household.get("current_role") else "?"
	var pop_id: String = household.person_name if household.get("person_name") and household.person_name != "" else household.name

	# [LAND] Gate farmer conversions on field capacity (only valid conversion block)
	if role == "farmer" and all_field_nodes.size() >= MAX_FIELDS:
		var block_line: String = "[CONVERT] pop=%s from=%s to=%s allowed=0 block=land_cap fields=%d/%d" % [
			pop_id, from_role, role, all_field_nodes.size(), MAX_FIELDS]
		print(block_line)
		if event_bus:
			event_bus.log(block_line)
		return

	var pos: Vector2 = household.global_position
	var wallet_money: float = 0.0
	var hw: Wallet = household.get_node_or_null("Wallet") as Wallet
	if hw:
		wallet_money = hw.money

	# ── NEW-STYLE in-place conversion (Agent + job components) ──────────────
	if household is Agent and (household as Agent).current_job != null:
		var ag: Agent = household as Agent
		var old_role: String = ag.current_role
		var ce = ag.get_node_or_null("CareerEvaluator")
		var u_cur: float = ce.utility_current if ce else 0.0
		var u_best: float = maxf(ce.utility_farmer, ce.utility_baker) if ce else 0.0
		var conv_delta: float = u_best - u_cur
		var conv_ratio: float = u_best / maxf(0.01, absf(u_cur))
		var convert_line: String = "[CONVERT] pop=%s from=%s to=%s allowed=1 block=none" % [pop_id, old_role, role]
		print(convert_line)
		if event_bus:
			event_bus.log(convert_line)
		ag.log_event("Switched: %s->%s reason=utility delta=%.2f ratio=%.2f cash=$%.0f" % [
			old_role, role.capitalize(), conv_delta, conv_ratio, wallet_money])
		if event_bus:
			event_bus.log("[MOBILITY] %s → in-place conversion to %s at (%.0f, %.0f) with $%.2f" % [
				ag.name, role, pos.x, pos.y, wallet_money])

		# Remove from households tracking (set_role handles Godot groups)
		var h_idx := households.find(ag)
		if h_idx != -1:
			households.remove_at(h_idx)

		# Disconnect old death signal
		if ag.agent_died.is_connected(_on_household_died):
			ag.agent_died.disconnect(_on_household_died)

		if role == "farmer":
			# Spawn field atomically first
			var field_pos := Vector2(
				clamp(pos.x + randf_range(-150.0, 150.0), 50.0, 750.0),
				clamp(pos.y + randf_range(-150.0, 150.0), 50.0, 550.0)
			)
			var pre_field := spawn_field_at(field_pos, null, true)
			if pre_field == null:
				# Re-add to households since conversion failed
				households.append(ag)
				if ag.agent_died and not ag.agent_died.is_connected(_on_household_died):
					ag.agent_died.connect(_on_household_died)
				if event_bus:
					event_bus.log("[MOBILITY] Farmer conversion aborted — field spawn returned null")
				return

			# In-place switch!
			ag.set_role("Farmer")
			ag.name = "Farmer_%d" % next_farmer_id
			next_farmer_id += 1
			_fixup_node_name(ag, "Farmer")

			# Re-bind HungerNeed for new role label
			if ag.hunger and ag.inv:
				ag.hunger.bind(ag.name, ag.inv, event_bus, calendar)

			# Wire FoodReserve
			if ag.food_reserve:
				ag.food_reserve.bind(ag.inv, ag.hunger, market, ag.wallet, event_bus, ag.name)

			# Create home
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

			# Assign field BEFORE set_route_nodes
			_assign_field_to_farmer(pre_field, ag)
			ag.set_route_nodes(home, market_node)

			all_farmers.append(ag)

			if event_bus:
				event_bus.log("[LAND] New field spawned for farmer %s at (%.0f, %.0f)" % [
					ag.name, field_pos.x, field_pos.y])

		elif role == "baker":
			ag.set_role("Baker")
			ag.name = "Baker_%d" % next_baker_id
			next_baker_id += 1
			_fixup_node_name(ag, "Baker")

			if ag.hunger and ag.inv:
				ag.hunger.bind(ag.name, ag.inv, event_bus, calendar)

			# Create bakery spot
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

		return


# ============================================================================
# PLACEMENT MODE - Click-to-place entities in the world
# ============================================================================

func _enter_placement_mode(mode: PlaceMode) -> void:
	"""Enter placement mode for the given entity type."""
	if place_mode == mode:
		# Clicking same button again cancels
		_cancel_placement()
		return
	place_mode = mode
	if placement_cursor:
		placement_cursor.visible = true
		match mode:
			PlaceMode.FIELD:
				placement_cursor.color = Color(0.4, 0.3, 0.1, 0.5)
				placement_cursor.size = Vector2(30, 30)
			PlaceMode.FARMER:
				placement_cursor.color = Color(0.2, 1, 0.2, 0.5)
				placement_cursor.size = Vector2(20, 20)
			PlaceMode.BAKER:
				placement_cursor.color = Color(0.8, 0.6, 0.2, 0.5)
				placement_cursor.size = Vector2(20, 20)
			PlaceMode.HOUSEHOLD:
				placement_cursor.color = Color(0.8, 0.2, 0.8, 0.5)
				placement_cursor.size = Vector2(20, 20)
	_update_placement_label()


func _cancel_placement() -> void:
	"""Exit placement mode."""
	place_mode = PlaceMode.NONE
	if placement_cursor:
		placement_cursor.visible = false
	_update_placement_label()


func _update_placement_cursor() -> void:
	"""Move the ghost cursor to follow the mouse."""
	if place_mode == PlaceMode.NONE or placement_cursor == null:
		return
	var mouse_pos = get_viewport().get_mouse_position()
	placement_cursor.position = mouse_pos - placement_cursor.size / 2.0


func _update_placement_label() -> void:
	if place_mode_label == null:
		return
	match place_mode:
		PlaceMode.NONE:
			place_mode_label.text = ""
		PlaceMode.FIELD:
			place_mode_label.text = "PLACING FIELD - Click world to place. Right-click or Esc to cancel."
		PlaceMode.FARMER:
			place_mode_label.text = "PLACING FARMER - Click world to place. Right-click or Esc to cancel."
		PlaceMode.BAKER:
			place_mode_label.text = "PLACING BAKER - Click world to place. Right-click or Esc to cancel."
		PlaceMode.HOUSEHOLD:
			place_mode_label.text = "PLACING HOUSEHOLD - Click world to place. Right-click or Esc to cancel."


func _place_entity_at(pos: Vector2) -> void:
	"""Place the selected entity type at the given world position."""
	match place_mode:
		PlaceMode.FIELD:
			spawn_field_at(pos)
		PlaceMode.FARMER:
			spawn_farmer_at(pos)
		PlaceMode.BAKER:
			spawn_baker_at(pos)
		PlaceMode.HOUSEHOLD:
			spawn_household_at(pos)
	# Stay in placement mode so user can place multiple of the same type
	# (click the button again or press Esc to stop)


# ============================================================================
# SPAWN SYSTEM - Entity creation with full wiring
# ============================================================================

func spawn_field_at(pos: Vector2, assign_to: Node = null, skip_auto_assign: bool = false) -> Node2D:
	"""Spawn a new field at the given position.
	If assign_to is provided the field is assigned directly (no popup).
	skip_auto_assign=true leaves the field unassigned (used for atomic farmer conversion).
	Otherwise falls back to auto-assign (single farmer) or popup (multiple farmers)."""
	# Hard land cap — never exceed MAX_FIELDS
	if all_field_nodes.size() >= MAX_FIELDS:
		print("[LAND] Spawn blocked — cap reached (%d/%d)" % [all_field_nodes.size(), MAX_FIELDS])
		if event_bus:
			event_bus.log("[LAND] Spawn blocked — cap reached (%d/%d)" % [all_field_nodes.size(), MAX_FIELDS])
		return null
	# Create field node with FieldPlot script
	var field_node = Node2D.new()
	field_node.name = "Field%d" % next_field_id
	next_field_id += 1
	field_node.set_script(load("res://scripts/field_plot.gd"))
	field_node.global_position = pos
	
	# Add visual marker (matches existing field style)
	var marker = ColorRect.new()
	marker.name = "FieldMarker"
	marker.offset_left = -15.0
	marker.offset_top = -15.0
	marker.offset_right = 15.0
	marker.offset_bottom = 15.0
	marker.color = Color(0.4, 0.3, 0.1, 1)
	field_node.add_child(marker)
	
	# Add a label underneath showing the field name
	var name_label = Label.new()
	name_label.name = "FieldLabel"
	name_label.text = field_node.name
	name_label.position = Vector2(-20, 18)
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.add_theme_color_override("font_color", Color(0.8, 0.7, 0.4))
	field_node.add_child(name_label)
	
	add_child(field_node)
	
	# Register with field manager
	field_mgr.register_field(field_node, field_node)
	
	if event_bus:
		event_bus.log("PLACED: %s at (%d, %d)" % [field_node.name, int(pos.x), int(pos.y)])
	
	# Resolve assignment unless caller requests deferred assignment (atomic conversion path).
	# 1) skip_auto_assign=true  → leave unassigned; caller assigns externally.
	# 2) Explicit assign_to     → assign directly, no popup.
	# 3) Single farmer in world → auto-assign silently.
	# 4) Multiple farmers       → show user popup to choose.
	if not skip_auto_assign:
		if assign_to != null and is_instance_valid(assign_to):
			_assign_field_to_farmer(field_node, assign_to)
		elif all_farmers.size() == 1 and is_instance_valid(all_farmers[0]):
			_assign_field_to_farmer(field_node, all_farmers[0])
		else:
			_show_field_assignment_popup(field_node, pos)
	
	return field_node


func spawn_farmer_at(pos: Vector2, initial_field_node: Node2D = null) -> Node:
	"""Spawn a new farmer using Agent.tscn + set_role("Farmer").
	initial_field_node, when provided, is assigned BEFORE set_route_nodes so that
	_rebuild_route never sees an empty fields array during construction."""
	if AgentScene == null:
		if event_bus:
			event_bus.log("[ERROR] Cannot spawn farmer: AgentScene not loaded")
		return null

	# Hard population cap
	var total_pop := get_total_population()
	if total_pop >= MAX_TOTAL_POP:
		print("[POP] Spawn blocked — cap reached (%d/%d)" % [total_pop, MAX_TOTAL_POP])
		if event_bus:
			event_bus.log("[POP] Spawn blocked — cap reached (%d/%d)" % [total_pop, MAX_TOTAL_POP])
		return null

	var f: Agent = AgentScene.instantiate() as Agent
	if f == null:
		push_error("AgentScene instantiate() returned null")
		return null
	f.name = "Farmer_%d" % next_farmer_id
	next_farmer_id += 1
	f.global_position = pos
	add_child(f)

	_fixup_node_name(f, "Farmer")

	await get_tree().process_frame

	_assign_new_identity(f)

	f.market = market
	f.event_bus = event_bus
	f.econ_stats = econ_stats
	f.set_role("Farmer")

	# Wire HungerNeed
	var f_hunger: HungerNeed = f.get_node("HungerNeed") as HungerNeed
	var f_inv: Inventory = f.get_node("Inventory") as Inventory
	if f_hunger and f_inv:
		f_hunger.bind(f.name, f_inv, event_bus, calendar)

	# Wire FoodReserve
	var f_reserve: FoodReserve = f.get_node("FoodReserve") as FoodReserve
	if f_reserve:
		f_reserve.bind(f_inv, f_hunger, market, f.get_node("Wallet") as Wallet, event_bus, f.name)

	# Create home
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

	# Assign initial field BEFORE set_route_nodes
	if initial_field_node != null and is_instance_valid(initial_field_node):
		_assign_field_to_farmer(initial_field_node, f)

	f.set_route_nodes(home, market_node)

	# Register
	all_farmers.append(f)

	# Absorb orphaned fields
	var absorbed: int = 0
	for fn in all_field_nodes:
		if is_instance_valid(fn) and field_assignment_map.get(fn, null) == null:
			_assign_field_to_farmer(fn, f)
			absorbed += 1

	if event_bus:
		var msg: String = "PLACED: %s at (%d, %d)" % [f.name, int(pos.x), int(pos.y)]
		if absorbed > 0:
			msg += " → absorbed %d unassigned field(s)" % absorbed
		event_bus.log(msg)

	f.pop_clicked.connect(select_pop)

	return f


func spawn_baker_at(pos: Vector2) -> Node:
	"""Spawn a new baker using Agent.tscn + set_role("Baker")."""
	if AgentScene == null:
		if event_bus:
			event_bus.log("[ERROR] Cannot spawn baker: AgentScene not loaded")
		return null

	# Hard population cap
	var total_pop := get_total_population()
	if total_pop >= MAX_TOTAL_POP:
		print("[POP] Spawn blocked — cap reached (%d/%d)" % [total_pop, MAX_TOTAL_POP])
		if event_bus:
			event_bus.log("[POP] Spawn blocked — cap reached (%d/%d)" % [total_pop, MAX_TOTAL_POP])
		return null

	var b: Agent = AgentScene.instantiate() as Agent
	if b == null:
		push_error("AgentScene instantiate() returned null")
		return null
	b.name = "Baker_%d" % next_baker_id
	next_baker_id += 1
	b.global_position = pos
	add_child(b)

	_fixup_node_name(b, "Baker")

	await get_tree().process_frame

	_assign_new_identity(b)

	b.market = market
	b.event_bus = event_bus
	b.econ_stats = econ_stats
	b.set_role("Baker")

	# Wire HungerNeed
	var b_hunger: HungerNeed = b.get_node("HungerNeed") as HungerNeed
	var b_inv: Inventory = b.get_node("Inventory") as Inventory
	if b_hunger and b_inv:
		b_hunger.bind(b.name, b_inv, event_bus, calendar)

	# Create bakery spot
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

	# Register
	all_bakers.append(b)

	if event_bus:
		event_bus.log("PLACED: %s at (%d, %d)" % [b.name, int(pos.x), int(pos.y)])

	b.pop_clicked.connect(select_pop)

	return b


# ============================================================================
# FIELD ASSIGNMENT POPUP
# ============================================================================

func _assign_field_to_farmer(field_node: Node2D, new_farmer) -> void:
	field_mgr.assign_field(field_node, new_farmer)


func _show_field_assignment_popup(field_node: Node2D, world_pos: Vector2) -> void:
	"""Show a popup near the placed field asking which farmer to assign it to."""
	if all_farmers.size() == 0:
		return  # No farmers yet, nothing to assign
	
	# Convert world position to canvas/UI position
	var vp_size = get_viewport().get_visible_rect().size
	var screen_pos = world_pos + Vector2(20, -60)  # Offset so popup is above/right of field
	screen_pos = screen_pos.clamp(Vector2(4, 4), vp_size - Vector2(180, 20))
	
	# Build popup on the CanvasLayer (always on top)
	var ui_layer = get_node_or_null("UI")
	if ui_layer == null:
		return
	
	var popup = PanelContainer.new()
	popup.name = "FieldAssignPopup"
	popup.position = screen_pos
	
	var bg = StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.1, 0.13, 0.97)
	bg.border_color = Color(0.5, 0.7, 0.4, 1.0)
	bg.set_border_width_all(2)
	bg.set_corner_radius_all(6)
	bg.set_content_margin_all(10)
	popup.add_theme_stylebox_override("panel", bg)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	popup.add_child(vbox)
	
	var title = Label.new()
	title.text = "Assign %s to:" % field_node.name
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.9, 0.85, 0.6))
	vbox.add_child(title)
	
	var sep = HSeparator.new()
	vbox.add_child(sep)
	
	# One button per farmer
	var farmer_colors = [Color(0.3, 0.7, 1.0), Color(1.0, 0.6, 0.2), Color(0.4, 1.0, 0.5), Color(1.0, 0.4, 0.7)]
	for i in range(all_farmers.size()):
		var f = all_farmers[i]
		if not is_instance_valid(f):
			continue
		var btn = Button.new()
		btn.text = f.name
		btn.custom_minimum_size = Vector2(140, 28)
		var fc = farmer_colors[i % farmer_colors.size()]
		var btn_style = StyleBoxFlat.new()
		btn_style.bg_color = fc.lerp(Color.BLACK, 0.55)
		btn_style.border_color = fc
		btn_style.set_border_width_all(1)
		btn_style.set_corner_radius_all(3)
		btn_style.set_content_margin_all(4)
		btn.add_theme_stylebox_override("normal", btn_style)
		var hover_style = btn_style.duplicate()
		hover_style.bg_color = fc.lerp(Color.BLACK, 0.35)
		btn.add_theme_stylebox_override("hover", hover_style)
		var fn_ref = field_node
		var farmer_ref = f
		btn.pressed.connect(func():
			_assign_field_to_farmer(fn_ref, farmer_ref)
			popup.queue_free()
		)
		vbox.add_child(btn)
	
	# Skip button
	var skip_btn = Button.new()
	skip_btn.text = "Skip (no farmer)"
	skip_btn.custom_minimum_size = Vector2(140, 24)
	skip_btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	skip_btn.pressed.connect(func(): popup.queue_free())
	vbox.add_child(skip_btn)
	
	ui_layer.add_child(popup)


# ============================================================================
# SPAWN HELPERS - Positioning
# ============================================================================

func _get_next_farmer_position() -> Vector2:
	"""Position new farmers near the house area."""
	var base_x = 80.0
	var base_y = 480.0
	var offset = (all_farmers.size()) * 40
	var col = offset % 200
	@warning_ignore("integer_division")
	var row = (offset / 200) * 60
	return Vector2(base_x + col, base_y + row)


func _get_next_baker_position() -> Vector2:
	"""Position new bakers near the bakery area."""
	var base_x = 350.0
	var base_y = 410.0
	var offset = (all_bakers.size()) * 40
	var col = offset % 200
	@warning_ignore("integer_division")
	var row = (offset / 200) * 60
	return Vector2(base_x + col, base_y + row)
