extends Node

var farmer: Farmer = null
var baker: Baker = null
var market: Market = null
var household_agent: HouseholdAgent = null
var clock: SimulationClock = null
var bus: EventBus = null
var audit: EconomyAudit = null
var calendar: Calendar = null
var prosperity_meter: ProsperityMeter = null

# Field plots
var field1_plot: FieldPlot = null
var field2_plot: FieldPlot = null

# PART 1: Central Registries (authoritative state)
var farmers: Array = []
var bakers: Array = []
var fields: Array = []
var farmer_counter: int = 1  # Track next ID for naming
var baker_counter: int = 1
var field_counter: int = 1

# PART 5: AdminMenu reference
var admin_menu = null
var admin_menu_button: Button = null  # On-screen fallback button
var placement_controller: PlacementController = null

# PART 1: PackedScene references for spawning
@export var FarmerScene: PackedScene
@export var BakerScene: PackedScene
@export var FieldScene: PackedScene
@export var AdminMenuScene: PackedScene

# Household management
@export var HouseholdScene: PackedScene
var households: Array = []
var market_node: Node2D = null
var event_bus: EventBus = null
var economy_config: Dictionary = {}
var last_spawn_day: int = -999  # Track last spawn day to enforce 1 spawn/day cap

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

var log_lines: Array[String] = []
var log_buffer: Array[String] = []  # Full log for export (not trimmed)
var user_at_bottom: bool = true  # Track if user is at bottom for sticky auto-scroll
const MAX_LOG_LINES: int = 200
const SCROLL_THRESHOLD: int = 50  # Pixels from bottom to consider "at bottom"


func _ready() -> void:
	# Load economy config
	_load_economy_config()
	
	# Resolve HouseholdScene (eliminate Inspector dependency)
	_resolve_household_scene()
	
	# Create simulation systems
	clock = SimulationClock.new()
	clock.name = "SimulationClock"
	add_child(clock)
	clock.ticked.connect(_on_tick)
	clock.speed_changed.connect(_on_speed_changed)
	
	bus = EventBus.new()
	bus.name = "EventBus"
	add_child(bus)
	bus.event_logged.connect(_on_event_logged)
	
	audit = EconomyAudit.new()
	audit.name = "EconomyAudit"
	add_child(audit)
	
	calendar = Calendar.new()
	calendar.name = "Calendar"
	add_child(calendar)
	
	prosperity_meter = ProsperityMeter.new()
	prosperity_meter.name = "ProsperityMeter"
	add_child(prosperity_meter)
	
	# Store EventBus reference for spawn function
	event_bus = bus
	
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
	
	# Get field plot scripts
	field1_plot = field1_node as FieldPlot
	field2_plot = field2_node as FieldPlot
	
	# Create market instance
	market = Market.new()
	market.name = "Market"
	add_child(market)
	
	# Wire calendar day_changed to market for daily price adjustments
	calendar.day_changed.connect(market.on_day_changed)
	
	# Wire event bus to all agents
	market.event_bus = bus
	farmer.event_bus = bus
	baker.event_bus = bus
	household_agent.event_bus = bus
	
	# Wire HungerNeed components
	var farmer_inv = farmer.get_node("Inventory") as Inventory
	var farmer_hunger = farmer.get_node("HungerNeed") as HungerNeed
	farmer_hunger.bind("Farmer", farmer_inv, bus, calendar)
	
	var baker_inv = baker.get_node("Inventory") as Inventory
	var baker_hunger = baker.get_node("HungerNeed") as HungerNeed
	baker_hunger.bind("Baker", baker_inv, bus, calendar)
	
	var household_inv = household_agent.get_node("Inventory") as Inventory
	var household_hunger = household_agent.get_node("HungerNeed") as HungerNeed
	household_hunger.bind("Household", household_inv, bus, calendar)
	
	# Connect farmer to market and fields
	farmer.market = market
	farmer.set_route_nodes(house, field1_node, field2_node, market_node)
	farmer.set_fields(field1_plot, field2_plot)
	
	# Bind farmer food reserve after market is set
	var farmer_food_reserve = farmer.get_node("FoodReserve") as FoodReserve
	if farmer_food_reserve:
		farmer_food_reserve.bind(farmer.get_node("Inventory"), farmer.get_node("HungerNeed"), market, farmer.get_node("Wallet"), bus, "Farmer")
	
	# Connect baker to market
	baker.market = market
	
	# Set up baker movement targets
	if baker and bakery and market_node:
		baker.set_locations(bakery, market_node)
	
	# Connect household agent to market
	household_agent.market = market
	if household_agent and household_home and market_node:
		household_agent.set_locations(household_home, market_node)
	
	# Add baseline household to households array for prosperity tracking
	households.append(household_agent)
	
	# Connect death signal for baseline household
	household_agent.household_died.connect(_on_household_died)
	
	# Bind prosperity meter references
	prosperity_meter.bind_references(bus, market, households)
	
	# PART 1: Initialize central registries from existing agents
	_initialize_registries()
	
	# PART 5: Initialize PlacementController
	_initialize_placement_controller()
	
	# PART 5: Initialize AdminMenu
	_initialize_admin_menu()
	
	# Ensure we receive input events
	set_process_input(true)
	set_process_unhandled_input(true)
	
	# Add on-screen Admin button
	_create_admin_button()
	
	# Get UI label references
	get_ui_labels()
	
	# Initial UI update
	update_ui()
	
	# Log startup
	bus.log("Tick 0: START")


