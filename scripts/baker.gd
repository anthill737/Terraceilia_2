extends CharacterBody2D
class_name Baker

## Baker agent - buys wheat, grinds flour, bakes bread, sells at market.
## Movement is handled by RouteRunner component.
## Baker NEVER buys bread - only eats from own inventory when hungry.

enum ProductionState { IDLE, GRINDING, BAKING }
enum Phase { RESTOCK, PRODUCE, SELL }

var production_state: ProductionState = ProductionState.IDLE
var phase: Phase = Phase.RESTOCK
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

# Batch cycle thresholds
const WHEAT_LOW_WATERMARK: int = 5  # Buy wheat when below this
const WHEAT_TARGET_STOCK: int = 30  # Restock to this amount
const BREAD_SELL_THRESHOLD: int = 20  # Sell when bread reaches this
const BREAD_PRODUCTION_MIN: int = 2  # Keep at least this much bread for eating

# Production recipe for profitability checking (full wheat→bread chain)
# Note: 2 wheat → 2 flour (1:1 ratio), then 2 flour → 4 bread (1:2 ratio)
# So effectively: 2 wheat → 4 bread (1:2 ratio)
const BREAD_RECIPE: Dictionary = {
	"output_good": "bread",
	"output_quantity": 4,
	"inputs": {"wheat": 2}
}

var process_timer: float = 0.0

# Components
@onready var wallet: Wallet = $Wallet
@onready var inv: Inventory = $Inventory
@onready var hunger: HungerNeed = $HungerNeed
@onready var food_stockpile: FoodStockpile = $FoodStockpile
@onready var route: RouteRunner = $RouteRunner
@onready var cap: InventoryCapacity = $InventoryCapacity
@onready var prod: ProductionBatch = $ProductionBatch
@onready var profit: ProductionProfitability = $ProductionProfitability
@onready var food_reserve: FoodReserve = $FoodReserve

# Margin compression component (loaded dynamically to avoid class resolution issues)
var margin_compression = null

# Inventory throttle component (loaded dynamically)
var inventory_throttle = null

# Reference to market
var market: Market = null

# Event logging
var event_bus: EventBus = null
var current_tick: int = 0

# Pending target for after waiting
var pending_target: Node2D = null

# Error throttling to prevent spam
var last_phase_error_tick: int = -1
var phase_error_cooldown: int = 100  # Only log phase errors once per 100 ticks

# Production tracking for diagnostics
var last_diagnostic_day: int = -1
var bread_produced_today: int = 0


func get_display_name() -> String:
	return "Baker"


func _bread_for_food() -> int:
	return inv.get_qty("bread")


func set_tick(t: int) -> void:
	current_tick = t
	if route:
		route.set_tick(t)
	if profit:
		profit.set_tick(t)
	if margin_compression:
		margin_compression.set_tick(t)
	if inventory_throttle:
		inventory_throttle.set_tick(t)
		# Calculate throttle factor based on market inventory pressure
		inventory_throttle.calculate_throttle(BREAD_RECIPE)
	if food_reserve:
		food_reserve.set_tick(t)
		# Check survival mode - this takes priority over production
		food_reserve.check_survival_mode()
		# Update survival override (allows production even when profit-paused if market has no food)
		food_reserve.update_survival_override()
	
	# Daily diagnostic: check if baker produced 0 bread while having wheat and being at bakery
	var current_day: int = t / 100  # Assuming 100 ticks per day
	if current_day != last_diagnostic_day:
		if last_diagnostic_day >= 0 and bread_produced_today == 0:
			# Check if conditions allow production
			var has_wheat: bool = inv.get_qty("wheat") > 0
			var at_bakery: bool = route and route.target == null and position.distance_to(bakery_location.global_position) <= 10.0
			if has_wheat and at_bakery and event_bus:
				event_bus.log("Tick %d: [DIAGNOSTIC] Baker produced 0 bread on day %d (wheat=%d, at_bakery=%s, profit=%s, override=%s)" % [
					t, last_diagnostic_day, inv.get_qty("wheat"), at_bakery, 
					(profit.is_production_profitable(BREAD_RECIPE) if profit else "N/A"),
					(food_reserve.survival_override_active if food_reserve else false)
				])
		last_diagnostic_day = current_day
		bread_produced_today = 0
	
	if t == 0 and event_bus:
		event_bus.log("Tick 0: Baker starting food=%d" % inv.get_qty("bread"))


