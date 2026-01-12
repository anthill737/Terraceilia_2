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
var household_status_label: Label
var event_log: RichTextLabel

var log_lines: Array[String] = []
const MAX_LOG_LINES: int = 200


func _ready() -> void:
	# Create simulation systems
	clock = SimulationClock.new()
	clock.name = "SimulationClock"
	add_child(clock)
	clock.ticked.connect(_on_tick)
	
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
	market.set_tick(tick)
	farmer.set_tick(tick)
	baker.set_tick(tick)
	household_agent.set_tick(tick)
	
	# Run audit checks
	audit.audit(farmer, baker, market, bus, tick)


func _on_event_logged(msg: String) -> void:
	log_lines.append(msg)
	
	# Trim to max lines
	while log_lines.size() > MAX_LOG_LINES:
		log_lines.pop_front()
	
	# Update event log display
	if event_log:
		event_log.clear()
		for line in log_lines:
			event_log.append_text(line + "\n")


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
	
	baker_status_label = baker_card.get_node("BakerStatus")
	baker_money_label = baker_card.get_node("BakerMoney")
	baker_wheat_label = baker_card.get_node("BakerWheat")
	baker_flour_label = baker_card.get_node("BakerFlour")
	baker_bread_label = baker_card.get_node("BakerBread")
	baker_food_bread_label = baker_card.get_node("BakerFoodBread")
	baker_days_until_starve_label = baker_card.get_node("BakerDaysUntilStarve")
	baker_starving_label = baker_card.get_node("BakerStarving")
	
	household_status_label = household_card.get_node("HouseholdStatus")
	household_money_label = household_card.get_node("HouseholdMoney")
	household_bread_label = household_card.get_node("HouseholdBread")
	household_bread_consumed_label = household_card.get_node("HouseholdBreadConsumed")
	
	market_money_label = market_card.get_node("MarketMoney")
	market_seeds_label = market_card.get_node("MarketSeeds")
	market_wheat_label = market_card.get_node("MarketWheat")
	market_wheat_cap_label = market_card.get_node("MarketWheatCap")
	market_bread_label = market_card.get_node("MarketBread")
	market_bread_cap_label = market_card.get_node("MarketBreadCap")
	wheat_price_label = market_card.get_node("WheatPrice")
	bread_price_label = market_card.get_node("BreadPrice")
	
	event_log = log_vbox.get_node("EventLog")


func update_ui() -> void:
	if farmer:
		farmer_status_label.text = "Status: " + farmer.get_status_text()
		farmer_money_label.text = "Farmer Money: $%.2f" % farmer.get_node("Wallet").money
		farmer_seeds_label.text = "Farmer Seeds: %d" % farmer.get_node("Inventory").get_qty("seeds")
		farmer_wheat_label.text = "Farmer Wheat: %d" % farmer.get_node("Inventory").get_qty("wheat")
		farmer_bread_label.text = "Farmer Bread: %d" % farmer.get_node("Inventory").get_qty("bread")
		var farmer_hunger = farmer.get_node("HungerNeed")
		farmer_days_until_starve_label.text = "Farmer Hunger Days: %d/%d" % [farmer_hunger.hunger_days, farmer_hunger.hunger_max_days]
		farmer_starving_label.text = "Farmer Starving: %s" % ("Yes" if farmer_hunger.is_starving else "No")
	
	if market:
		market_money_label.text = "Market Money: $%.2f" % market.money
		market_seeds_label.text = "Market Seeds: %d" % market.seeds
		market_wheat_label.text = "Market Wheat: %d" % market.wheat
		market_wheat_cap_label.text = "Market Wheat: %d/%d" % [market.wheat, market.wheat_capacity]
		market_bread_label.text = "Market Bread: %d" % market.bread
		market_bread_cap_label.text = "Market Bread: %d/%d" % [market.bread, market.bread_capacity]
		wheat_price_label.text = "Wheat Price: $%.2f (floor $%.2f)" % [market.wheat_price, market.WHEAT_PRICE_FLOOR]
		bread_price_label.text = "Bread Price: $%.2f (floor $%.2f)" % [market.bread_price, market.BREAD_PRICE_FLOOR]
	
	if baker:
		baker_status_label.text = "Status: " + baker.get_status_text()
		baker_money_label.text = "Baker Money: $%.2f" % baker.get_node("Wallet").money
		baker_wheat_label.text = "Baker Wheat: %d" % baker.get_node("Inventory").get_qty("wheat")
		baker_flour_label.text = "Baker Flour: %d" % baker.get_node("Inventory").get_qty("flour")
		baker_bread_label.text = "Baker Bread: %d" % baker.get_node("Inventory").get_qty("bread")
		baker_food_bread_label.text = "Baker Food Bread: %d" % baker.get_node("Inventory").get_qty("bread")
		var baker_hunger = baker.get_node("HungerNeed")
		baker_days_until_starve_label.text = "Baker Hunger Days: %d/%d" % [baker_hunger.hunger_days, baker_hunger.hunger_max_days]
		baker_starving_label.text = "Baker Starving: %s" % ("Yes" if baker_hunger.is_starving else "No")
	
	if household_agent:
		household_status_label.text = "Status: " + household_agent.get_status_text()
		household_money_label.text = "Household Money: $%.2f" % household_agent.get_node("Wallet").money
		household_bread_label.text = "Household Bread: %d" % household_agent.get_node("Inventory").get_qty("bread")
		household_bread_consumed_label.text = "Household Bread Consumed: %d" % household_agent.bread_consumed