func _process(_delta: float) -> void:
	update_ui()


func _on_tick(tick: int) -> void:
	# Update calendar
	calendar.set_tick(tick)
	
	# Tick field plots
	if field1_plot:
		field1_plot.tick()
	if field2_plot:
		field2_plot.tick()
	
	# Update tick for all agents (including spawned households)
	if market:
		market.set_tick(tick)
	if farmer:
		farmer.set_tick(tick)
	if baker:
		baker.set_tick(tick)
	
	# Tick all households
	for h in households:
		if h and is_instance_valid(h):
			h.set_tick(tick)
	
	# Update prosperity meter
	if prosperity_meter:
		prosperity_meter.update_prosperity(calendar.day_index)
		
		# Check if we should spawn a new household
		if prosperity_meter.should_spawn_household(calendar.day_index):
			# POPULATION GROWTH FRICTION: Only spawn if we haven't already spawned today
			if calendar.day_index != last_spawn_day:
				var spawn_pos = Vector2(randf_range(100, 700), randf_range(100, 500))
				spawn_household_at(spawn_pos)
				last_spawn_day = calendar.day_index
				prosperity_meter.record_spawn(calendar.day_index)
			else:
				# Log once when blocked (only if we haven't logged yet this day)
				if event_bus:
					event_bus.log("POP GROWTH: blocked (already spawned today)")
	
	# Run audit checks
	audit.audit(farmer, baker, market, bus, tick)


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


func _resolve_household_scene() -> void:
	"""Auto-resolve HouseholdScene to eliminate Inspector dependency."""
	if HouseholdScene != null:
		return
	
	var candidate_paths := [
		"res://scenes/Household.tscn",
		"res://scenes/agents/HouseholdAgent.tscn",
		"res://scenes/HouseholdAgent.tscn",
		"res://scenes/household_agent.tscn"
	]
	
	for p in candidate_paths:
		if ResourceLoader.exists(p):
			HouseholdScene = load(p)
			if event_bus:
				event_bus.log("HouseholdScene auto-loaded from " + p)
			else:
				print("Main: HouseholdScene auto-loaded from ", p)
			return
	
	push_error("FATAL: HouseholdScene could not be resolved. Population growth disabled.")


func _input(event: InputEvent) -> void:
	# Direct key detection for AdminMenu toggle (F1 primary, F2 fallback)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1 or event.keycode == KEY_F2:
			_toggle_admin_menu()
			get_viewport().set_input_as_handled()
			return
	
	if clock == null:
		return
	if event.is_action_pressed("speed_up"):
		clock.increase_speed()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("speed_down"):
		clock.decrease_speed()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	"""Fallback input handler in case _input doesn't catch the key."""
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1 or event.keycode == KEY_F2:
			_toggle_admin_menu()
			get_viewport().set_input_as_handled()


func _toggle_admin_menu() -> void:
	"""Toggle AdminMenu visibility with proper null checks and logging."""
	if admin_menu == null:
		if event_bus:
			event_bus.log("UI ERROR: AdminMenu is null, cannot toggle")
		else:
			push_error("UI ERROR: AdminMenu is null")
		return
	
	if admin_menu.visible:
		admin_menu.hide()
		if event_bus:
			event_bus.log("UI: AdminMenu closed")
	else:
		admin_menu.show()
		if admin_menu.has_method("refresh"):
			admin_menu.refresh()
		if event_bus:
			event_bus.log("UI: AdminMenu opened")


