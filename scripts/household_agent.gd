extends CharacterBody2D
class_name HouseholdAgent

enum Phase { GO_TO_MARKET, WAIT_AT_MARKET, GO_HOME, WAIT_AT_HOME }

var phase: Phase = Phase.GO_TO_MARKET
var target: Node2D = null

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

# State
var bread_consumed: int = 0
var wait_left: float = 0.0


func _ready() -> void:
	# Initialize wallet and inventory
	wallet.money = 5000.0
	inv.items = {"bread": 0}
	
	# Bind food stockpile
	food_stockpile.bind(inv)


func _on_ate_meal(qty: int) -> void:
	bread_consumed += qty


func set_tick(t: int) -> void:
	current_tick = t


func set_locations(home: Node2D, market_node: Node2D) -> void:
	home_location = home
	market_location = market_node
	target = market_location


func _physics_process(delta: float) -> void:
	if target == null:
		return
	
	match phase:
		Phase.GO_TO_MARKET, Phase.GO_HOME:
			move_toward_target(delta)
		Phase.WAIT_AT_MARKET, Phase.WAIT_AT_HOME:
			wait_at_location(delta)


func move_toward_target(delta: float) -> void:
	var direction = (target.global_position - global_position).normalized()
	var distance = global_position.distance_to(target.global_position)
	
	if distance <= ARRIVAL_DISTANCE:
		velocity = Vector2.ZERO
		handle_arrival()
	else:
		velocity = direction * SPEED
	
	move_and_slide()


func handle_arrival() -> void:
	if target == market_location:
		# Arrived at market
		attempt_buy_bread()
		phase = Phase.WAIT_AT_MARKET
		wait_left = WAIT_TIME
	elif target == home_location:
		# Arrived at home
		consume_bread_at_home()
		phase = Phase.WAIT_AT_HOME
		wait_left = WAIT_TIME


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
	# Try to eat bread to restore hunger
	var old_bread = inv.get_qty("bread")
	hunger.try_eat(current_tick)
	var new_bread = inv.get_qty("bread")
	var consumed = old_bread - new_bread
	if consumed > 0:
		bread_consumed += consumed


func wait_at_location(delta: float) -> void:
	wait_left -= delta
	if wait_left <= 0.0:
		if phase == Phase.WAIT_AT_MARKET:
			# Done waiting at market, go home
			target = home_location
			phase = Phase.GO_HOME
		elif phase == Phase.WAIT_AT_HOME:
			# Done waiting at home, go to market
			target = market_location
			phase = Phase.GO_TO_MARKET


func get_status_text() -> String:
	match phase:
		Phase.GO_TO_MARKET:
			return "Going to Market"
		Phase.WAIT_AT_MARKET:
			return "Waiting at Market"
		Phase.GO_HOME:
			return "Going Home"
		Phase.WAIT_AT_HOME:
			if inv.get_qty("bread") > 0:
				return "Eating"
			else:
				return "Waiting at Home"
	
	return "Unknown"
