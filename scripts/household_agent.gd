extends CharacterBody2D
class_name HouseholdAgent

## Household agent - buys bread at market, consumes at home.
## Movement is handled by RouteRunner component.

signal household_died(household: HouseholdAgent)
signal pop_clicked(pop: Node)

var _health_bar_fg: ColorRect = null


func _create_health_bar() -> void:
	var bg := ColorRect.new()
	bg.name = "HealthBarBG"
	bg.position = Vector2(-10.0, -24.0)
	bg.size     = Vector2(20.0, 4.0)
	bg.color    = Color(0.18, 0.05, 0.05, 0.85)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_health_bar_fg = ColorRect.new()
	_health_bar_fg.name = "HealthBar"
	_health_bar_fg.position = Vector2(-10.0, -24.0)
	_health_bar_fg.size     = Vector2(20.0, 4.0)
	_health_bar_fg.color    = Color(0.85, 0.12, 0.12, 1.0)
	_health_bar_fg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_health_bar_fg)


func _process(_delta: float) -> void:
	if _health_bar_fg == null or hunger == null or hunger.hunger_max_days <= 0:
		return
	var ratio: float = clamp(float(hunger.hunger_days) / float(hunger.hunger_max_days), 0.0, 1.0)
	_health_bar_fg.size.x = 20.0 * ratio
	_health_bar_fg.color = Color(0.85, 0.12, 0.12, 1.0) if ratio > 0.25 else Color(0.50, 0.06, 0.06, 1.0)

enum Phase { AT_MARKET, AT_HOME }

var phase: Phase = Phase.AT_HOME  # Start at home, not market

# Locations
var home_location: Node2D = null
var market_location: Node2D = null

# References
var market: Market = null
var event_bus: EventBus = null
var current_tick: int = 0

# Travel Config (tunable survival triggers)
@export var reserve_target_bread: int = 3  # Target bread reserve (base level)
@export var reserve_min_bread: int = 0  # Emergency threshold
@export var hunger_buy_threshold_ratio: float = 0.4  # Go to market when hunger <= 40%
@export var buy_batch_multiplier: float = 1.0  # Buy multiplier (1.0 = exact deficit)
@export var market_trip_cooldown_ticks: int = 0  # Cooldown between trips (0 = none)

# Demand Elasticity Config (price sensitivity)
@export var bread_price_soft_cap: float = 4.0  # Price above which reserve target begins reducing
@export var bread_price_hard_cap: float = 7.0  # Price above which non-emergency purchases stop
@export var emergency_hunger_threshold: float = 0.2  # Hunger ratio below which emergency buying triggers (20%)
@export var reserve_target_base: int = 3  # Base reserve target at normal prices
@export var reserve_target_min: int = 1  # Minimum reserve target at high prices

# Effective reserve target (dynamically adjusted based on price)
var effective_reserve_target: int = 3
var last_logged_price_adjustment_tick: int = -999999  # Prevent log spam

# Travel State
var last_market_trip_tick: int = -999999  # Last tick household went to market
var logged_staying_home: bool = false  # Prevent log spam when staying home

# Labor-market tracking (read/written by LaborMarket and main.gd)
var switch_cooldown_days: int = 0          # Days remaining before this household can switch roles
var training_days_remaining: int = 0       # Days until role conversion completes
var days_in_survival_mode: int = 0         # Consecutive days in survival mode (updated by LaborMarket)
var consecutive_failed_food_days: int = 0  # Days in a row with zero bread purchased at market

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

# [BUGFIX] Travel and idle watchdog state
var travel_ticks: int = 0
const MAX_TRAVEL_TICKS: int = 300
var idle_ticks: int = 0
const MAX_IDLE_TICKS: int = 10


func _ready() -> void:
	add_to_group("households")
	_create_health_bar()
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
		route.travel_timeout.connect(_on_travel_timeout)
	
	# Connect starvation death signal
	if hunger:
		hunger.starved.connect(_on_starved)


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