func _on_speed_changed(new_speed: float) -> void:
	if sim_speed_label:
		sim_speed_label.text = "Speed: %.1fx" % new_speed


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


func get_ui_labels() -> void:
	var farmer_card = get_node("UI/HUDRoot/Layout/Sidebar/SidebarVBox/CardsScroll/Cards/FarmerCard/FarmerVBox")
	var baker_card = get_node("UI/HUDRoot/Layout/Sidebar/SidebarVBox/CardsScroll/Cards/BakerCard/BakerVBox")
	var household_card = get_node("UI/HUDRoot/Layout/Sidebar/SidebarVBox/CardsScroll/Cards/HouseholdCard/HouseholdVBox")
	var market_card = get_node("UI/HUDRoot/Layout/Sidebar/SidebarVBox/CardsScroll/Cards/MarketCard/MarketVBox")
	var log_vbox = get_node("UI/HUDRoot/Layout/Sidebar/SidebarVBox/LogPanel/LogVBox")
	
	farmer_status_label = farmer_card.get_node("FarmerStatus")
	farmer_money_label = farmer_card.get_node("FarmerMoney")
	farmer_seeds_label = farmer_card.get_node("FarmerSeeds")
	farmer_wheat_label = farmer_card.get_node("FarmerWheat")
	farmer_bread_label = farmer_card.get_node("FarmerBread")
	farmer_days_until_starve_label = farmer_card.get_node("FarmerDaysUntilStarve")
	farmer_starving_label = farmer_card.get_node("FarmerStarving")
	farmer_inventory_label = farmer_card.get_node("FarmerInventory")
	
	baker_status_label = baker_card.get_node("BakerStatus")
	baker_money_label = baker_card.get_node("BakerMoney")
	baker_wheat_label = baker_card.get_node("BakerWheat")
	baker_flour_label = baker_card.get_node("BakerFlour")
	baker_bread_label = baker_card.get_node("BakerBread")
	baker_food_bread_label = baker_card.get_node("BakerFoodBread")
	baker_days_until_starve_label = baker_card.get_node("BakerDaysUntilStarve")
	baker_starving_label = baker_card.get_node("BakerStarving")
	baker_inventory_label = baker_card.get_node("BakerInventory")
	
	household_status_label = household_card.get_node("HouseholdStatus")
	household_money_label = household_card.get_node("HouseholdMoney")
	household_bread_label = household_card.get_node("HouseholdBread")
	household_bread_consumed_label = household_card.get_node("HouseholdBreadConsumed")
	household_hunger_label = household_card.get_node("HouseholdHunger")
	household_starving_label = household_card.get_node("HouseholdStarving")
	household_inventory_label = household_card.get_node("HouseholdInventory")
	
	market_money_label = market_card.get_node("MarketMoney")
	market_seeds_label = market_card.get_node("MarketSeeds")
	market_wheat_label = market_card.get_node("MarketWheat")
	market_wheat_cap_label = market_card.get_node("MarketWheatCap")
	market_bread_label = market_card.get_node("MarketBread")
	market_bread_cap_label = market_card.get_node("MarketBreadCap")
	wheat_price_label = market_card.get_node("WheatPrice")
	bread_price_label = market_card.get_node("BreadPrice")
	
	event_log = log_vbox.get_node("EventLog")
	export_log_button = log_vbox.get_node("ExportLogButton")
	export_log_button.pressed.connect(export_log)
	
	# Add Jump to Bottom button if it exists in scene
	if log_vbox.has_node("JumpToBottomButton"):
		jump_to_bottom_button = log_vbox.get_node("JumpToBottomButton")
		jump_to_bottom_button.pressed.connect(_on_jump_to_bottom)
	
	# Add simulation speed label if it exists in scene
	if has_node("UI/HUDRoot/Layout/TopBar"):
		var top_bar = get_node("UI/HUDRoot/Layout/TopBar")
		if top_bar and top_bar.has_node("SimSpeedLabel"):
			sim_speed_label = top_bar.get_node("SimSpeedLabel")
			sim_speed_label.text = "Speed: 1.0x"
	
	# Get prosperity panel labels if they exist
	if has_node("UI/HUDRoot/Layout/Sidebar/SidebarVBox/CardsScroll/Cards/ProsperityCard"):
		var prosperity_card = get_node("UI/HUDRoot/Layout/Sidebar/SidebarVBox/CardsScroll/Cards/ProsperityCard/ProsperityVBox")
		if prosperity_card:
			prosperity_score_label = prosperity_card.get_node_or_null("ProsperityScore")
			wealth_score_label = prosperity_card.get_node_or_null("WealthScore")
			food_score_label = prosperity_card.get_node_or_null("FoodScore")
			starvation_score_label = prosperity_card.get_node_or_null("StarvationScore")
			trade_score_label = prosperity_card.get_node_or_null("TradeScore")
			population_info_label = prosperity_card.get_node_or_null("PopulationInfo")
	
	# Connect scroll detection for sticky auto-scroll
	if event_log:
		# RichTextLabel uses a ScrollBar child for scrolling
		var vscroll = event_log.get_v_scroll_bar()
		if vscroll:
			vscroll.value_changed.connect(_on_log_scroll)


