extends CharacterBody2D
class_name Farmer

## Farmer agent - plants seeds, harvests wheat, sells at market, buys bread.
## Movement is handled by RouteRunner component.

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

# Production recipe for profitability checking (seed→wheat chain)
# 5 seeds per field planting → 10 wheat per harvest (1:2 ratio)
const WHEAT_RECIPE: Dictionary = {
	"output_good": "wheat",
	"output_quantity": 10,
	"inputs": {"seeds": 5}
}

# Components
@onready var wallet: Wallet = $Wallet
@onready var inv: Inventory = $Inventory
@onready var hunger: HungerNeed = $HungerNeed
@onready var food_stockpile: FoodStockpile = $FoodStockpile
@onready var route: RouteRunner = $RouteRunner
@onready var cap: InventoryCapacity = $InventoryCapacity
@onready var food_reserve: FoodReserve = $FoodReserve

# Producer mechanics (shared with baker)
var profit: ProductionProfitability = null
var inventory_throttle: InventoryThrottle = null

# Reference to market
var market: Market = null

# Event logging
var event_bus: EventBus = null
var current_tick: int = 0

# Pending target for after waiting
var pending_target: Node2D = null


func get_display_name() -> String:
	return "Farmer"


func set_tick(t: int) -> void:
	current_tick = t
	if profit:
		profit.set_tick(t)
	if inventory_throttle:
		inventory_throttle.set_tick(t)
		# Calculate throttle factor based on market wheat inventory pressure
		inventory_throttle.calculate_throttle(WHEAT_RECIPE)
	if food_reserve:
		food_reserve.set_tick(t)
		# Check survival mode - takes priority
		food_reserve.check_survival_mode()
		# Update survival override (though farmer doesn't produce food)
		food_reserve.update_survival_override()
	if t == 0 and event_bus:
		event_bus.log("Tick 0: Farmer starting food=%d" % inv.get_qty("bread"))


func _ready() -> void:
	# Initialize wallet and inventory
	wallet.money = 1000.0
	inv.items = {"seeds": 50, "wheat": 0, "bread": 2}
	
	# Load producer mechanics components dynamically
	if has_node("ProductionProfitability"):
		profit = get_node("ProductionProfitability")
	if has_node("InventoryThrottle"):
		inventory_throttle = get_node("InventoryThrottle")
	
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


func set_route_nodes(house: Node2D, field1: Node2D, field2: Node2D, market_pos: Node2D) -> void:
	house_node = house
	field1_node = field1
	field2_node = field2
	market_node = market_pos
	route_targets = [house_node, field1_node, field2_node, market_node]
	route_index = 0
	# Bind profitability to market
	if profit and self.market and event_bus:
		profit.bind(self.market, event_bus, get_display_name())
	# Bind inventory throttle (smooth production scaling based on wheat inventory)
	if inventory_throttle and self.market and event_bus:
		inventory_throttle.bind(self.market, event_bus, get_display_name())
	route.set_target(route_targets[route_index])


func set_fields(field1: FieldPlot, field2: FieldPlot) -> void:
	field1_plot = field1
	field2_plot = field2


func _physics_process(_delta: float) -> void:
	# Stop movement if starving (RouteRunner still processes but we override here)
	if hunger.is_starving:
		route.stop()


func _on_arrived(t: Node2D) -> void:
	# Handle arrival actions
	handle_arrival(t)
	
	# Set pending target for after wait completes
	pending_target = get_next_target()
	route.wait(WAIT_TIME)


func _on_wait_finished() -> void:
	if pending_target != null:
		route.set_target(pending_target)
		pending_target = null


func get_next_target() -> Node2D:
	route_index = (route_index + 1) % route_targets.size()
	return route_targets[route_index]


func handle_arrival(t: Node2D) -> void:
	if t == house_node:
		handle_house_arrival()
	elif t == field1_node:
		handle_field_arrival(field1_plot, "Field1")
	elif t == field2_node:
		handle_field_arrival(field2_plot, "Field2")
	elif t == market_node:
		handle_market_arrival()


func handle_house_arrival() -> void:
	# Home arrival - no action needed (eating handled by HungerNeed)
	pass


func handle_field_arrival(field: FieldPlot, field_name: String) -> void:
	# Check if field is mature and harvest
	if field.is_mature():
		var harvest_result = field.harvest()
		inv.add("wheat", harvest_result.wheat)
		inv.add("seeds", harvest_result.seeds)
		if event_bus:
			event_bus.log("Tick %d: Farmer harvested %s (+%d wheat, +%d seeds)" % [current_tick, field_name, harvest_result.wheat, harvest_result.seeds])
	# Otherwise try to plant if field is empty and we have seeds
	elif field.state == FieldPlot.State.EMPTY and inv.get_qty("seeds") >= 5:
		# Apply production throttle to planting (procurement coupling)
		var should_plant: bool = true
		if inventory_throttle:
			var throttle_factor: float = inventory_throttle.production_throttle
			# Skip planting probabilistically based on throttle
			# throttle=1.0 → always plant, throttle=0.5 → plant 50% of the time
			should_plant = randf() < throttle_factor
		
		if should_plant and field.plant():
			inv.remove("seeds", 5)
			if event_bus:
				event_bus.log("Tick %d: Farmer planted %s (-5 seeds)" % [current_tick, field_name])
		elif inventory_throttle and not should_plant:
			if event_bus:
				event_bus.log("Tick %d: Farmer SKIPPED planting %s (throttle %.0f%%)" % [current_tick, field_name, inventory_throttle.production_throttle * 100.0])


func handle_market_arrival() -> void:
	# PRIORITY 1: Survival mode - buy food if reserve is critical AND market has food
	if food_reserve and food_reserve.is_survival_mode:
		var bought: int = food_reserve.attempt_survival_purchase()
		# If bought == 0, market has no food - continue with normal logic
		# Farmer cannot produce food, so will rely on baker producing bread
	
	# PRIORITY 2: Sell all wheat to market
	if inv.get_qty("wheat") > 0:
		# Calculate min acceptable price using production cost + margin (shared logic)
		var min_price: float = 0.0
		if profit:
			min_price = profit.get_min_acceptable_price(WHEAT_RECIPE)
		else:
			# Fallback: 150% of seed cost (rough profit margin)
			min_price = market.SEED_PRICE * 1.5
		market.buy_wheat_from_farmer(self, min_price)
	
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
	
	# Use RouteRunner status with context
	if route.target == house_node:
		if route.is_waiting:
			return "Waiting at House"
		return "Walking to House"
	elif route.target == field1_node:
		if route.is_waiting:
			return "Waiting at Field1"
		return "Walking to Field1"
	elif route.target == field2_node:
		if route.is_waiting:
			return "Waiting at Field2"
		return "Walking to Field2"
	elif route.target == market_node:
		if route.is_waiting:
			return "At Market (trading)"
		return "Walking to Market"
	
	return route.get_status_text()