func _ready() -> void:
	# Initialize wallet and inventory
	wallet.money = 500.0
	inv.items = {"wheat": 0, "flour": 0, "bread": 2}
	
	# Load margin compression component dynamically
	if has_node("MarginCompression"):
		margin_compression = get_node("MarginCompression")
	
	# Load inventory throttle component dynamically
	if has_node("InventoryThrottle"):
		inventory_throttle = get_node("InventoryThrottle")
	
	# Bind capacity to inventory
	cap.bind(inv)
	inv.bind_capacity(cap)
	
	# Bind production batch
	prod.bind(inv, cap)
	
	# Bind profitability checker (margin set by config, default 10%)
	# No hard-coded values - component uses its default or config-loaded value
	
	# Bind food stockpile
	food_stockpile.bind(inv)
	
	# Bind RouteRunner
	route.bind(self)
	route.speed = SPEED
	route.arrival_distance = ARRIVAL_DISTANCE
	route.arrived.connect(_on_arrived)
	route.wait_finished.connect(_on_wait_finished)
	route.travel_timeout.connect(_on_travel_timeout)


func set_locations(bakery: Node2D, market_node: Node2D) -> void:
	bakery_location = bakery
	market_location = market_node
	# Bind logging to RouteRunner
	if event_bus and route:
		route.bind_logging(event_bus, get_display_name())
	# Bind profitability to market
	if profit and market and event_bus:
		profit.bind(market, event_bus, get_display_name())
	# Bind margin compression (early throttle mechanic)
	if margin_compression and market and event_bus:
		margin_compression.bind(market, event_bus, get_display_name())
	# Bind inventory throttle (smooth production scaling)
	if inventory_throttle and market and event_bus:
		inventory_throttle.bind(market, event_bus, get_display_name())
	# Bind food reserve (survival mechanic)
	if food_reserve and market:
		food_reserve.bind(inv, hunger, market, wallet, event_bus, get_display_name())
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


func _on_travel_timeout(t: Node2D) -> void:
	# Handle travel timeout - force recovery to RESTOCK phase
	if event_bus:
		event_bus.log("Tick %d: Baker travel timeout recovery - forcing RESTOCK phase" % current_tick)
	production_state = ProductionState.IDLE
	phase = Phase.RESTOCK
	pending_target = market_location
	route.wait(WAIT_TIME)