func update_ui() -> void:
	if farmer and farmer_status_label:
		farmer_status_label.text = "Status: " + farmer.get_status_text()
	if farmer and farmer_money_label:
		farmer_money_label.text = "Farmer Money: $%.2f" % farmer.get_node("Wallet").money
	if farmer and farmer_seeds_label:
		farmer_seeds_label.text = "Farmer Seeds: %d" % farmer.get_node("Inventory").get_qty("seeds")
	if farmer and farmer_wheat_label:
		farmer_wheat_label.text = "Farmer Wheat: %d" % farmer.get_node("Inventory").get_qty("wheat")
	if farmer and farmer_bread_label:
		farmer_bread_label.text = "Farmer Bread: %d" % farmer.get_node("Inventory").get_qty("bread")
	if farmer and farmer_days_until_starve_label:
		var farmer_hunger = farmer.get_node("HungerNeed")
		farmer_days_until_starve_label.text = "Farmer Hunger Days: %d/%d" % [farmer_hunger.hunger_days, farmer_hunger.hunger_max_days]
	if farmer and farmer_starving_label:
		var farmer_hunger = farmer.get_node("HungerNeed")
		farmer_starving_label.text = "Farmer Starving: %s" % ("Yes" if farmer_hunger.is_starving else "No")
	if farmer and farmer_inventory_label:
		var farmer_cap = farmer.get_node("InventoryCapacity")
		var farmer_inv_text = "Inventory: %d / %d" % [farmer_cap.current_total(), farmer_cap.max_items]
		if farmer_cap.is_full():
			farmer_inv_text += " (FULL)"
		farmer_inventory_label.text = farmer_inv_text
	
	if market and market_money_label:
		market_money_label.text = "Market Money: $%.2f" % market.money
	if market and market_seeds_label:
		market_seeds_label.text = "Market Seeds: %d" % market.seeds
	if market and market_wheat_label:
		market_wheat_label.text = "Market Wheat: %d" % market.wheat
	if market and market_wheat_cap_label:
		market_wheat_cap_label.text = "Market Wheat: %d/%d" % [market.wheat, market.wheat_capacity]
	if market and market_bread_label:
		market_bread_label.text = "Market Bread: %d" % market.bread
	if market and market_bread_cap_label:
		market_bread_cap_label.text = "Market Bread: %d/%d" % [market.bread, market.bread_capacity]
	if market and wheat_price_label:
		wheat_price_label.text = "Wheat Price: $%.2f ($%.2f–$%.2f)" % [market.wheat_price, market.WHEAT_PRICE_FLOOR, market.WHEAT_PRICE_CEILING]
	if market and bread_price_label:
		bread_price_label.text = "Bread Price: $%.2f ($%.2f–$%.2f)" % [market.bread_price, market.BREAD_PRICE_FLOOR, market.BREAD_PRICE_CEILING]
	
	if baker and baker_status_label:
		baker_status_label.text = "Status: " + baker.get_status_text()
	if baker and baker_money_label:
		baker_money_label.text = "Baker Money: $%.2f" % baker.get_node("Wallet").money
	if baker and baker_wheat_label:
		baker_wheat_label.text = "Baker Wheat: %d" % baker.get_node("Inventory").get_qty("wheat")
	if baker and baker_flour_label:
		baker_flour_label.text = "Baker Flour: %d" % baker.get_node("Inventory").get_qty("flour")
	if baker and baker_bread_label:
		baker_bread_label.text = "Baker Bread: %d" % baker.get_node("Inventory").get_qty("bread")
	if baker and baker_food_bread_label:
		baker_food_bread_label.text = "Baker Food Bread: %d" % baker.get_node("Inventory").get_qty("bread")
	if baker and baker_days_until_starve_label:
		var baker_hunger = baker.get_node("HungerNeed")
		baker_days_until_starve_label.text = "Baker Hunger Days: %d/%d" % [baker_hunger.hunger_days, baker_hunger.hunger_max_days]
	if baker and baker_starving_label:
		var baker_hunger = baker.get_node("HungerNeed")
		baker_starving_label.text = "Baker Starving: %s" % ("Yes" if baker_hunger.is_starving else "No")
	if baker and baker_inventory_label:
		var baker_cap = baker.get_node("InventoryCapacity")
		var baker_inv_text = "Inventory: %d / %d" % [baker_cap.current_total(), baker_cap.max_items]
		if baker_cap.is_full():
			baker_inv_text += " (FULL)"
		baker_inventory_label.text = baker_inv_text
	
	if household_agent and household_status_label:
		household_status_label.text = "Status: " + household_agent.get_status_text()
	if household_agent and household_money_label:
		household_money_label.text = "Household Money: $%.2f" % household_agent.get_node("Wallet").money
	if household_agent and household_bread_label:
		household_bread_label.text = "Household Bread: %d" % household_agent.get_node("Inventory").get_qty("bread")
	if household_agent and household_bread_consumed_label:
		household_bread_consumed_label.text = "Household Bread Consumed: %d" % household_agent.bread_consumed
	if household_agent and household_hunger_label:
		var household_hunger = household_agent.get_node("HungerNeed")
		household_hunger_label.text = "Household Hunger: %d/%d" % [household_hunger.hunger_days, household_hunger.hunger_max_days]
	if household_agent and household_starving_label:
		var household_hunger = household_agent.get_node("HungerNeed")
		household_starving_label.text = "Household Starving: %s" % ("Yes" if household_hunger.is_starving else "No")
	if household_agent and household_inventory_label:
		var household_cap = household_agent.get_node("InventoryCapacity")
		var household_inv_text = "Inventory: %d / %d" % [household_cap.current_total(), household_cap.max_items]
		if household_cap.is_full():
			household_inv_text += " (FULL)"
		household_inventory_label.text = household_inv_text
	
	# Update prosperity UI
	if prosperity_meter:
		if prosperity_score_label:
			prosperity_score_label.text = "Prosperity: %.2f" % prosperity_meter.prosperity_score
		if wealth_score_label:
			var wealth = prosperity_meter.prosperity_inputs.get("wealth_health", 0.0)
			wealth_score_label.text = "Wealth: %.2f" % wealth
		if food_score_label:
			var food = prosperity_meter.prosperity_inputs.get("food_security", 0.0)
			food_score_label.text = "Food: %.2f" % food
		if starvation_score_label:
			var starvation = prosperity_meter.prosperity_inputs.get("starvation_pressure", 0.0)
			starvation_score_label.text = "Starvation: %.2f" % starvation
		if trade_score_label:
			var trade = prosperity_meter.prosperity_inputs.get("trade_activity", 0.0)
			trade_score_label.text = "Trade: %.2f" % trade
		if population_info_label:
			population_info_label.text = "Population: %d" % households.size()


