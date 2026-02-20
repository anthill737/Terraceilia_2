extends Agent
class_name HouseholdAgent

## Household agent - buys bread at market, consumes at home.
## Movement is handled by RouteRunner component.

signal household_died(household: HouseholdAgent)

enum Phase { AT_MARKET, AT_HOME }

var phase: Phase = Phase.AT_HOME

# Locations
var home_location: Node2D = null
var market_location: Node2D = null

# Travel Config (tunable survival triggers)
@export var reserve_target_bread: int = 3
@export var reserve_min_bread: int = 0
@export var hunger_buy_threshold_ratio: float = 0.4
@export var buy_batch_multiplier: float = 1.0
@export var market_trip_cooldown_ticks: int = 0

# Demand Elasticity Config (price sensitivity)
@export var bread_price_soft_cap: float = 4.0
@export var bread_price_hard_cap: float = 7.0
@export var emergency_hunger_threshold: float = 0.2
@export var reserve_target_base: int = 3
@export var reserve_target_min: int = 1

# Effective reserve target (dynamically adjusted based on price)
var effective_reserve_target: int = 3
var last_logged_price_adjustment_tick: int = -999999

# Travel State
var last_market_trip_tick: int = -999999
var logged_staying_home: bool = false

# Labor-market tracking now forwarded via Agent base class

# Constants
const SPEED: float = 100.0
const ARRIVAL_DISTANCE: float = 5.0
const WAIT_TIME: float = 1.0

# State
var bread_consumed: int = 0

# Validation flag - only log missing nodes once
var _validation_logged: bool = false


func get_display_name() -> String:
	return "Household"


func get_inspector_data() -> Dictionary:
	var d: Dictionary = _base_inspector_data()
	d["role"] = "Household"
	var phase_str := "AT_HOME" if phase == Phase.AT_HOME else "AT_MARKET"
	var state_str := phase_str
	if route:
		if route.is_traveling:
			state_str = "traveling→" + (route.target.name if route.target else "?")
		elif pending_target != null:
			state_str = phase_str + " (waiting→" + pending_target.name + ")"
	d["state"] = state_str
	d["bread_consumed"] = bread_consumed
	d["effective_reserve"] = effective_reserve_target
	d["failed_food_days"] = consecutive_failed_food_days
	d["switch_cooldown"] = switch_cooldown_days
	d["prod_mult"] = 1.0
	if training_days_remaining > 0:
		d["training_days"] = training_days_remaining
	return d


func _ready() -> void:
	_health_bar_y = -24.0
	super()
	add_to_group("households")
	
	if not _validation_logged:
		_validate_components()
	
	if wallet:
		wallet.money = 5000.0
	if inv:
		inv.items = {"bread": 0}
	
	if cap and inv:
		cap.bind(inv)
		inv.bind_capacity(cap)
	
	if food_stockpile and inv:
		food_stockpile.bind(inv)
	
	if route:
		route.bind(self)
		route.speed = SPEED
		route.arrival_distance = ARRIVAL_DISTANCE
		route.arrived.connect(_on_arrived)
		route.wait_finished.connect(_on_wait_finished)
		route.travel_timeout.connect(_on_travel_timeout)
	
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
	"""Calculate effective reserve target based on current bread price (demand elasticity)."""
	if market == null:
		return reserve_target_base
	
	var current_price: float = market.bread_price
	
	if current_price <= bread_price_soft_cap:
		return reserve_target_base
	
	if current_price >= bread_price_hard_cap:
		return reserve_target_min
	
	var price_range: float = bread_price_hard_cap - bread_price_soft_cap
	var price_excess: float = current_price - bread_price_soft_cap
	var reduction_ratio: float = price_excess / price_range
	var target_range: float = float(reserve_target_base - reserve_target_min)
	var adjusted_target: int = reserve_target_base - int(reduction_ratio * target_range)
	
	if adjusted_target != reserve_target_base and current_tick - last_logged_price_adjustment_tick > 100:
		if event_bus:
			event_bus.log("%s high price $%.2f: reserve_target %d→%d" % [name, current_price, reserve_target_base, adjusted_target])
		last_logged_price_adjustment_tick = current_tick
	
	return clamp(adjusted_target, reserve_target_min, reserve_target_base)


func _on_ate_meal(qty: int) -> void:
	bread_consumed += qty


func set_tick(t: int) -> void:
	current_tick = t
	effective_reserve_target = _calculate_effective_reserve_target()
	if food_reserve:
		food_reserve.set_tick(t)
		food_reserve.check_survival_mode()
		food_reserve.update_survival_override()
	
	_check_travel_timeout()
	_check_idle_guard()


func set_locations(home: Node2D, market_node: Node2D) -> void:
	home_location = home
	market_location = market_node
	if food_reserve and market:
		food_reserve.bind(inv, hunger, market, wallet, event_bus, get_display_name())
	route.set_target(home_location)


