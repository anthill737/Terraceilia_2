extends CharacterBody2D
class_name Baker

## Baker agent - buys wheat, grinds flour, bakes bread, sells at market.
## Movement is handled by RouteRunner component.

enum ProductionState { IDLE, GRINDING, BAKING }

var production_state: ProductionState = ProductionState.IDLE
var bakery_location: Node2D = null
var market_location: Node2D = null

const SPEED: float = 100.0
const ARRIVAL_DISTANCE: float = 5.0
const WAIT_TIME: float = 1.0
const GRINDING_TIME: float = 2.0
const BAKING_TIME: float = 2.0

# Production recipe parameters
const GRIND_BATCH_SIZE: int = 5
const BAKE_BATCH_SIZE: int = 5
const FLOUR_PER_WHEAT: int = 1
const BREAD_PER_FLOUR: int = 2
const DELIVER_BREAD_THRESHOLD: int = 20

var process_timer: float = 0.0

# Components
@onready var wallet: Wallet = $Wallet
@onready var inv: Inventory = $Inventory
@onready var hunger: HungerNeed = $HungerNeed
@onready var food_stockpile: FoodStockpile = $FoodStockpile
@onready var route: RouteRunner = $RouteRunner
@onready var cap: InventoryCapacity = $InventoryCapacity
@onready var prod: ProductionBatch = $ProductionBatch

# Reference to market
var market: Market = null

# Event logging
var event_bus: EventBus = null
var current_tick: int = 0

# Pending target for after waiting
var pending_target: Node2D = null


func set_tick(t: int) -> void:
	current_tick = t
	if t == 0 and event_bus:
		event_bus.log("Tick 0: Baker starting food=%d" % inv.get_qty("bread"))


func _ready() -> void:
	# Initialize wallet and inventory
	wallet.money = 500.0
	inv.items = {"wheat": 0, "flour": 0, "bread": 2}
	
	# Bind capacity to inventory
	cap.bind(inv)
	inv.bind_capacity(cap)
	
	# Bind production batch
	prod.bind(inv, cap)
	
	# Bind food stockpile
	food_stockpile.bind(inv)
	
	# Bind RouteRunner
	route.bind(self)
	route.speed = SPEED
	route.arrival_distance = ARRIVAL_DISTANCE
	route.arrived.connect(_on_arrived)
	route.wait_finished.connect(_on_wait_finished)


func set_locations(bakery: Node2D, market_node: Node2D) -> void:
	bakery_location = bakery
	market_location = market_node
	route.set_target(market_location)


func _physics_process(delta: float) -> void:
	# Stop movement if starving
	if hunger.is_starving:
		route.stop()
		return
	
	# Handle production states (grinding/baking) while at bakery
	match production_state:
		ProductionState.GRINDING:
			process_grinding(delta)
		ProductionState.BAKING:
			process_baking(delta)


func _on_arrived(t: Node2D) -> void:
	if t == market_location and market != null:
		perform_market_transactions()
		# After market, go to bakery
		pending_target = bakery_location
		route.wait(WAIT_TIME)
	elif t == bakery_location:
		handle_bakery_arrival()


func _on_wait_finished() -> void:
	# Only set next target if we're not in production
	if production_state == ProductionState.IDLE and pending_target != null:
		route.set_target(pending_target)
		pending_target = null


func perform_market_transactions() -> void:
	# Sell bread to market, but keep food buffer
	var sellable: int = max(0, inv.get_qty("bread") - food_stockpile.target_buffer)
	if sellable > 0:
		market.buy_bread_from_agent(self, sellable)
	
	# Buy wheat if below threshold
	var current_wheat: int = inv.get_qty("wheat")
	if current_wheat < 20:
		var wheat_needed: int = 20 - current_wheat
		market.sell_wheat_to_baker(self, wheat_needed)
	
	# Buy bread to reach food buffer target
	var bread_needed: int = food_stockpile.needed_to_reach_target()
	if bread_needed > 0:
		var bought: int = market.sell_bread_to_agent(self, bread_needed)
		inv.add("bread", bought)
		if bought > 0 and event_bus:
			event_bus.log("Tick %d: Baker bought %d bread for food buffer" % [current_tick, bought])


func handle_bakery_arrival() -> void:
	# Try to eat bread to restore hunger
	hunger.try_eat(current_tick)
	
	# Start production if not starving
	if not hunger.is_starving:
		start_production()
	else:
		# If starving, just wait then go to market
		pending_target = market_location
		route.wait(WAIT_TIME)


func start_production() -> void:
	# Stop RouteRunner during production to prevent repeated arrival signals
	route.stop()
	
	# Start grinding if we have wheat
	if inv.get_qty("wheat") > 0:
		production_state = ProductionState.GRINDING
		process_timer = GRINDING_TIME
	# Otherwise start baking if we have flour
	elif inv.get_qty("flour") > 0:
		production_state = ProductionState.BAKING
		process_timer = BAKING_TIME
	# If nothing to process, wait then go to market
	else:
		pending_target = market_location
		route.wait(WAIT_TIME)