func spawn_household_at(pos: Vector2) -> Node:
	"""Spawn a new household from the HouseholdScene PackedScene."""
	
	# Fail cleanly if HouseholdScene is not resolved
	if HouseholdScene == null:
		push_error("Cannot spawn household: HouseholdScene is null.")
		return null
	
	# Instantiate household from scene file
	var h := HouseholdScene.instantiate()
	if h == null:
		push_error("HouseholdScene.instantiate() returned null")
		return null
	
	# Setup household
	h.name = "Household_%d" % (households.size() + 1)
	h.global_position = pos
	add_child(h)
	
	# Allow _ready() to run so child nodes/components exist
	await get_tree().process_frame
	
	# Wire required references (identical to baseline household)
	h.market = market
	h.event_bus = event_bus
	
	# Wire HungerNeed component for spawned household
	var spawned_hunger = h.get_node("HungerNeed") as HungerNeed
	var spawned_inv = h.get_node("Inventory") as Inventory
	if spawned_hunger and spawned_inv:
		spawned_hunger.bind(h.name, spawned_inv, event_bus, calendar)
	
	# Create a home node for this household at their spawn position
	var home = Node2D.new()
	home.name = h.name + "_Home"
	home.global_position = pos
	add_child(home)
	
	h.set_locations(home, market_node)
	
	# Register in ALL simulation loops (identical to baseline)
	households.append(h)
	h.add_to_group("households")
	h.add_to_group("agents")
	
	# Connect death signal
	h.household_died.connect(_on_household_died)
	
	if event_bus:
		event_bus.log("POP GROWTH: spawning %s (prosperity=%.3f)" % [h.name, prosperity_meter.prosperity_score])
	
	return h