func perform_market_transactions() -> void:
	# PRIORITY 1: Survival mode - buy food if reserve is critical AND market has food
	if food_reserve and food_reserve.is_survival_mode:
		var bought: int = food_reserve.attempt_survival_purchase()
		# If we successfully bought food and reserve is restored, survival mode will be off next tick
		if bought > 0 and not food_reserve.is_survival_mode:
			# Reserve restored, continue with normal logic
			pass
		elif bought > 0 and food_reserve.is_survival_mode:
			# Bought some but still need more - stay at market to try again
			pending_target = market_location
			route.wait(WAIT_TIME)
			return
		# If bought == 0, market has no food - fall through to allow restocking/production
		# This is CRITICAL: food producers must be able to bootstrap supply
	
	# PRIORITY 2: Execute action based on current phase
	match phase:
		Phase.RESTOCK:
			# Buy wheat for production
			var current_wheat: int = inv.get_qty("wheat")
			if current_wheat < WHEAT_LOW_WATERMARK:
				var wheat_needed: int = WHEAT_TARGET_STOCK - current_wheat
				market.sell_wheat_to_baker(self, wheat_needed)
			# Transition to production phase
			phase = Phase.PRODUCE
			pending_target = bakery_location
			route.wait(WAIT_TIME)
		
		Phase.SELL:
			# Check margin compression FIRST - throttle selling if margins too thin
			if margin_compression and margin_compression.should_throttle_selling(BREAD_RECIPE):
				# Margins compressed - don't sell, go back to produce more inventory
				# This allows inventory to build, signaling price system to adjust
				phase = Phase.PRODUCE
				pending_target = bakery_location
				route.wait(WAIT_TIME)
				return
			
			# Check if market is saturated before attempting to sell
			if market.is_saturated("bread"):
				if event_bus:
					var info = market.get_saturation_info("bread")
					event_bus.log("Tick %d: Baker skipping sell - market bread storage saturated (%d/%d)" % [current_tick, info["current"], info["capacity"]])
				# Stay in SELL phase and wait - don't produce more until market has space
				pending_target = market_location
				route.wait(WAIT_TIME)
				return
			
			# Sell bread in large batch, keeping minimum for eating
			var current_bread: int = inv.get_qty("bread")
			var sellable: int = max(0, current_bread - BREAD_PRODUCTION_MIN)
			# Apply inventory throttle to selling
			if inventory_throttle:
				sellable = inventory_throttle.apply_to_sell(sellable)
			if sellable > 0:
				# Calculate min acceptable price using production cost + margin
				var min_price: float = 0.0
				if profit:
					min_price = profit.get_min_acceptable_price(BREAD_RECIPE)
				market.buy_bread_from_agent(self, sellable, min_price)
			
			# After selling, decide next action
			var current_wheat: int = inv.get_qty("wheat")
			if current_wheat < WHEAT_LOW_WATERMARK:
				# Need to restock wheat - stay at market
				phase = Phase.RESTOCK
				pending_target = market_location
				route.wait(WAIT_TIME)
			else:
				# Have enough wheat - go back to bakery to produce
				phase = Phase.PRODUCE
				pending_target = bakery_location
				route.wait(WAIT_TIME)
		
		Phase.PRODUCE:
			# Should not be at market during production phase - log throttled error
			if event_bus and (current_tick - last_phase_error_tick) >= phase_error_cooldown:
				event_bus.log("ERROR Tick %d: Baker at market during PRODUCE phase (state machine leak)" % current_tick)
				last_phase_error_tick = current_tick
			# Force transition to RESTOCK to recover
			phase = Phase.RESTOCK
			pending_target = market_location
			route.wait(WAIT_TIME)


func handle_bakery_arrival() -> void:
	# Arriving at bakery - set production phase
	if not hunger.is_starving:
		phase = Phase.PRODUCE
		start_production()
	else:
		# If starving, go to market to restock
		phase = Phase.RESTOCK
		pending_target = market_location
		route.wait(WAIT_TIME)


func start_production() -> void:
	# Location guard - must be at bakery to produce
	if global_position.distance_to(bakery_location.global_position) > ARRIVAL_DISTANCE * 2:
		if event_bus:
			event_bus.log("Tick %d: Baker attempting production while not at bakery" % current_tick)
		return
	
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
	# If nothing to process, go to market to restock
	else:
		production_state = ProductionState.IDLE
		phase = Phase.RESTOCK
		pending_target = market_location
		route.wait(WAIT_TIME)


