extends CharacterBody2D
class_name Farmer

## Farmer agent - plants seeds, harvests wheat, sells at market, buys bread.
## Movement is handled by RouteRunner component.
## PART 4: Works ONLY assigned fields (dynamic, data-driven)

# Route nodes
var house_node: Node2D = null
var market_node: Node2D = null
var route_targets: Array[Node2D] = []
var route_index: int = 0

# PART 4: Dynamic field assignment (authoritative source)
var assigned_fields: Array = []  # Array of FieldPlot nodes

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
	"""Initialize route nodes. field1 and field2 are legacy params (ignored for dynamic farmers)."""
	house_node = house
	market_node = market_pos
	_rebuild_route()
	route_index = 0
	# Bind profitability to market
	if profit and self.market and event_bus:
		profit.bind(self.market, event_bus, get_display_name())
	# Bind inventory throttle (smooth production scaling based on wheat inventory)
	if inventory_throttle and self.market and event_bus:
		inventory_throttle.bind(self.market, event_bus, get_display_name())
	if route_targets.size() > 0:
		route.set_target(route_targets[route_index])


func _rebuild_route() -> void:
	"""Rebuild route_targets from assigned_fields (called when fields change)."""
	route_targets.clear()
	route_targets.append(house_node)
	# Add each assigned field's node as a target
	for field in assigned_fields:
		if field:
			route_targets.append(field)
	route_targets.append(market_node)
	
	# Reset route and start from beginning
	route_index = 0
	if route_targets.size() > 0 and route:
		route.set_target(route_targets[route_index])


# DEPRECATED: Kept for backwards compatibility with existing baseline farmer
func set_fields(field1: FieldPlot, field2: FieldPlot) -> void:
	"""DEPRECATED: Use assign_field() instead. Kept for baseline farmer compatibility."""
	if field1:
		assign_field(field1)
	if field2:
		assign_field(field2)


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
	"""PART 4: Dynamic field handling - check if t is any assigned field."""
	if t == house_node:
		handle_house_arrival()
	elif t == market_node:
		handle_market_arrival()
	else:
		# Check if this is one of our assigned fields
		for field in assigned_fields:
			if field and t == field:
				handle_field_arrival(field)
				return
		# Unknown target - log warning
		if event_bus:
			event_bus.log("Tick %d: %s arrived at unknown target %s" % [current_tick, name, t.name if t else "null"])


func handle_house_arrival() -> void:
	# Home arrival - no action needed (eating handled by HungerNeed)
	pass


func handle_field_arrival(field: FieldPlot) -> void:
	"""PART 4: Work on assigned field dynamically."""
	if field == null:
		return
	
	var field_name: String = field.name
	
	# Check if field is mature and harvest
	if field.is_mature():
		var harvest_result = field.harvest()
		inv.add("wheat", harvest_result.wheat)
		inv.add("seeds", harvest_result.seeds)
		if event_bus:
			event_bus.log("Tick %d: %s harvested %s (+%d wheat, +%d seeds)" % [current_tick, name, field_name, harvest_result.wheat, harvest_result.seeds])
	# Otherwise try to plant if field is empty and we have seeds
	elif field.state == FieldPlot.State.EMPTY and inv.get_qty("seeds") >= 5:
		# HYSTERESIS PROCUREMENT COUPLING: Don't plant if wheat production is paused
		if not market.can_producer_produce("wheat"):
			if event_bus:
				event_bus.log("Tick %d: %s SKIPPED planting %s (wheat production paused by hysteresis)" % [current_tick, name, field_name])
			return
		
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
				event_bus.log("Tick %d: %s planted %s (-5 seeds)" % [current_tick, name, field_name])
		elif inventory_throttle and not should_plant:
			if event_bus:
				event_bus.log("Tick %d: %s SKIPPED planting %s (throttle %.0f%%)" % [current_tick, name, field_name, inventory_throttle.production_throttle * 100.0])


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
	elif route.target == market_node:
		if route.is_waiting:
			return "At Market (trading)"
		return "Walking to Market"
	else:
		# Check if at a field
		for field in assigned_fields:
			if field and route.target == field:
				if route.is_waiting:
					return "Waiting at %s" % field.name
				return "Walking to %s" % field.name
	
	return route.get_status_text()


# ====================================================================
# PART 4: FIELD ASSIGNMENT API (DYNAMIC PRODUCTION)
# ====================================================================

func assign_field(field: FieldPlot) -> void:
	"""Assign a field to this farmer (add to assigned_fields if not already there)."""
	if field == null:
		return
	
	# Check if already assigned
	if field in assigned_fields:
		return
	
	# Add to assigned fields
	assigned_fields.append(field)
	
	# Rebuild route to include new field
	_rebuild_route()
	
	# Notify
	on_fields_changed()


func unassign_field(field: FieldPlot) -> void:
	"""Unassign a field from this farmer (remove from assigned_fields)."""
	if field == null:
		return
	
	var idx = assigned_fields.find(field)
	if idx != -1:
		assigned_fields.remove_at(idx)
		
		# Rebuild route without this field
		_rebuild_route()
		
		# Notify
		on_fields_changed()


func unassign_all_fields() -> void:
	"""Unassign all fields from this farmer."""
	var count = assigned_fields.size()
	assigned_fields.clear()
	
	# Rebuild route (house -> market only)
	_rebuild_route()
	
	# Notify
	if count > 0:
		on_fields_changed()


func on_fields_changed() -> void:
	"""Called when assigned_fields changes - recalculate cached values."""
	if event_bus:
		event_bus.log("%s now has %d assigned fields" % [name, assigned_fields.size()])
	
	# Could add more sophisticated logic here:
	# - Recalculate total acreage
	# - Adjust seed demand
	# - Update planting schedule
	# For now, just log the change