## Handle household starvation death - remove from all simulation lists.
func _on_household_died(household: HouseholdAgent) -> void:
	# Remove from households list
	var idx := households.find(household)
	if idx != -1:
		households.remove_at(idx)
	
	# Remove from agent groups
	household.remove_from_group("households")
	household.remove_from_group("agents")
	
	# household will queue_free() itself, no need to call it here


# ====================================================================
# PART 1: CENTRAL REGISTRIES AND INITIALIZATION
# ====================================================================

func _initialize_registries() -> void:
	"""Populate registries from existing scene nodes and groups."""
	# Add existing farmer
	if farmer:
		farmers.append(farmer)
		farmer.add_to_group("farmers")
		farmer.name = "Farmer_1"
		farmer_counter = 2
	
	# Add existing baker
	if baker:
		bakers.append(baker)
		baker.add_to_group("bakers")
		baker.name = "Baker_1"
		baker_counter = 2
	
	# Add existing fields
	if field1_plot:
		fields.append(field1_plot)
		field1_plot.add_to_group("fields")
		if field1_plot.name != "Field_1":
			field1_plot.name = "Field_1"
	if field2_plot:
		fields.append(field2_plot)
		field2_plot.add_to_group("fields")
		if field2_plot.name != "Field_2":
			field2_plot.name = "Field_2"
	
	field_counter = 3
	
	if event_bus:
		event_bus.log("REGISTRY: Initialized with %d farmers, %d bakers, %d fields" % [farmers.size(), bakers.size(), fields.size()])


func _initialize_placement_controller() -> void:
	"""PART 6: Initialize PlacementController for click-to-place spawning."""
	placement_controller = PlacementController.new()
	placement_controller.name = "PlacementController"
	add_child(placement_controller)
	placement_controller.set_controller(self)
	
	if event_bus:
		event_bus.log("UI: PlacementController initialized")


func _initialize_admin_menu() -> void:
	"""PART 5: Initialize AdminMenu UI with robust error handling."""
	if AdminMenuScene:
		admin_menu = AdminMenuScene.instantiate()
		if admin_menu:
			add_child(admin_menu)
			admin_menu.visible = false
			admin_menu.set_controller(self)
			if placement_controller:
				admin_menu.set_placement_controller(placement_controller)
				placement_controller.set_admin_menu(admin_menu)
			if event_bus:
				event_bus.log("UI: AdminMenu instantiated (press F1 or F2 to open)")
		else:
			if event_bus:
				event_bus.log("UI ERROR: AdminMenuScene failed to instantiate")
			else:
				push_error("UI ERROR: AdminMenuScene failed to instantiate")
	else:
		# Try to load directly if not set in export
		var menu_path = "res://scenes/ui/AdminMenu.tscn"
		if ResourceLoader.exists(menu_path):
			var scene = load(menu_path)
			if scene:
				admin_menu = scene.instantiate()
				if admin_menu:
					add_child(admin_menu)
					admin_menu.visible = false
					admin_menu.set_controller(self)
					if placement_controller:
						admin_menu.set_placement_controller(placement_controller)
						placement_controller.set_admin_menu(admin_menu)
					if event_bus:
						event_bus.log("UI: AdminMenu loaded from %s (press F1 or F2 to open)" % menu_path)
				else:
					if event_bus:
						event_bus.log("UI ERROR: AdminMenu scene instantiation failed")
					else:
						push_error("UI ERROR: AdminMenu scene instantiation failed")
			else:
				if event_bus:
					event_bus.log("UI ERROR: Failed to load %s" % menu_path)
				else:
					push_error("UI ERROR: Failed to load %s" % menu_path)
		else:
			if event_bus:
				event_bus.log("UI ERROR: AdminMenu scene not found at %s" % menu_path)
			else:
				push_error("UI ERROR: AdminMenu scene not found at %s" % menu_path)


