extends CharacterBody2D
class_name Farmer

## Farmer agent - plants seeds, harvests wheat, sells at market, buys bread.
## Movement is handled by RouteRunner component.

# Route nodes
var house_node: Node2D = null
var market_node: Node2D = null
var route_targets: Array[Node2D] = []
var route_index: int = 0

# Dynamic field references
var fields: Array = []  # Array of FieldPlot
var field_nodes: Array = []  # Array of Node2D (field scene nodes)

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

# Capital constraints (B) - maintenance costs and production capacity
var field_work_capacity_per_day: int = 3       # Max fields worked per day
var fields_worked_today: int = 0               # Reset each day
var maintenance_cost_per_day: float = 0.2      # Coin/day upkeep deducted at day start
var consecutive_days_negative_cashflow: int = 0 # Tracked by on_day_changed
var day_money_start: float = -1.0              # Sentinel: -1 = not yet initialized

# [BUGFIX] Travel and idle watchdog state
var travel_ticks: int = 0
const MAX_TRAVEL_TICKS: int = 300
var hysteresis_cooldown_ticks: int = 0
var idle_ticks: int = 0
const MAX_IDLE_TICKS: int = 10

# Construction guard: suppresses _rebuild_route "no fields" warning until the farmer
# has received at least one field via add_field().
var _initialized: bool = false
# Per-day throttle: prevents spamming the production-skip warning more than once per day.
var warned_no_field_today: bool = false


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
	
	# [BUGFIX] Defensive state guards
	if hysteresis_cooldown_ticks > 0:
		hysteresis_cooldown_ticks -= 1
	_check_travel_timeout()
	_check_idle_guard()


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
	route.travel_timeout.connect(_on_travel_timeout)


func set_route_nodes(house: Node2D, market_pos: Node2D) -> void:
	house_node = house
	market_node = market_pos
	# Bind profitability to market
	if profit and self.market and event_bus:
		profit.bind(self.market, event_bus, get_display_name())
	# Bind inventory throttle (smooth production scaling based on wheat inventory)
	if inventory_throttle and self.market and event_bus:
		inventory_throttle.bind(self.market, event_bus, get_display_name())
	_rebuild_route()


func _rebuild_route() -> void:
	# Only warn once the farmer has been fully initialised (i.e. has had at least one
	# field assigned via add_field).  This suppresses the false-positive that fires
	# during spawn_farmer_at → set_route_nodes before the initial field is attached.
	if fields.size() == 0 and _initialized:
		print("[ERROR] Farmer %s lost all fields — economic dead zone" % get_display_name())
		if event_bus:
			event_bus.log("[ERROR] Farmer %s lost all fields" % get_display_name())
	
	route_targets.clear()
	if house_node:
		route_targets.append(house_node)
	for fn in field_nodes:
		route_targets.append(fn)
	if market_node:
		route_targets.append(market_node)
	route_index = 0
	if route_targets.size() > 0:
		route.set_target(route_targets[route_index])


func set_fields(field_plots: Array, nodes: Array) -> void:
	fields = field_plots.duplicate()
	field_nodes = nodes.duplicate()
	_rebuild_route()


func add_field(field_node: Node2D, field_plot: FieldPlot) -> void:
	if field_node not in field_nodes:
		field_nodes.append(field_node)
		fields.append(field_plot)
		_initialized = true  # Farmer now has at least one field; enable full warnings
		_rebuild_route()
		if event_bus:
			event_bus.log("%s: New field assigned (%s, total fields: %d)" % [get_display_name(), field_node.name, fields.size()])


func remove_field(field_node: Node2D) -> void:
	var idx = field_nodes.find(field_node)
	if idx != -1:
		field_nodes.remove_at(idx)
		fields.remove_at(idx)
		_rebuild_route()
		if event_bus:
			event_bus.log("%s: Field removed (%s, total fields: %d)" % [get_display_name(), field_node.name, fields.size()])


func get_field_count() -> int:
	return fields.size()


func _physics_process(_delta: float) -> void:
	# Stop movement if starving (RouteRunner still processes but we override here)
	if hunger.is_starving:
		route.stop()


func _on_arrived(t: Node2D) -> void:
	# [BUGFIX] Reset travel watchdog on arrival
	travel_ticks = 0
	idle_ticks = 0
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
	elif t == market_node:
		handle_market_arrival()
	else:
		# Check if it's one of our assigned fields
		var idx = field_nodes.find(t)
		if idx != -1:
			handle_field_arrival(fields[idx], t.name)


func handle_house_arrival() -> void:
	# Home arrival - no action needed (eating handled by HungerNeed)
	pass