func _on_arrived(t: Node2D) -> void:
	travel_ticks = 0
	idle_ticks = 0
	if t == market_location:
		attempt_buy_bread()
		phase = Phase.AT_MARKET
		pending_target = home_location
		route.wait(WAIT_TIME)
	elif t == home_location:
		consume_bread_at_home()
		phase = Phase.AT_HOME
		var current_bread: int = inv.get_qty("bread") if inv != null else 0
		var hunger_ratio: float = float(hunger.hunger_days) / float(hunger.hunger_max_days) if hunger != null and hunger.hunger_max_days > 0 else 1.0
		
		if needs_food_trip():
			pending_target = market_location
			if event_bus and not logged_staying_home:
				event_bus.log("Tick %d: %s deciding to go to market (bread=%d/%d, hunger=%.1f%%)" % [current_tick, name, current_bread, effective_reserve_target, hunger_ratio * 100])
		else:
			pending_target = home_location
			if event_bus and not logged_staying_home:
				event_bus.log("Tick %d: %s staying home (bread=%d/%d, hunger=%.1f%%)" % [current_tick, name, current_bread, effective_reserve_target, hunger_ratio * 100])
				logged_staying_home = true
		route.wait(WAIT_TIME)


func _on_wait_finished() -> void:
	if pending_target != null:
		if pending_target == market_location and not needs_food_trip():
			pending_target = home_location
			if event_bus:
				event_bus.log("Tick %d: %s [BUGFIX] market trip cancelled - need resolved during wait" % [current_tick, name])
		if pending_target == market_location and pending_target != route.target:
			log_travel_decision("going to market")
		route.set_target(pending_target)
		pending_target = null


func attempt_buy_bread() -> void:
	if market and wallet and inv:
		var current_bread: int = inv.get_qty("bread")
		var hunger_ratio: float = float(hunger.hunger_days) / float(hunger.hunger_max_days) if hunger != null and hunger.hunger_max_days > 0 else 1.0
		
		var target_to_use: int = effective_reserve_target
		if hunger_ratio <= emergency_hunger_threshold or current_bread == 0:
			target_to_use = max(reserve_target_base, 1)
		
		var deficit: int = max(0, target_to_use - current_bread)
		var desired: int = ceili(deficit * buy_batch_multiplier)
		
		if desired == 0:
			if event_bus:
				event_bus.log("Tick %d: %s [BUGFIX] at market but no deficit (%d/%d) - returning home" % [current_tick, name, current_bread, effective_reserve_target])
			return
		
		var qty_bought: int = market.sell_bread_to_household(self, desired)
		
		if qty_bought > 0:
			inv.add("bread", qty_bought)
			cashflow_today_expense += float(qty_bought) * (market.bread_price if market else 0.0)
			consecutive_failed_food_days = 0
			if event_bus:
				event_bus.log("Tick %d: %s bought %d bread (wanted %d, now have %d)" % [current_tick, name, qty_bought, desired, inv.get_qty("bread")])
			log_event("Bread buy: got=%d/%d  mkt=%d" % [qty_bought, desired, market.bread if market else -1])
		else:
			consecutive_failed_food_days += 1
			if event_bus:
				event_bus.log("Tick %d: %s tried to buy %d bread, bought 0 (market empty, fail_streak=%d)" % [current_tick, name, desired, consecutive_failed_food_days])
			var _mkt_inv: int = market.bread if market else -1
			var _reason: String
			if _mkt_inv == 0:
				_reason = "empty"
			elif wallet != null and market != null and wallet.money < market.bread_price:
				_reason = "insufficient_funds"
			else:
				_reason = "blocked"
			log_event("Bread buy: wanted=%d, got=0, mkt=%d, reason=%s" % [desired, _mkt_inv, _reason])


func consume_bread_at_home() -> void:
	pass


func needs_food_trip() -> bool:
	if inv == null or hunger == null:
		return false
	
	if current_tick - last_market_trip_tick < market_trip_cooldown_ticks:
		return false
	
	var current_bread: int = inv.get_qty("bread")
	var hunger_ratio: float = float(hunger.hunger_days) / float(hunger.hunger_max_days) if hunger.hunger_max_days > 0 else 1.0
	
	if current_bread == 0:
		return true
	if hunger.hunger_days == 0:
		return true
	if hunger_ratio <= emergency_hunger_threshold:
		return true
	
	if current_bread < effective_reserve_target:
		return true
	
	if hunger_ratio <= hunger_buy_threshold_ratio:
		return true
	
	return false


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
	_person_day = _day
	_roll_cashflow()
	_progress_skills("Household")
	# Daily snapshot for life-history panel
	var _br: int = inv.get_qty("bread") if inv else 0
	log_event("── $%.0f  br=%d" % [get_cash(), _br])
	if training_days_remaining > 0:
		training_days_remaining -= 1


## Handle starvation death.
func _on_starved(agent_name_param: String) -> void:
	log_event("Died: reason=starvation")
	if event_bus:
		event_bus.log("STARVATION: %s died (hunger depleted, no food available)" % agent_name_param)
	
	if has_signal("household_died"):
		emit_signal("household_died", self)
	
	queue_free()
