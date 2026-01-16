extends CharacterBody2D
class_name HouseholdAgent

## Household agent - buys bread at market, consumes at home.
## Movement is handled by RouteRunner component.

enum Phase { AT_MARKET, AT_HOME }

var phase: Phase = Phase.AT_MARKET

# Locations
var home_location: Node2D = null
var market_location: Node2D = null

# References
var market: Market = null
var event_bus: EventBus = null
var current_tick: int = 0

# Constants
const SPEED: float = 100.0
const ARRIVAL_DISTANCE: float = 5.0
const WAIT_TIME: float = 1.0

# Components
@onready var wallet: Wallet = $Wallet
@onready var inv: Inventory = $Inventory
@onready var hunger: HungerNeed = $HungerNeed
@onready var food_stockpile: FoodStockpile = $FoodStockpile
@onready var route: RouteRunner = $RouteRunner
@onready var cap: InventoryCapacity = $InventoryCapacity
@onready var food_reserve: FoodReserve = $FoodReserve

# State
var bread_consumed: int = 0

# Pending target for after waiting
var pending_target: Node2D = null


func _ready() -> void:
	# Get component references if @onready didn't work (e.g., from PackedScene instantiation)
	if not wallet:
		wallet = get_node_or_null("Wallet")
	if not inv:
		inv = get_node_or_null("Inventory")
	if not hunger:
		hunger = get_node_or_null("HungerNeed")
	if not food_stockpile:
		food_stockpile = get_node_or_null("FoodStockpile")
	if not route:
		route = get_node_or_null("RouteRunner")
	if not cap:
		cap = get_node_or_null("InventoryCapacity")
	if not food_reserve:
		food_reserve = get_node_or_null("FoodReserve")
	
	# Validate critical components exist
	if not wallet or not inv or not hunger or not food_stockpile or not route or not cap:
		push_error("%s: Missing critical components in _ready()" % name)
		return
	
	# Initialize wallet and inventory
	wallet.money = 5000.0
	inv.items = {"bread": 0}
	
	# Bind capacity to inventory
	cap.bind(inv)
	inv.bind_capacity(cap)
	
	# Bind food stockpile
	food_stockpile.bind(inv)
	
	# Bind RouteRunner
	route.bind(self)
	route.speed = SPEED
	route.arrival_distance = ARRIVAL_DISTANCE
	route.arrived.connect(_on_arrived)
	route.wait_finished.connect(_on_wait_finished)


func _on_ate_meal(qty: int) -> void:
	bread_consumed += qty


func get_display_name() -> String:
	return name  # Return actual node name (e.g., "Household", "Household_2")


func set_tick(t: int) -> void:
	current_tick = t
	if food_reserve:
		food_reserve.set_tick(t)
		food_reserve.check_survival_mode()
		# Update survival override (though household doesn't produce food)
		food_reserve.update_survival_override()


func set_locations(home: Node2D, market_node: Node2D) -> void:
	home_location = home
	market_location = market_node
	# Bind food reserve
	if food_reserve and market:
		food_reserve.bind(inv, hunger, market, wallet, event_bus, get_display_name())
	route.set_target(market_location)


func _on_arrived(t: Node2D) -> void:
	if t == market_location:
		# Arrived at market
		if event_bus:
			event_bus.log("Tick %d: %s arrived at market" % [current_tick, get_display_name()])
		attempt_buy_bread()
		phase = Phase.AT_MARKET
		pending_target = home_location
		route.wait(WAIT_TIME)
	elif t == home_location:
		# Arrived at home
		if event_bus:
			event_bus.log("Tick %d: %s arrived at home" % [current_tick, get_display_name()])
		consume_bread_at_home()
		phase = Phase.AT_HOME
		pending_target = market_location
		route.wait(WAIT_TIME)


func _on_wait_finished() -> void:
	if pending_target != null:
		route.set_target(pending_target)
		pending_target = null


func attempt_buy_bread() -> void:
	# Diagnostic: confirm this function is being called
	if event_bus and current_tick % 100 == 0:
		event_bus.log("DEBUG: %s.attempt_buy_bread() called at tick %d" % [get_display_name(), current_tick])
	
	# Buy bread to reach food buffer target
	var needed: int = food_stockpile.needed_to_reach_target()
	if needed > 0:
		if not market:
			if event_bus:
				event_bus.log("ERROR: %s has no market reference!" % get_display_name())
			return
		
		var bought: int = market.sell_bread_to_household(self, needed)
		inv.add("bread", bought)
		
		if event_bus:
			if bought > 0:
				event_bus.log("Tick %d: %s bought %d bread (needed %d)" % [current_tick, get_display_name(), bought, needed])
			else:
				event_bus.log("Tick %d: %s tried to buy %d bread, bought 0 (market empty or no money)" % [current_tick, get_display_name(), needed])
	else:
		# Log periodically even when not buying (for debugging spawned households)
		if current_tick % 50 == 0 and event_bus:
			event_bus.log("Tick %d: %s at market, no purchase needed (has %d bread, target %d)" % [
				current_tick, get_display_name(), inv.get_qty("bread"), food_stockpile.target_buffer
			])


func consume_bread_at_home() -> void:
	# Eating handled by HungerNeed auto-eat mechanic
	pass


func get_status_text() -> String:
	# Use RouteRunner status with context
	if route.target == market_location:
		if route.is_waiting:
			return "Waiting at Market"
		return "Going to Market"
	elif route.target == home_location:
		if route.is_waiting:
			if inv.get_qty("bread") > 0:
				return "Eating"
			return "Waiting at Home"
		return "Going Home"
	
	return route.get_status_text()