func handle_field_arrival(field: FieldPlot, field_name: String) -> void:
	# [BUGFIX] Defensive guard — throttled to once per day to prevent log spam.
	if fields.size() == 0:
		if not warned_no_field_today:
			print("[ERROR] Farmer_%s has no fields; skipping production" % name)
			warned_no_field_today = true
		return
	
	# Capital constraint: respect daily field-work capacity
	if fields_worked_today >= field_work_capacity_per_day:
		if event_bus:
			event_bus.log("Tick %d: Farmer [CAP] skipping %s - daily field capacity reached (%d/%d)" % [
				current_tick, field_name, fields_worked_today, field_work_capacity_per_day])
		return
	fields_worked_today += 1
	# Check if field is mature and harvest
	if field.is_mature():
		var harvest_result = field.harvest()
		inv.add("wheat", harvest_result.wheat)
		inv.add("seeds", harvest_result.seeds)
		if event_bus:
			event_bus.log("Tick %d: Farmer harvested %s (+%d wheat, +%d seeds)" % [current_tick, field_name, harvest_result.wheat, harvest_result.seeds])
	# Otherwise try to plant if field is empty and we have seeds
	elif field.state == FieldPlot.State.EMPTY and inv.get_qty("seeds") >= 5:
		# HYSTERESIS PROCUREMENT COUPLING: Don't plant if wheat production is paused
		if not market.can_producer_produce("wheat"):
			if event_bus:
				event_bus.log("Tick %d: Farmer SKIPPED planting %s (wheat production paused by hysteresis)" % [current_tick, field_name])
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
				event_bus.log("Tick %d: Farmer planted %s (-5 seeds)" % [current_tick, field_name])
		elif inventory_throttle and not should_plant:
			if event_bus:
				event_bus.log("Tick %d: Farmer SKIPPED planting %s (throttle %.0f%%)" % [current_tick, field_name, inventory_throttle.production_throttle * 100.0])


func handle_market_arrival() -> void:
	# PRIORITY 1: Survival mode - buy food if reserve is critical AND market has food
	if food_reserve and food_reserve.is_survival_mode:
		var _bought: int = food_reserve.attempt_survival_purchase()
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


## Called once per game day by main._on_calendar_day_changed.
func on_day_changed(_day: int) -> void:
	# Evaluate yesterday's cashflow BEFORE paying today's maintenance
	var cur_money: float = wallet.money if wallet else 0.0
	if day_money_start >= 0.0:  # Skip the very first call (sentinel -1.0)
		if cur_money <= day_money_start:
			consecutive_days_negative_cashflow += 1
		else:
			consecutive_days_negative_cashflow = 0
	
	# Pay maintenance cost for today
	if wallet and maintenance_cost_per_day > 0.0:
		wallet.debit(maintenance_cost_per_day)
	
	# Snapshot money after maintenance for next day's comparison
	day_money_start = wallet.money if wallet else 0.0
	
	# Reset daily field-work counter
	fields_worked_today = 0
	# Reset per-day warning throttle
	warned_no_field_today = false


func _on_travel_timeout(_t: Node2D) -> void:
	travel_ticks = 0
	print("[BUGFIX] Farmer: travel timeout, restarting route")
	if event_bus:
		event_bus.log("[TRAVEL] Tick %d: Farmer travel timeout recovery - restarting route" % current_tick)
	pending_target = route_targets[route_index] if route_targets.size() > 0 else null
	if pending_target:
		route.wait(WAIT_TIME)


func _check_travel_timeout() -> void:
	if route == null:
		return
	if route.is_traveling:
		travel_ticks += 1
		if travel_ticks > MAX_TRAVEL_TICKS:
			var tname: String = route.target.name if route.target else "null"
			print("[BUGFIX] Farmer: travel timeout reset after %d ticks (target=%s)" % [travel_ticks, tname])
			if event_bus:
				event_bus.log("[TRAVEL] Tick %d: Farmer travel timeout reset (travel_ticks=%d, target=%s)" % [current_tick, travel_ticks, tname])
			route.stop()
			travel_ticks = 0
			pending_target = route_targets[route_index] if route_targets.size() > 0 else null
			if pending_target:
				route.wait(WAIT_TIME)
	else:
		travel_ticks = 0


func _check_idle_guard() -> void:
	if hunger == null or hunger.is_starving:
		idle_ticks = 0
		return
	if hysteresis_cooldown_ticks > 0:
		idle_ticks = 0
		return
	if route == null:
		return
	if route.is_traveling or route.is_waiting or route.target != null or pending_target != null:
		idle_ticks = 0
		return
	idle_ticks += 1
	if idle_ticks < MAX_IDLE_TICKS:
		return
	idle_ticks = 0
	print("[BUGFIX] Farmer: idle guard triggered, restarting route")
	if event_bus:
		event_bus.log("[STATE] Tick %d: Farmer idle guard triggered, restarting route" % current_tick)
	if route_targets.size() > 0:
		route.set_target(route_targets[route_index])


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
	elif route.target in field_nodes:
		var field_name = route.target.name
		if route.is_waiting:
			return "Waiting at %s" % field_name
		return "Walking to %s" % field_name
	
	return route.get_status_text()