func _calculate_effective_reserve_target() -> int:
	"""Calculate effective reserve target based on current bread price (demand elasticity).
	Returns adjusted target: higher prices = lower target, preserving price sensitivity."""
	if market == null:
		return reserve_target_base
	
	var current_price: float = market.bread_price
	
	# Below soft cap: full reserve target
	if current_price <= bread_price_soft_cap:
		return reserve_target_base
	
	# Above hard cap: minimum reserve target (emergency only)
	if current_price >= bread_price_hard_cap:
		return reserve_target_min
	
	# Between soft and hard cap: linear interpolation
	var price_range: float = bread_price_hard_cap - bread_price_soft_cap
	var price_excess: float = current_price - bread_price_soft_cap
	var reduction_ratio: float = price_excess / price_range
	var target_range: float = float(reserve_target_base - reserve_target_min)
	var adjusted_target: int = reserve_target_base - int(reduction_ratio * target_range)
	
	# Log occasionally when price causes adjustment (not every tick)
	if adjusted_target != reserve_target_base and current_tick - last_logged_price_adjustment_tick > 100:
		if event_bus:
			event_bus.log("%s high price $%.2f: reserve_target %d→%d" % [name, current_price, reserve_target_base, adjusted_target])
		last_logged_price_adjustment_tick = current_tick
	
	return clamp(adjusted_target, reserve_target_min, reserve_target_base)


func _on_ate_meal(qty: int) -> void:
	bread_consumed += qty


func get_display_name() -> String:
	return "Household"


func set_tick(t: int) -> void:
	current_tick = t
	# Recalculate effective reserve target based on current bread price
	effective_reserve_target = _calculate_effective_reserve_target()
	if food_reserve:
		food_reserve.set_tick(t)
		food_reserve.check_survival_mode()
		# Update survival override (though household doesn't produce food)
		food_reserve.update_survival_override()
	
	# [BUGFIX] Defensive state guards
	_check_travel_timeout()
	_check_idle_guard()


func set_locations(home: Node2D, market_node: Node2D) -> void:
	home_location = home
	market_location = market_node
	# Bind food reserve
	if food_reserve and market:
		food_reserve.bind(inv, hunger, market, wallet, event_bus, get_display_name())
	# Start at home, not market
	route.set_target(home_location)


func _on_arrived(t: Node2D) -> void:
	# [BUGFIX] Reset travel watchdog on arrival
	travel_ticks = 0
	idle_ticks = 0
	if t == market_location:
		# Arrived at market - buy bread
		attempt_buy_bread()
		phase = Phase.AT_MARKET
		# Always return home after market visit
		pending_target = home_location
		route.wait(WAIT_TIME)
	elif t == home_location:
		# Arrived at home - consume and decide next action
		consume_bread_at_home()
		phase = Phase.AT_HOME
		# Only go to market if survival triggers fire
		# Fresh evaluation of current state
		var current_bread: int = inv.get_qty("bread") if inv != null else 0
		var hunger_ratio: float = float(hunger.hunger_days) / float(hunger.hunger_max_days) if hunger != null and hunger.hunger_max_days > 0 else 1.0
		
		if needs_food_trip():
			pending_target = market_location
			# Log decision with fresh data
			if event_bus and not logged_staying_home:
				event_bus.log("Tick %d: %s deciding to go to market (bread=%d/%d, hunger=%.1f%%)" % [current_tick, name, current_bread, effective_reserve_target, hunger_ratio * 100])
		else:
			pending_target = home_location  # Stay home
			# Log staying home once per cycle
			if event_bus and not logged_staying_home:
				event_bus.log("Tick %d: %s staying home (bread=%d/%d, hunger=%.1f%%)" % [current_tick, name, current_bread, effective_reserve_target, hunger_ratio * 100])
				logged_staying_home = true
		route.wait(WAIT_TIME)


