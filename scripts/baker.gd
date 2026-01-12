extends CharacterBody2D
class_name Baker

enum State { WALKING, WAITING, GRINDING, BAKING }

var state: State = State.WAITING
var current_target: Node2D = null
var bakery_location: Node2D = null
var market_location: Node2D = null

const SPEED: float = 100.0
const ARRIVAL_DISTANCE: float = 5.0
const WAIT_TIME: float = 1.0
const GRINDING_TIME: float = 2.0
const BAKING_TIME: float = 2.0

var wait_timer: float = 0.0
var process_timer: float = 0.0

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
		event_bus.log("Tick 0: Baker starting food=%d" % inv.get_qty("bread"))


func _ready() -> void:
	wait_timer = WAIT_TIME
	
	# Initialize wallet and inventory
	wallet.money = 500.0
	inv.items = {"wheat": 0, "flour": 0, "bread": 2}
	
	# Bind food stockpile
	food_stockpile.bind(inv)


func set_locations(bakery: Node2D, market: Node2D) -> void:
	bakery_location = bakery
	market_location = market
	current_target = market_location


func _physics_process(delta: float) -> void:
	if bakery_location == null or market_location == null or hunger.is_starving:
		return
	
	match state:
		State.WALKING:
			walk_toward_target(delta)
		State.WAITING:
			wait_at_location(delta)
		State.GRINDING:
			process_grinding(delta)
		State.BAKING:
			process_baking(delta)


func walk_toward_target(delta: float) -> void:
	var direction = (current_target.global_position - global_position).normalized()
	var distance = global_position.distance_to(current_target.global_position)
	
	if distance <= ARRIVAL_DISTANCE:
		velocity = Vector2.ZERO
		state = State.WAITING
		wait_timer = WAIT_TIME
		# Perform actions at arrival
		if current_target == market_location and market != null:
			perform_market_transactions()
		elif current_target == bakery_location:
			handle_bakery_arrival()
	else:
		velocity = direction * SPEED
	
	move_and_slide()


func wait_at_location(delta: float) -> void:
	wait_timer -= delta
	if wait_timer <= 0.0:
		switch_target()
		state = State.WALKING


func switch_target() -> void:
	if current_target == bakery_location:
		current_target = market_location
	else:
		current_target = bakery_location


func perform_market_transactions() -> void:
	# Sell bread to market, but keep food buffer
	var sellable: int = max(0, inv.get_qty("bread") - food_stockpile.target_buffer)
	if sellable > 0:
		market.buy_bread_from_agent(self, sellable)
	
	# Buy wheat if below threshold
	var current_wheat: int = inv.get_qty("wheat")
	if current_wheat < 20:
		var needed: int = 20 - current_wheat
		market.sell_wheat_to_baker(self, needed)
	
	# Buy bread to reach food buffer target
	var needed: int = food_stockpile.needed_to_reach_target()
	if needed > 0:
		var bought: int = market.sell_bread_to_agent(self, needed)
		inv.add("bread", bought)
		if bought > 0 and event_bus:
			event_bus.log("Tick %d: Baker bought %d bread for food buffer" % [current_tick, bought])


func handle_bakery_arrival() -> void:
	# Try to eat bread to restore hunger
	hunger.try_eat(current_tick)
	
	# Start production if not starving
	if not hunger.is_starving:
		start_production()


func start_production() -> void:
	# Start grinding if we have wheat
	if inv.get_qty("wheat") > 0:
		state = State.GRINDING
		process_timer = GRINDING_TIME
	# Otherwise start baking if we have flour
	elif inv.get_qty("flour") > 0:
		state = State.BAKING
		process_timer = BAKING_TIME
	# If nothing to process, just wait
	else:
		state = State.WAITING
		wait_timer = WAIT_TIME


func process_grinding(delta: float) -> void:
	process_timer -= delta
	if process_timer <= 0.0:
		# Convert wheat to flour (1 wheat → 2 flour)
		var wheat_amount: int = inv.get_qty("wheat")
		inv.add("flour", wheat_amount * 2)
		inv.set_qty("wheat", 0)
		
		if event_bus:
			event_bus.log("Tick %d: Baker converted %d wheat to %d flour" % [current_tick, wheat_amount, wheat_amount * 2])
		
		# Check if we can start baking immediately
		if inv.get_qty("flour") > 0:
			state = State.BAKING
			process_timer = BAKING_TIME
		else:
			state = State.WAITING
			wait_timer = WAIT_TIME


func process_baking(delta: float) -> void:
	process_timer -= delta
	if process_timer <= 0.0:
		# Convert flour to bread (1 flour → 3 bread)
		var flour_amount: int = inv.get_qty("flour")
		inv.add("bread", flour_amount * 3)
		inv.set_qty("flour", 0)
		
		if event_bus:
			event_bus.log("Tick %d: Baker converted %d flour to %d bread" % [current_tick, flour_amount, flour_amount * 3])
		
		# Done processing, wait before leaving
		state = State.WAITING
		wait_timer = WAIT_TIME


func get_status_text() -> String:
	if hunger.is_starving:
		return "STARVING (inactive)"
	
	match state:
		State.GRINDING:
			return "Grinding wheat"
		State.BAKING:
			return "Baking bread"
		State.WAITING:
			if current_target == bakery_location:
				return "Waiting at Bakery"
			elif current_target == market_location:
				return "Waiting at Market"
			else:
				return "Waiting"
		State.WALKING:
			if current_target == bakery_location:
				return "Walking to Bakery"
			elif current_target == market_location:
				return "Walking to Market"
			else:
				return "Walking"
	
	return "Unknown"
