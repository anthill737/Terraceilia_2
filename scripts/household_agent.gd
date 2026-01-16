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

# Validation flag - only log missing nodes once
var _validation_logged: bool = false


func _ready() -> void:
	# Validate critical child nodes exist
	if not _validation_logged:
		_validate_components()
	
	# Initialize wallet and inventory
	if wallet:
		wallet.money = 5000.0
	if inv:
		inv.items = {"bread": 0}
	
	# Bind capacity to inventory
	if cap and inv:
		cap.bind(inv)
		inv.bind_capacity(cap)
	
	# Bind food stockpile
	if food_stockpile and inv:
		food_stockpile.bind(inv)
	
	# Bind RouteRunner
	if route:
		route.bind(self)
		route.speed = SPEED
		route.arrival_distance = ARRIVAL_DISTANCE
		route.arrived.connect(_on_arrived)
		route.wait_finished.connect(_on_wait_finished)


func _validate_components() -> void:
	"""Validate all critical child nodes exist. Log once per instance."""
	var missing: Array[String] = []
	
	if not wallet:
		missing.append("Wallet")
	if not inv:
		missing.append("Inventory")
	if not hunger:
		missing.append("HungerNeed")
	if not food_stockpile:
		missing.append("FoodStockpile")
	if not route:
		missing.append("RouteRunner")
	if not cap:
		missing.append("InventoryCapacity")
	if not food_reserve:
		missing.append("FoodReserve")
	
	if missing.size() > 0:
		push_error("%s: Missing critical child nodes: %s" % [get_name(), ", ".join(missing)])
		_validation_logged = true
	else:
		_validation_logged = true


func _on_ate_meal(qty: int) -> void:
	bread_consumed += qty


func get_display_name() -> String:
	return "Household"


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
		attempt_buy_bread()
		phase = Phase.AT_MARKET
		pending_target = home_location
		route.wait(WAIT_TIME)
	elif t == home_location:
		# Arrived at home
		consume_bread_at_home()
		phase = Phase.AT_HOME
		pending_target = market_location
		route.wait(WAIT_TIME)


func _on_wait_finished() -> void:
	if pending_target != null:
		route.set_target(pending_target)
		pending_target = null


func attempt_buy_bread() -> void:
	# Buy bread to reach food buffer target
	var needed: int = food_stockpile.needed_to_reach_target()
	if needed > 0:
		var bought: int = market.sell_bread_to_household(self, needed)
		inv.add("bread", bought)
		
		if event_bus:
			if bought > 0:
				event_bus.log("Tick %d: Household bought %d bread" % [current_tick, bought])
			else:
				event_bus.log("Tick %d: Household tried to buy bread, bought 0" % current_tick)


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