func _on_wait_finished() -> void:
	if pending_target != null:
		# [BUGFIX] Re-check if we still need to go to market before committing.
		# Conditions may have changed (e.g. bread delivered home) while waiting.
		if pending_target == market_location and not needs_food_trip():
			pending_target = home_location
			if event_bus:
				event_bus.log("Tick %d: %s [BUGFIX] market trip cancelled - need resolved during wait" % [current_tick, name])
		# Only log travel decisions (not staying home loops)
		if pending_target == market_location and pending_target != route.target:
			log_travel_decision("going to market")
		route.set_target(pending_target)
		pending_target = null


func attempt_buy_bread() -> void:
	if market and wallet and inv:
		# Calculate desired purchase quantity with FRESH data
		var current_bread: int = inv.get_qty("bread")
		var hunger_ratio: float = float(hunger.hunger_days) / float(hunger.hunger_max_days) if hunger != null and hunger.hunger_max_days > 0 else 1.0
		
		# Determine effective target: use emergency override if critical hunger or zero reserve
		var target_to_use: int = effective_reserve_target
		if hunger_ratio <= emergency_hunger_threshold or current_bread == 0:
			# Emergency: always try to buy at least 1, ignore price caps
			target_to_use = max(reserve_target_base, 1)
		
		var deficit: int = max(0, target_to_use - current_bread)
		var desired: int = ceili(deficit * buy_batch_multiplier)
		
		if desired == 0:
			# [BUGFIX] This can occur if needs_food_trip() wasn't re-checked before travel.
			# Demoted from ERROR to a soft warning to suppress log spam.
			if event_bus:
				event_bus.log("Tick %d: %s [BUGFIX] at market but no deficit (%d/%d) - returning home" % [current_tick, name, current_bread, effective_reserve_target])
			return
		
		# Attempt to buy desired amount using market's household function
		var qty_bought: int = market.sell_bread_to_household(self, desired)
		
		# Add purchased bread to inventory
		if qty_bought > 0:
			inv.add("bread", qty_bought)
			consecutive_failed_food_days = 0  # Reset streak on any successful purchase
			if event_bus:
				event_bus.log("Tick %d: %s bought %d bread (wanted %d, now have %d)" % [current_tick, name, qty_bought, desired, inv.get_qty("bread")])
		else:
			consecutive_failed_food_days += 1  # Count days market had no bread for us
			if event_bus:
				event_bus.log("Tick %d: %s tried to buy %d bread, bought 0 (market empty, fail_streak=%d)" % [current_tick, name, desired, consecutive_failed_food_days])


func consume_bread_at_home() -> void:
	# Eating handled by HungerNeed auto-eat mechanic
	pass


## Check if household needs to make a food trip to market.
## Returns true if any survival trigger is met.
## Uses FRESH data from inventory - single source of truth.
func needs_food_trip() -> bool:
	if inv == null or hunger == null:
		return false
	
	# Check cooldown
	if current_tick - last_market_trip_tick < market_trip_cooldown_ticks:
		return false
	
	# FRESH inventory read - single source of truth
	var current_bread: int = inv.get_qty("bread")
	var hunger_ratio: float = float(hunger.hunger_days) / float(hunger.hunger_max_days) if hunger.hunger_max_days > 0 else 1.0
	
	# Emergency triggers (hard) - override price sensitivity
	if current_bread == 0:
		return true
	if hunger.hunger_days == 0:
		return true
	if hunger_ratio <= emergency_hunger_threshold:
		return true
	
	# Reserve trigger - uses effective (price-adjusted) target
	if current_bread < effective_reserve_target:
		return true
	
	# Hunger trigger
	if hunger_ratio <= hunger_buy_threshold_ratio:
		return true
	
	return false


## Log travel decision with household state.
func log_travel_decision(action: String) -> void:
	if event_bus and inv and hunger:
		var current_bread: int = inv.get_qty("bread")
		event_bus.log("Tick %d: %s %s (reserve=%d/%d, hunger=%d/%d)" % [
			current_tick, name, action,
			current_bread, effective_reserve_target,
			hunger.hunger_days, hunger.hunger_max_days
		])
		
		if action == "going to market":
			last_market_trip_tick = current_tick