func process_grinding(delta: float) -> void:
	process_timer -= delta
	if process_timer <= 0.0:
		# Compute safe batch size
		var units: int = prod.compute_batch(GRIND_BATCH_SIZE, "wheat", "flour", FLOUR_PER_WHEAT)
		
		if units == 0:
			# No wheat or no space
			if inv.get_qty("wheat") == 0:
				# Switch to baking if we have flour, else go to market
				if inv.get_qty("flour") > 0:
					production_state = ProductionState.BAKING
					process_timer = BAKING_TIME
				else:
					production_state = ProductionState.IDLE
					pending_target = market_location
					route.wait(WAIT_TIME)
			else:
				# No space - go to market to sell bread
				production_state = ProductionState.IDLE
				pending_target = market_location
				route.wait(WAIT_TIME)
		else:
			# Convert wheat to flour
			var ok: bool = prod.convert("wheat", "flour", units, FLOUR_PER_WHEAT)
			if not ok:
				if event_bus:
					event_bus.log("ERROR Tick %d: Baker grinding failed due to capacity/rollback safety" % current_tick)
				production_state = ProductionState.IDLE
				pending_target = market_location
				route.wait(WAIT_TIME)
			else:
				var flour_produced: int = units * FLOUR_PER_WHEAT
				if event_bus:
					event_bus.log("Tick %d: Baker ground %d wheat into %d flour" % [current_tick, units, flour_produced])
				
				# Decide next action: continue production or deliver to market
				var current_bread: int = inv.get_qty("bread")
				var current_flour: int = inv.get_qty("flour")
				var current_wheat: int = inv.get_qty("wheat")
				
				# Go to market if we have enough bread to deliver
				if current_bread >= DELIVER_BREAD_THRESHOLD:
					production_state = ProductionState.IDLE
					pending_target = market_location
					route.wait(WAIT_TIME)
				# Continue to baking if we have flour and space for bread
				elif current_flour > 0 and cap.remaining_space() >= BREAD_PER_FLOUR:
					production_state = ProductionState.BAKING
					process_timer = BAKING_TIME
				# Continue grinding if we have wheat and space for flour
				elif current_wheat > 0 and cap.remaining_space() >= FLOUR_PER_WHEAT:
					production_state = ProductionState.GRINDING
					process_timer = GRINDING_TIME
				else:
					# Blocked: go to market to sell or buy
					production_state = ProductionState.IDLE
					pending_target = market_location
					route.wait(WAIT_TIME)
				# Blocked: go to market to sell or buy

func process_baking(delta: float) -> void:
	process_timer -= delta
	if process_timer <= 0.0:
		# Compute safe batch size
		var units: int = prod.compute_batch(BAKE_BATCH_SIZE, "flour", "bread", BREAD_PER_FLOUR)
		
		if units == 0:
			# No flour or no space
			if inv.get_qty("flour") == 0:
				# Switch to grinding if we have wheat, else go to market
				if inv.get_qty("wheat") > 0:
					production_state = ProductionState.GRINDING
					process_timer = GRINDING_TIME
				else:
					production_state = ProductionState.IDLE
					pending_target = market_location
					route.wait(WAIT_TIME)
			else:
				# No space - go to market to sell bread
				production_state = ProductionState.IDLE
				pending_target = market_location
				route.wait(WAIT_TIME)
		else:
			# Convert flour to bread
			var ok: bool = prod.convert("flour", "bread", units, BREAD_PER_FLOUR)
			if not ok:
				if event_bus:
					event_bus.log("ERROR Tick %d: Baker baking failed due to capacity/rollback safety" % current_tick)
				production_state = ProductionState.IDLE
				pending_target = market_location
				route.wait(WAIT_TIME)
			else:
				var bread_produced: int = units * BREAD_PER_FLOUR
				if event_bus:
					event_bus.log("Tick %d: Baker baked %d flour into %d bread" % [current_tick, units, bread_produced])
				
				# Decide next action: continue production or deliver to market
				var current_bread: int = inv.get_qty("bread")
				var current_flour: int = inv.get_qty("flour")
				var current_wheat: int = inv.get_qty("wheat")
				
				# Go to market if we have enough bread to deliver
				if current_bread >= DELIVER_BREAD_THRESHOLD:
					production_state = ProductionState.IDLE
					pending_target = market_location
					route.wait(WAIT_TIME)
				# Continue baking if we have flour and space for bread
				elif current_flour > 0 and cap.remaining_space() >= BREAD_PER_FLOUR:
					production_state = ProductionState.BAKING
					process_timer = BAKING_TIME
				# Switch to grinding if we have wheat and space for flour
				elif current_wheat > 0 and cap.remaining_space() >= FLOUR_PER_WHEAT:
					production_state = ProductionState.GRINDING
					process_timer = GRINDING_TIME
				else:
					# Blocked: go to market to sell or buy
					production_state = ProductionState.IDLE
					pending_target = market_location
					route.wait(WAIT_TIME)


func get_status_text() -> String:
	
	match production_state:
		ProductionState.GRINDING:
			return "Grinding wheat"
		ProductionState.BAKING:
			return "Baking bread"
	
	# Use RouteRunner status with context
	if route.target == bakery_location:
		if route.is_waiting:
			return "Waiting at Bakery"
		return "Walking to Bakery"
	elif route.target == market_location:
		if route.is_waiting:
			return "Waiting at Market"
		return "Walking to Market"
	
	return route.get_status_text()