func _create_admin_button() -> void:
	"""Create on-screen Admin button as fallback for opening menu."""
	# Find the UI CanvasLayer
	var ui_layer = get_node_or_null("UI")
	if ui_layer == null:
		if event_bus:
			event_bus.log("UI ERROR: Cannot find UI CanvasLayer for admin button")
		return
	
	# Create button
	admin_menu_button = Button.new()
	admin_menu_button.text = "Admin"
	admin_menu_button.position = Vector2(10, 10)
	admin_menu_button.custom_minimum_size = Vector2(80, 30)
	admin_menu_button.pressed.connect(_toggle_admin_menu)
	
	# Add to UI layer
	ui_layer.add_child(admin_menu_button)
	
	if event_bus:
		event_bus.log("UI: Admin button created (top-left corner)")



# ====================================================================
# PART 2: SPAWN FUNCTIONS (CALLED BY UI)
# ====================================================================

func spawn_farmer_at(pos: Vector2) -> Farmer:
	"""Spawn a new farmer from FarmerScene PackedScene."""
	if FarmerScene == null:
		if event_bus:
			event_bus.log("ERROR: Cannot spawn farmer - FarmerScene PackedScene is null. Needs proper .tscn with all components!")
		push_error("Cannot spawn farmer: FarmerScene is null - requires full scene with components")
		return null
	
	var f := FarmerScene.instantiate() as Farmer
	if f == null:
		push_error("FarmerScene.instantiate() returned null")
		return null
	
	# Setup
	f.name = "Farmer_%d" % farmer_counter
	farmer_counter += 1
	f.global_position = pos
	add_child(f)
	
	# Allow _ready() to run
	await get_tree().process_frame
	
	# Wire references
	f.market = market
	f.event_bus = event_bus
	
	# Wire HungerNeed component
	var f_hunger = f.get_node_or_null("HungerNeed") as HungerNeed
	var f_inv = f.get_node_or_null("Inventory") as Inventory
	if f_hunger and f_inv:
		f_hunger.bind(f.name, f_inv, event_bus, calendar)
	
	# Wire FoodReserve component
	var f_food_reserve = f.get_node_or_null("FoodReserve") as FoodReserve
	if f_food_reserve and f_inv and f.get_node_or_null("HungerNeed") and f.get_node_or_null("Wallet"):
		f_food_reserve.bind(f_inv, f.get_node("HungerNeed"), market, f.get_node("Wallet"), event_bus, f.name)
	
	# Create a house node for this farmer
	var house = Node2D.new()
	house.name = f.name + "_House"
	house.global_position = pos
	add_child(house)
	
	# Set route nodes (no fields assigned yet)
	f.set_route_nodes(house, null, null, market_node)
	
	# Register
	farmers.append(f)
	f.add_to_group("farmers")
	f.add_to_group("agents")
	
	if event_bus:
		event_bus.log("SPAWN: %s at (%.0f,%.0f)" % [f.name, pos.x, pos.y])
	
	return f


func spawn_baker_at(pos: Vector2) -> Baker:
	"""Spawn a new baker from BakerScene PackedScene."""
	if BakerScene == null:
		if event_bus:
			event_bus.log("ERROR: Cannot spawn baker - BakerScene PackedScene is null. Needs proper .tscn with all components!")
		push_error("Cannot spawn baker: BakerScene is null - requires full scene with components")
		return null
	
	var b := BakerScene.instantiate() as Baker
	if b == null:
		push_error("BakerScene.instantiate() returned null")
		return null
	
	# Setup
	b.name = "Baker_%d" % baker_counter
	baker_counter += 1
	b.global_position = pos
	add_child(b)
	
	# Allow _ready() to run
	await get_tree().process_frame
	
	# Wire references
	b.market = market
	b.event_bus = event_bus
	
	# Wire HungerNeed component
	var b_hunger = b.get_node_or_null("HungerNeed") as HungerNeed
	var b_inv = b.get_node_or_null("Inventory") as Inventory
	if b_hunger and b_inv:
		b_hunger.bind(b.name, b_inv, event_bus, calendar)
	
	# Wire FoodReserve component
	var b_food_reserve = b.get_node_or_null("FoodReserve") as FoodReserve
	if b_food_reserve and b_inv and b.get_node_or_null("HungerNeed") and b.get_node_or_null("Wallet"):
		b_food_reserve.bind(b_inv, b.get_node("HungerNeed"), market, b.get_node("Wallet"), event_bus, b.name)
	
	# Create a bakery node for this baker
	var bakery = Node2D.new()
	bakery.name = b.name + "_Bakery"
	bakery.global_position = pos
	add_child(bakery)
	
	# Set locations
	b.set_locations(bakery, market_node)
	
	# Register
	bakers.append(b)
	b.add_to_group("bakers")
	b.add_to_group("agents")
	
	if event_bus:
		event_bus.log("SPAWN: %s at (%.0f,%.0f)" % [b.name, pos.x, pos.y])
	
	return b