func process_grinding(delta: float) -> void:
	process_timer -= delta
	if process_timer <= 0.0:
		# DECISION ORDER:
		# 1. Survival override (allow subsistence production)
		# 2. Margin compression (throttle before prices crash)
		# 3. Profit check (final hard stop)
		
		var can_produce: bool = true
		
		# Check margin compression FIRST (leading indicator)
		if margin_compression and margin_compression.should_throttle_production(BREAD_RECIPE):
			# Check survival override: can still produce if market has no food and we need food
			if food_reserve and food_reserve.survival_override_active:
				var current_food: int = inv.get_qty("bread")
				can_produce = current_food < food_reserve.min_reserve_units
			else:
				can_produce = false
		# Check profit (final hard stop if margin compression didn't trigger)
		elif profit and not profit.is_production_profitable(BREAD_RECIPE):
			# Check survival override: can produce if market has no food and we need food
			if food_reserve and food_reserve.survival_override_active:
				var current_food: int = inv.get_qty("bread")
				can_produce = current_food < food_reserve.min_reserve_units
			else:
				can_produce = false
		
		if not can_produce:
			# Margins too thin or unprofitable - pause production
			production_state = ProductionState.IDLE
			phase = Phase.SELL if inv.get_qty("bread") >= BREAD_PRODUCTION_MIN else Phase.RESTOCK
			pending_target = market_location
			route.wait(WAIT_TIME)
			return
		
		# Compute safe batch size with inventory throttling
		var target_batch: int = GRIND_BATCH_SIZE
		# Apply inventory throttle (unless survival override active)
		if inventory_throttle and not (food_reserve and food_reserve.survival_override_active):
			target_batch = inventory_throttle.apply_to_batch(target_batch)
		var units: int = prod.compute_batch(target_batch, "wheat", "flour", FLOUR_PER_WHEAT)
		
		if units == 0:
			# No wheat or no space
			if inv.get_qty("wheat") == 0:
				# Switch to baking if we have flour, else go to market
				if inv.get_qty("flour") > 0:
					production_state = ProductionState.BAKING
					process_timer = BAKING_TIME
				else:
					production_state = ProductionState.IDLE
					phase = Phase.RESTOCK
					pending_target = market_location
					route.wait(WAIT_TIME)
			else:
				# No space - go to market to sell bread
				production_state = ProductionState.IDLE
				phase = Phase.SELL
				pending_target = market_location
				route.wait(WAIT_TIME)
		else:
			# Convert wheat to flour
			var ok: bool = prod.convert("wheat", "flour", units, FLOUR_PER_WHEAT)
			if not ok:
				if event_bus:
					event_bus.log("ERROR Tick %d: Baker grinding failed due to capacity/rollback safety" % current_tick)
				production_state = ProductionState.IDLE
				phase = Phase.RESTOCK
				pending_target = market_location
				route.wait(WAIT_TIME)
			else:
				var flour_produced: int = units * FLOUR_PER_WHEAT
				if event_bus:
					event_bus.log("Tick %d: Baker ground %d wheat into %d flour" % [current_tick, units, flour_produced])
				
				# Decide next action: continue production or go to market
				var current_bread: int = inv.get_qty("bread")
				var current_flour: int = inv.get_qty("flour")
				var current_wheat: int = inv.get_qty("wheat")
				
				# Go to market to sell if bread threshold reached
				if current_bread >= BREAD_SELL_THRESHOLD:
					# Check if market can accept bread before going to sell
					if market.is_saturated("bread"):
						if event_bus:
							var info = market.get_saturation_info("bread")
							event_bus.log("Tick %d: Baker pausing production - market bread saturated (%d/%d)" % [current_tick, info["current"], info["capacity"]])
						production_state = ProductionState.IDLE
						phase = Phase.SELL
						pending_target = market_location
						route.wait(WAIT_TIME)
					else:
						production_state = ProductionState.IDLE
						phase = Phase.SELL
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
					# Blocked by capacity or out of inputs - go to market
					production_state = ProductionState.IDLE
					if current_bread >= BREAD_PRODUCTION_MIN:
						phase = Phase.SELL
					else:
						phase = Phase.RESTOCK
					pending_target = market_location
					route.wait(WAIT_TIME)

