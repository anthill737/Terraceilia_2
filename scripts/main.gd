extends Node

var farmer: Farmer = null
var baker: Baker = null
var market: Market = null
var household_agent: HouseholdAgent = null
var clock: SimulationClock = null
var bus: EventBus = null
var audit: EconomyAudit = null
var calendar: Calendar = null

# Field plots
var field1_plot: FieldPlot = null
var field2_plot: FieldPlot = null

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

var log_lines: Array[String] = []
var log_buffer: Array[String] = []  # Full log for export (not trimmed)
var user_at_bottom: bool = true  # Track if user is at bottom for sticky auto-scroll
const MAX_LOG_LINES: int = 200
const SCROLL_THRESHOLD: int = 50  # Pixels from bottom to consider "at bottom"


func _ready() -> void:
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
	
	# Get references to scene nodes
	var house = get_node("House")
	var field1_node = get_node("Field1")
	var field2_node = get_node("Field2")
	var market_node = get_node("MarketNode")
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
	
	# Update tick for all agents
	if market:
		market.set_tick(tick)
	if farmer:
		farmer.set_tick(tick)
	if baker:
		baker.set_tick(tick)
	if household_agent:
		household_agent.set_tick(tick)
	
	# Run audit checks
	audit.audit(farmer, baker, market, bus, tick)


func _input(event: InputEvent) -> void:
	if clock == null:
		return
	if event.is_action_pressed("speed_up"):
		clock.increase_speed()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("speed_down"):
		clock.decrease_speed()
		get_viewport().set_input_as_handled()


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