func spawn_field_at(pos: Vector2) -> FieldPlot:
	"""Spawn a new field from FieldScene PackedScene."""
	if event_bus:
		event_bus.log("DEBUG: spawn_field_at called with pos=(%.0f,%.0f), FieldScene=%s" % [pos.x, pos.y, "null" if FieldScene == null else "set"])
	
	if FieldScene == null:
		# Fallback: Create field programmatically if PackedScene not set
		if event_bus:
			event_bus.log("INFO: FieldScene not set, creating field programmatically")
		
		var field = FieldPlot.new()
		field.name = "Field_%d" % field_counter
		field_counter += 1
		field.global_position = pos
		add_child(field)
		
		# Register
		fields.append(field)
		field.add_to_group("fields")
		
		if event_bus:
			event_bus.log("SPAWN: %s at (%.0f,%.0f)" % [field.name, pos.x, pos.y])
		
		return field
	
	# Use PackedScene if available
	var field_instance := FieldScene.instantiate() as FieldPlot
	if field_instance == null:
		push_error("FieldScene.instantiate() returned null")
		return null
	
	# Setup
	field_instance.name = "Field_%d" % field_counter
	field_counter += 1
	field_instance.global_position = pos
	add_child(field_instance)
	
	# Allow _ready() to run
	await get_tree().process_frame
	
	# Register
	fields.append(field_instance)
	field_instance.add_to_group("fields")
	
	if event_bus:
		event_bus.log("SPAWN: %s at (%.0f,%.0f)" % [field_instance.name, pos.x, pos.y])
	
	return field_instance


# ====================================================================
# PART 3: FIELD-FARMER ASSIGNMENT API (CALLED BY UI)
# ====================================================================

func assign_field_to_farmer(field: FieldPlot, farmer_node: Farmer) -> void:
	"""Assign a field to a farmer (bidirectional update)."""
	if field == null or farmer_node == null:
		push_error("assign_field_to_farmer: null parameter")
		return
	
	# Use field's assignment function (handles bidirectional update)
	field.assign_to_farmer(farmer_node)
	
	if event_bus:
		event_bus.log("ASSIGN: %s -> %s" % [field.name, farmer_node.name])


func unassign_field(field: FieldPlot) -> void:
	"""Unassign a field from its current farmer."""
	if field == null:
		push_error("unassign_field: null parameter")
		return
	
	var old_farmer = field.assigned_farmer
	field.unassign_farmer()
	
	if event_bus and old_farmer:
		event_bus.log("UNASSIGN: %s (was %s)" % [field.name, old_farmer.name])


func assign_all_unassigned_to_farmer(farmer_node: Farmer) -> void:
	"""Assign all unassigned fields to a farmer."""
	if farmer_node == null:
		push_error("assign_all_unassigned_to_farmer: null farmer")
		return
	
	var count = 0
	for field in fields:
		if field.assigned_farmer == null:
			assign_field_to_farmer(field, farmer_node)
			count += 1
	
	if event_bus:
		event_bus.log("ASSIGN ALL: %d unassigned fields -> %s" % [count, farmer_node.name])


func unassign_all_from_farmer(farmer_node: Farmer) -> void:
	"""Unassign all fields from a farmer."""
	if farmer_node == null:
		push_error("unassign_all_from_farmer: null farmer")
		return
	
	var count = farmer_node.assigned_fields.size()
	farmer_node.unassign_all_fields()
	
	if event_bus:
		event_bus.log("UNASSIGN ALL: %d fields from %s" % [count, farmer_node.name])