func process_baking(delta: float) -> void:
	process_timer -= delta
	if process_timer <= 0.0:
		# DECISION ORDER:
		# 1. Survival override (allow subsistence production)
		# 2. Margin compression (throttle before prices crash)
		# 3. Profit check (final hard stop)
		
		var can_produce: bool = true
		
		# Check margin compression FIRST (leading indicator)
		if margin_compression and margin_compression.should_throttle_production(BREAD_RECIPE):
			# Check survival override: can still produce if market has no food and we need food
			if food_reserve and food_reserve.survival_override_active:
				var current_food: int = inv.get_qty("bread")
				can_produce = current_food < food_reserve.min_reserve_units
			else:
				can_produce = false
		# Check profit (final hard stop if margin compression didn't trigger)
		elif profit and not profit.is_production_profitable(BREAD_RECIPE):
			# Check survival override: can produce if market has no food and we need food
			if food_reserve and food_reserve.survival_override_active:
				var current_food: int = inv.get_qty("bread")
				can_produce = current_food < food_reserve.min_reserve_units
			else:
				can_produce = false
		
		if not can_produce:
			# Margins too thin or unprofitable - pause production
			production_state = ProductionState.IDLE
			phase = Phase.SELL if inv.get_qty("bread") >= BREAD_PRODUCTION_MIN else Phase.RESTOCK
			pending_target = market_location
			route.wait(WAIT_TIME)
			return
		
		# Compute safe batch size with inventory throttling
		var target_batch: int = BAKE_BATCH_SIZE
		# Apply inventory throttle (unless survival override active)
		if inventory_throttle and not (food_reserve and food_reserve.survival_override_active):
			target_batch = inventory_throttle.apply_to_batch(target_batch)
		var units: int = prod.compute_batch(target_batch, "flour", "bread", BREAD_PER_FLOUR)
		
		if units == 0:
			# No flour or no space
			if inv.get_qty("flour") == 0:
				# Switch to grinding if we have wheat, else go to market
				if inv.get_qty("wheat") > 0:
					production_state = ProductionState.GRINDING
					process_timer = GRINDING_TIME
				else:
					production_state = ProductionState.IDLE
					phase = Phase.RESTOCK
					pending_target = market_location
					route.wait(WAIT_TIME)
			else:
				# No space - go to market to sell bread
				production_state = ProductionState.IDLE
				phase = Phase.SELL
				pending_target = market_location
				route.wait(WAIT_TIME)
		else:
			# Convert flour to bread
			var ok: bool = prod.convert("flour", "bread", units, BREAD_PER_FLOUR)
			if not ok:
				if event_bus:
					event_bus.log("ERROR Tick %d: Baker baking failed due to capacity/rollback safety" % current_tick)
				production_state = ProductionState.IDLE
				phase = Phase.RESTOCK
				pending_target = market_location
				route.wait(WAIT_TIME)
			else:
				var bread_produced: int = units * BREAD_PER_FLOUR
				bread_produced_today += bread_produced  # Track production for diagnostics
				if event_bus:
					event_bus.log("Tick %d: Baker baked %d flour into %d bread" % [current_tick, units, bread_produced])
				
				# Decide next action: continue production or go to market
				var current_bread: int = inv.get_qty("bread")
				var current_flour: int = inv.get_qty("flour")
				var current_wheat: int = inv.get_qty("wheat")
				
				# Go to market to sell if bread threshold reached
				if current_bread >= BREAD_SELL_THRESHOLD:
					# Check if market can accept bread before going to sell
					if market.is_saturated("bread"):
						if event_bus:
							var info = market.get_saturation_info("bread")
							event_bus.log("Tick %d: Baker pausing production - market bread saturated (%d/%d)" % [current_tick, info["current"], info["capacity"]])
						production_state = ProductionState.IDLE
						phase = Phase.SELL
						pending_target = market_location
						route.wait(WAIT_TIME)
					else:
						production_state = ProductionState.IDLE
						phase = Phase.SELL
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
					# Blocked by capacity or out of inputs - go to market
					production_state = ProductionState.IDLE
					if current_bread >= BREAD_PRODUCTION_MIN:
						phase = Phase.SELL
					else:
						phase = Phase.RESTOCK
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
