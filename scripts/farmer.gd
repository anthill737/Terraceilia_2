extends CharacterBody2D
class_name Farmer

enum State { WALKING, WAITING }

var state: State = State.WAITING
var current_target: Node2D = null

# Route nodes
var house_node: Node2D = null
var field1_node: Node2D = null
var field2_node: Node2D = null
var market_node: Node2D = null
var route_targets: Array[Node2D] = []
var route_index: int = 0

# Field references
var field1_plot: FieldPlot = null
var field2_plot: FieldPlot = null

const SPEED: float = 100.0
const ARRIVAL_DISTANCE: float = 5.0
const WAIT_TIME: float = 1.0

var wait_timer: float = 0.0

# Components
@onready var wallet: Wallet = $Wallet
@onready var inv: Inventory = $Inventory
@onready var hunger: HungerNeed = $HungerNeed
@onready var food_stockpile: FoodStockpile = $FoodStockpile

# Reference to market
var market: Market = null

# Event logging
var event_bus: EventBus = null
var current_tick: int = 0


func set_tick(t: int) -> void:
	current_tick = t
	if t == 0 and event_bus:
		event_bus.log("Tick 0: Farmer starting food=%d" % inv.get_qty("bread"))


func _ready() -> void:
	wait_timer = WAIT_TIME
	
	# Initialize wallet and inventory
	wallet.money = 1000.0
	inv.items = {"seeds": 100, "wheat": 0, "bread": 2}
	
	# Bind food stockpile
	food_stockpile.bind(inv)


func set_route_nodes(house: Node2D, field1: Node2D, field2: Node2D, market: Node2D) -> void:
	house_node = house
	field1_node = field1
	field2_node = field2
	market_node = market
	route_targets = [house_node, field1_node, field2_node, market_node]
	route_index = 0
	current_target = route_targets[route_index]


func set_fields(field1: FieldPlot, field2: FieldPlot) -> void:
	field1_plot = field1
	field2_plot = field2


func _physics_process(delta: float) -> void:
	if current_target == null or hunger.is_starving:
		return
	
	match state:
		State.WALKING:
			walk_toward_target(delta)
		State.WAITING:
			wait_at_location(delta)


func walk_toward_target(delta: float) -> void:
	var direction = (current_target.global_position - global_position).normalized()
	var distance = global_position.distance_to(current_target.global_position)
	
	if distance <= ARRIVAL_DISTANCE:
		velocity = Vector2.ZERO
		state = State.WAITING
		wait_timer = WAIT_TIME
		# Perform actions at arrival
		handle_arrival()
	else:
		velocity = direction * SPEED
	
	move_and_slide()


func wait_at_location(delta: float) -> void:
	wait_timer -= delta
	if wait_timer <= 0.0:
		advance_to_next_target()
		state = State.WALKING


func advance_to_next_target() -> void:
	route_index = (route_index + 1) % route_targets.size()
	current_target = route_targets[route_index]


func handle_arrival() -> void:
	if current_target == house_node:
		handle_house_arrival()
	elif current_target == field1_node:
		handle_field_arrival(field1_plot, "Field1")
	elif current_target == field2_node:
		handle_field_arrival(field2_plot, "Field2")
	elif current_target == market_node:
		handle_market_arrival()


func handle_house_arrival() -> void:
	# Try to eat bread to restore hunger
	hunger.try_eat(current_tick)


func handle_field_arrival(field: FieldPlot, field_name: String) -> void:
	# Check if field is mature and harvest
	if field.is_mature():
		var harvest_result = field.harvest()
		inv.add("wheat", harvest_result.wheat)
		inv.add("seeds", harvest_result.seeds)
		if event_bus:
			event_bus.log("Tick %d: Farmer harvested %s (+%d wheat, +%d seeds)" % [current_tick, field_name, harvest_result.wheat, harvest_result.seeds])
	# Otherwise try to plant if field is empty and we have seeds
	elif field.state == FieldPlot.State.EMPTY and inv.get_qty("seeds") >= 1:
		if field.plant():
			inv.remove("seeds", 1)
			if event_bus:
				event_bus.log("Tick %d: Farmer planted %s (-1 seed)" % [current_tick, field_name])


func handle_market_arrival() -> void:
	# Sell all wheat to market
	if inv.get_qty("wheat") > 0:
		market.buy_wheat_from_farmer(self)
	
	# Buy seeds if below threshold
	if inv.get_qty("seeds") < 20:
		market.sell_seeds_to_farmer(self)
	
	# Buy bread to reach food buffer target
	var needed: int = food_stockpile.needed_to_reach_target()
	if needed > 0:
		var bought: int = market.sell_bread_to_agent(self, needed)
		inv.add("bread", bought)
		if bought > 0 and event_bus:
			event_bus.log("Tick %d: Farmer bought %d bread for food buffer" % [current_tick, bought])


func get_status_text() -> String:
	if hunger.is_starving:
		return "STARVING (inactive)"
	
	if state == State.WAITING:
		if current_target == house_node:
			return "Waiting at House"
		elif current_target == field1_node:
			return "Waiting at Field1"
		elif current_target == field2_node:
			return "Waiting at Field2"
		elif current_target == market_node:
			return "At Market (trading)"
		else:
			return "Waiting"
	elif state == State.WALKING:
		if current_target == house_node:
			return "Walking to House"
		elif current_target == field1_node:
			return "Walking to Field1"
		elif current_target == field2_node:
			return "Walking to Field2"
		elif current_target == market_node:
			return "Walking to Market"
		else:
			return "Walking"
	
	return "Unknown"