func _on_travel_timeout(_t: Node2D) -> void:
	travel_ticks = 0
	idle_ticks = 0
	print("[BUGFIX] %s: travel timeout recovery - returning home" % get_display_name())
	if event_bus:
		event_bus.log("[TRAVEL] Tick %d: %s travel timeout recovery - returning home" % [current_tick, name])
	phase = Phase.AT_HOME
	pending_target = home_location
	if route:
		route.wait(WAIT_TIME)


func _check_travel_timeout() -> void:
	if route == null:
		return
	if route.is_traveling:
		travel_ticks += 1
		if travel_ticks > MAX_TRAVEL_TICKS:
			var tname: String = route.target.name if route.target else "null"
			print("[BUGFIX] %s: travel timeout reset after %d ticks (target=%s)" % [get_display_name(), travel_ticks, tname])
			if event_bus:
				event_bus.log("[TRAVEL] Tick %d: %s travel timeout reset (travel_ticks=%d, target=%s)" % [current_tick, name, travel_ticks, tname])
			route.stop()
			travel_ticks = 0
			phase = Phase.AT_HOME
			pending_target = home_location
			route.wait(WAIT_TIME)
	else:
		travel_ticks = 0


func _check_idle_guard() -> void:
	if route == null:
		return
	if route.is_traveling or route.is_waiting or route.target != null or pending_target != null:
		idle_ticks = 0
		return
	idle_ticks += 1
	if idle_ticks < MAX_IDLE_TICKS:
		return
	idle_ticks = 0
	print("[BUGFIX] %s: idle guard triggered" % get_display_name())
	if event_bus:
		event_bus.log("[STATE] Tick %d: %s idle guard triggered" % [current_tick, name])
	if needs_food_trip():
		pending_target = market_location
	else:
		pending_target = home_location
	route.wait(WAIT_TIME)


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


## Called once per game day by main._on_calendar_day_changed.
func on_day_changed(_day: int) -> void:
	# Tick down training countdown (used by main.gd for pending conversions)
	if training_days_remaining > 0:
		training_days_remaining -= 1


## Handle starvation death - household has run out of food and hunger reached zero.
## This is LETHAL and NON-NEGOTIABLE - no survival overrides prevent death.
func _on_starved(agent_name_param: String) -> void:
	if event_bus:
		event_bus.log("STARVATION: %s died (hunger depleted, no food available)" % agent_name_param)
	
	# Remove from simulation lists (main.gd will handle this via signal)
	# Signal to main that this household has died
	if has_signal("household_died"):
		emit_signal("household_died", self)
	
	# Remove from scene tree
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			if get_local_mouse_position().length() <= 15.0:
				pop_clicked.emit(self)
				get_viewport().set_input_as_handled()


func get_inspector_data() -> Dictionary:
	var phase_str := "AT_HOME" if phase == Phase.AT_HOME else "AT_MARKET"
	var state_str := phase_str
	if route:
		if route.is_traveling:
			state_str = "traveling→" + (route.target.name if route.target else "?")
		elif pending_target != null:
			state_str = phase_str + " (waiting→" + pending_target.name + ")"
	var d: Dictionary = {
		"name": name,
		"role": "Household",
		"cash": wallet.money if wallet else 0.0,
		"hunger": "%d/%d" % [hunger.hunger_days, hunger.hunger_max_days] if hunger else "?/?",
		"starving": hunger.is_starving if hunger else false,
		"bread": inv.get_qty("bread") if inv else 0,
		"bread_consumed": bread_consumed,
		"effective_reserve": effective_reserve_target,
		"survival": food_reserve.is_survival_mode if food_reserve else false,
		"state": state_str,
		"failed_food_days": consecutive_failed_food_days,
		"switch_cooldown": switch_cooldown_days,
	}
	if training_days_remaining > 0:
		d["training_days"] = training_days_remaining
	return d
