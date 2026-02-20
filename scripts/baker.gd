extends Agent
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
const FLOUR_PER_WHEAT: int = 2
const BREAD_PER_FLOUR: int = 1

# Batch cycle thresholds
const WHEAT_LOW_WATERMARK: int = 5
const WHEAT_TARGET_STOCK: int = 30
const BREAD_SELL_THRESHOLD: int = 20
const BREAD_PRODUCTION_MIN: int = 2

# Production recipe for profitability checking (full wheat→bread chain)
const BREAD_RECIPE: Dictionary = {
	"output_good": "bread",
	"output_quantity": 2,
	"inputs": {"wheat": 1}
}

var process_timer: float = 0.0

# Role-specific components (beyond what Agent provides)
@onready var prod: ProductionBatch = $ProductionBatch
@onready var profit: ProductionProfitability = $ProductionProfitability

# Margin compression component (loaded dynamically to avoid class resolution issues)
var margin_compression = null
var inventory_throttle = null

# Error throttling to prevent spam
var last_phase_error_tick: int = -1
var phase_error_cooldown: int = 100

# Production tracking for diagnostics
var last_diagnostic_day: int = -1
var bread_produced_today: int = 0

# Capital constraints (B) - maintenance costs and production capacity
var oven_capacity_per_day: int = 15
var maintenance_cost_per_day: float = 0.3
var day_money_start: float = -1.0

# [BUGFIX] Hysteresis cooldown (role-specific recovery)
var hysteresis_cooldown_ticks: int = 0


func get_display_name() -> String:
	return "Baker"


func get_inspector_data() -> Dictionary:
	var d: Dictionary = _base_inspector_data()
	d["role"] = "Baker"
	var phase_names: Array[String] = ["RESTOCK", "PRODUCE", "SELL"]
	var phase_str: String = phase_names[phase] if phase < phase_names.size() else "?"
	var state_str := phase_str
	if route:
		if route.is_traveling:
			state_str = "traveling→" + (route.target.name if route.target else "?")
		elif pending_target != null:
			state_str = phase_str + " (waiting→" + pending_target.name + ")"
	d["state"] = state_str
	d["wheat"] = inv.get_qty("wheat") if inv else 0
	d["flour"] = inv.get_qty("flour") if inv else 0
	d["neg_cashflow_days"] = consecutive_days_negative_cashflow
	d["prod_mult"] = clamp(lerp(0.85, 1.25, skill_baker), 0.85, 1.25)
	return d


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
		inventory_throttle.calculate_throttle(BREAD_RECIPE)
	if food_reserve:
		food_reserve.set_tick(t)
		food_reserve.check_survival_mode()
		food_reserve.update_survival_override()
	
	@warning_ignore("integer_division")
	var current_day: int = t / 100
	if current_day != last_diagnostic_day:
		if last_diagnostic_day >= 0 and bread_produced_today == 0:
			var has_wheat: bool = inv.get_qty("wheat") > 0
			var at_bakery: bool = route and route.target == null and position.distance_to(bakery_location.global_position) <= 10.0
			if has_wheat and at_bakery and event_bus:
				event_bus.log("Tick %d: [DIAGNOSTIC] Baker produced 0 bread on day %d (wheat=%d, at_bakery=%s, profit=%s, override=%s)" % [
					t, last_diagnostic_day, inv.get_qty("wheat"), at_bakery, 
					(str(profit.is_production_profitable(BREAD_RECIPE)) if profit else "N/A"),
					(food_reserve.survival_override_active if food_reserve else false)
				])
		last_diagnostic_day = current_day
		bread_produced_today = 0
	
	if t == 0 and event_bus:
		event_bus.log("Tick 0: Baker starting food=%d" % inv.get_qty("bread"))
	
	if hysteresis_cooldown_ticks > 0:
		hysteresis_cooldown_ticks -= 1
	_check_travel_timeout()
	_check_idle_and_pause_guard()


func _ready() -> void:
	super()
	add_to_group("bakers")
	wallet.money = 500.0
	inv.items = {"wheat": 0, "flour": 0, "bread": 2}
	
	if has_node("MarginCompression"):
		margin_compression = get_node("MarginCompression")
	if has_node("InventoryThrottle"):
		inventory_throttle = get_node("InventoryThrottle")
	
	cap.bind(inv)
	inv.bind_capacity(cap)
	prod.bind(inv, cap)
	food_stockpile.bind(inv)
	
	route.bind(self)
	route.speed = SPEED
	route.arrival_distance = ARRIVAL_DISTANCE
	route.arrived.connect(_on_arrived)
	route.wait_finished.connect(_on_wait_finished)
	route.travel_timeout.connect(_on_travel_timeout)


func set_locations(bakery: Node2D, market_node: Node2D) -> void:
	bakery_location = bakery
	market_location = market_node
	if event_bus and route:
		route.bind_logging(event_bus, get_display_name())
	if profit and market and event_bus:
		profit.bind(market, event_bus, get_display_name())
	if margin_compression and market and event_bus:
		margin_compression.bind(market, event_bus, get_display_name())
	if inventory_throttle and market and event_bus:
		inventory_throttle.bind(market, event_bus, get_display_name())
	if food_reserve and market:
		food_reserve.bind(inv, hunger, market, wallet, event_bus, get_display_name())
	route.set_target(market_location)


func _physics_process(delta: float) -> void:
	if hunger.is_starving:
		route.stop()
		return
	
	match production_state:
		ProductionState.GRINDING:
			process_grinding(delta)
		ProductionState.BAKING:
			process_baking(delta)


func _on_arrived(t: Node2D) -> void:
	travel_ticks = 0
	idle_ticks = 0
	if t == market_location and market != null:
		perform_market_transactions()
		pending_target = bakery_location
		route.wait(WAIT_TIME)
	elif t == bakery_location:
		handle_bakery_arrival()


func _on_wait_finished() -> void:
	if production_state == ProductionState.IDLE and pending_target != null:
		route.set_target(pending_target)
		pending_target = null


func _on_travel_timeout(_t: Node2D) -> void:
	travel_ticks = 0
	idle_ticks = 0
	print("[BUGFIX] Baker: travel timeout, forcing RESTOCK")
	if event_bus:
		event_bus.log("[TRAVEL] Tick %d: Baker travel timeout recovery - forcing RESTOCK phase" % current_tick)
	production_state = ProductionState.IDLE
	phase = Phase.RESTOCK
	pending_target = market_location
	route.wait(WAIT_TIME)


func perform_market_transactions() -> void:
	if food_reserve and food_reserve.is_survival_mode:
		var bought: int = food_reserve.attempt_survival_purchase()
		if bought > 0 and not food_reserve.is_survival_mode:
			pass
		elif bought > 0 and food_reserve.is_survival_mode:
			pending_target = market_location
			route.wait(WAIT_TIME)
			return
	
	match phase:
		Phase.RESTOCK:
			if not market.can_producer_produce("bread"):
				hysteresis_cooldown_ticks = randi_range(5, 15)
				print("[BUGFIX] Baker BUY blocked by hysteresis → cooldown %d ticks" % hysteresis_cooldown_ticks)
				if event_bus:
					event_bus.log("[HYSTERESIS] Tick %d: Baker BUY blocked → cooldown %d ticks (bread production paused)" % [current_tick, hysteresis_cooldown_ticks])
				phase = Phase.PRODUCE
				pending_target = bakery_location
				route.wait(WAIT_TIME)
			else:
				var current_wheat: int = inv.get_qty("wheat")
				if current_wheat < WHEAT_LOW_WATERMARK:
					var base_target: int = WHEAT_TARGET_STOCK - current_wheat
					var adjusted_target: int = base_target
					
					if inventory_throttle:
						var throttle_factor: float = inventory_throttle.production_throttle
						adjusted_target = max(1, int(float(base_target) * throttle_factor))
					
					var _cf_wbuy_snap: float = get_cash()
					var _bw: int = market.sell_wheat_to_baker(self, adjusted_target)
					cashflow_today_expense += max(0.0, _cf_wbuy_snap - get_cash())
					if _bw > 0:
						log_event("Bought %d wheat" % _bw)
				phase = Phase.PRODUCE
				pending_target = bakery_location
				route.wait(WAIT_TIME)
		
		Phase.SELL:
			if not market.can_producer_sell("bread"):
				hysteresis_cooldown_ticks = randi_range(5, 15)
				print("[BUGFIX] Baker SELL blocked by hysteresis → cooldown %d ticks" % hysteresis_cooldown_ticks)
				if event_bus:
					event_bus.log("[HYSTERESIS] Tick %d: Baker SELL blocked → cooldown %d ticks" % [current_tick, hysteresis_cooldown_ticks])
				phase = Phase.PRODUCE
				pending_target = bakery_location
				route.wait(WAIT_TIME)
				return
			
			if margin_compression and margin_compression.should_throttle_selling(BREAD_RECIPE):
				phase = Phase.PRODUCE
				pending_target = bakery_location
				route.wait(WAIT_TIME)
				return
			
			if market.is_saturated("bread"):
				if event_bus:
					var info = market.get_saturation_info("bread")
					event_bus.log("Tick %d: Baker skipping sell - market bread storage saturated (%d/%d)" % [current_tick, info["current"], info["capacity"]])
				pending_target = market_location
				route.wait(WAIT_TIME)
				return
			
			var current_bread: int = inv.get_qty("bread")
			var sellable: int = max(0, current_bread - BREAD_PRODUCTION_MIN)
			if inventory_throttle:
				sellable = inventory_throttle.apply_to_sell(sellable)
			if sellable > 0:
				var min_price: float = 0.0
				if profit:
					min_price = profit.get_min_acceptable_price(BREAD_RECIPE)
				var _cf_bsale_snap: float = get_cash()
				var _bs: int = market.buy_bread_from_agent(self, sellable, min_price)
				cashflow_today_income += max(0.0, get_cash() - _cf_bsale_snap)
				if _bs > 0:
					log_event("Sold %d bread" % _bs)
			
			var current_wheat: int = inv.get_qty("wheat")
			if current_wheat < WHEAT_LOW_WATERMARK:
				phase = Phase.RESTOCK
				pending_target = market_location
				route.wait(WAIT_TIME)
			else:
				phase = Phase.PRODUCE
				pending_target = bakery_location
				route.wait(WAIT_TIME)
		
		Phase.PRODUCE:
			if event_bus and (current_tick - last_phase_error_tick) >= phase_error_cooldown:
				event_bus.log("ERROR Tick %d: Baker at market during PRODUCE phase (state machine leak)" % current_tick)
				last_phase_error_tick = current_tick
			phase = Phase.RESTOCK
			pending_target = market_location
			route.wait(WAIT_TIME)


func handle_bakery_arrival() -> void:
	if not hunger.is_starving:
		phase = Phase.PRODUCE
		start_production()
	else:
		phase = Phase.RESTOCK
		pending_target = market_location
		route.wait(WAIT_TIME)


func start_production() -> void:
	if global_position.distance_to(bakery_location.global_position) > ARRIVAL_DISTANCE * 2:
		if event_bus:
			event_bus.log("Tick %d: Baker attempting production while not at bakery" % current_tick)
		return
	
	route.stop()
	
	if inv.get_qty("wheat") > 0:
		production_state = ProductionState.GRINDING
		process_timer = GRINDING_TIME
	elif inv.get_qty("flour") > 0:
		production_state = ProductionState.BAKING
		process_timer = BAKING_TIME
	else:
		production_state = ProductionState.IDLE
		phase = Phase.RESTOCK
		pending_target = market_location
		route.wait(WAIT_TIME)


func process_grinding(delta: float) -> void:
	process_timer -= delta
	if process_timer <= 0.0:
		if not market.can_producer_produce("bread"):
			production_state = ProductionState.IDLE
			phase = Phase.SELL if inv.get_qty("bread") >= BREAD_PRODUCTION_MIN else Phase.RESTOCK
			pending_target = market_location
			route.wait(WAIT_TIME)
			return
		
		var can_produce: bool = true
		
		if margin_compression and margin_compression.should_throttle_production(BREAD_RECIPE):
			if food_reserve and food_reserve.survival_override_active:
				var current_food: int = inv.get_qty("bread")
				can_produce = current_food < food_reserve.min_reserve_units
			else:
				can_produce = false
		elif profit and not profit.is_production_profitable(BREAD_RECIPE):
			if food_reserve and food_reserve.survival_override_active:
				var current_food: int = inv.get_qty("bread")
				can_produce = current_food < food_reserve.min_reserve_units
			else:
				can_produce = false
		
		if not can_produce:
			production_state = ProductionState.IDLE
			phase = Phase.SELL if inv.get_qty("bread") >= BREAD_PRODUCTION_MIN else Phase.RESTOCK
			pending_target = market_location
			route.wait(WAIT_TIME)
			return
		
		var target_batch: int = GRIND_BATCH_SIZE
		
		if inventory_throttle and not (food_reserve and food_reserve.survival_override_active):
			target_batch = inventory_throttle.apply_to_batch(target_batch)
		var units: int = prod.compute_batch(target_batch, "wheat", "flour", FLOUR_PER_WHEAT)
		
		if units == 0:
			if inv.get_qty("wheat") == 0:
				if inv.get_qty("flour") > 0:
					production_state = ProductionState.BAKING
					process_timer = BAKING_TIME
				else:
					production_state = ProductionState.IDLE
					phase = Phase.RESTOCK
					pending_target = market_location
					route.wait(WAIT_TIME)
			else:
				production_state = ProductionState.IDLE
				phase = Phase.SELL
				pending_target = market_location
				route.wait(WAIT_TIME)
		else:
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
				log_event("Ground %d wheat → %d flour" % [units, flour_produced])
				
				var current_bread: int = inv.get_qty("bread")
				var current_flour: int = inv.get_qty("flour")
				var current_wheat: int = inv.get_qty("wheat")
				
				if current_bread >= BREAD_SELL_THRESHOLD:
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
				elif current_flour > 0 and cap.remaining_space() >= BREAD_PER_FLOUR:
					production_state = ProductionState.BAKING
					process_timer = BAKING_TIME
				elif current_wheat > 0 and cap.remaining_space() >= FLOUR_PER_WHEAT:
					production_state = ProductionState.GRINDING
					process_timer = GRINDING_TIME
				else:
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
		if not market.can_producer_produce("bread"):
			production_state = ProductionState.IDLE
			phase = Phase.SELL if inv.get_qty("bread") >= BREAD_PRODUCTION_MIN else Phase.RESTOCK
			pending_target = market_location
			route.wait(WAIT_TIME)
			return
		
		var can_produce: bool = true
		
		if margin_compression and margin_compression.should_throttle_production(BREAD_RECIPE):
			if food_reserve and food_reserve.survival_override_active:
				var current_food: int = inv.get_qty("bread")
				can_produce = current_food < food_reserve.min_reserve_units
			else:
				can_produce = false
		elif profit and not profit.is_production_profitable(BREAD_RECIPE):
			if food_reserve and food_reserve.survival_override_active:
				var current_food: int = inv.get_qty("bread")
				can_produce = current_food < food_reserve.min_reserve_units
			else:
				can_produce = false
		
		if not can_produce:
			production_state = ProductionState.IDLE
			phase = Phase.SELL if inv.get_qty("bread") >= BREAD_PRODUCTION_MIN else Phase.RESTOCK
			pending_target = market_location
			route.wait(WAIT_TIME)
			return
		
		if bread_produced_today >= oven_capacity_per_day:
			if event_bus:
				event_bus.log("Tick %d: Baker [CAP] oven capacity reached (%d/%d) - going to sell" % [
					current_tick, bread_produced_today, oven_capacity_per_day])
			production_state = ProductionState.IDLE
			phase = Phase.SELL if inv.get_qty("bread") >= BREAD_PRODUCTION_MIN else Phase.RESTOCK
			pending_target = market_location
			route.wait(WAIT_TIME)
			return
		
		var target_batch: int = BAKE_BATCH_SIZE
		
		if inventory_throttle and not (food_reserve and food_reserve.survival_override_active):
			target_batch = inventory_throttle.apply_to_batch(target_batch)
		var units: int = prod.compute_batch(target_batch, "flour", "bread", BREAD_PER_FLOUR)
		
		if units == 0:
			if inv.get_qty("flour") == 0:
				if inv.get_qty("wheat") > 0:
					production_state = ProductionState.GRINDING
					process_timer = GRINDING_TIME
				else:
					production_state = ProductionState.IDLE
					phase = Phase.RESTOCK
					pending_target = market_location
					route.wait(WAIT_TIME)
			else:
				production_state = ProductionState.IDLE
				phase = Phase.SELL
				pending_target = market_location
				route.wait(WAIT_TIME)
		else:
			var ok: bool = prod.convert("flour", "bread", units, BREAD_PER_FLOUR)
			if not ok:
				if event_bus:
					event_bus.log("ERROR Tick %d: Baker baking failed due to capacity/rollback safety" % current_tick)
				production_state = ProductionState.IDLE
				phase = Phase.RESTOCK
				pending_target = market_location
				route.wait(WAIT_TIME)
			else:
				var _base_bread: int    = units * BREAD_PER_FLOUR
				var _sk_mult: float     = clamp(lerp(0.85, 1.25, skill_baker), 0.85, 1.25)
				var bread_produced: int = maxi(1, roundi(float(_base_bread) * _sk_mult))
				var _diff: int          = bread_produced - _base_bread
				if _diff > 0:
					inv.add("bread", _diff)
				elif _diff < 0:
					inv.remove("bread", mini(-_diff, inv.get_qty("bread")))
				bread_produced_today += bread_produced
				if event_bus:
					event_bus.log("Tick %d: Baker baked %d flour into %d bread (skill=%.2f)" % [current_tick, units, bread_produced, skill_baker])
				log_event("Baked %d bread (sk=%.2f ×%.2f)" % [bread_produced, skill_baker, _sk_mult])
				
				var current_bread: int = inv.get_qty("bread")
				var current_flour: int = inv.get_qty("flour")
				var current_wheat: int = inv.get_qty("wheat")
				
				if current_bread >= BREAD_SELL_THRESHOLD:
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
				elif current_flour > 0 and cap.remaining_space() >= BREAD_PER_FLOUR:
					production_state = ProductionState.BAKING
					process_timer = BAKING_TIME
				elif current_wheat > 0 and cap.remaining_space() >= FLOUR_PER_WHEAT:
					production_state = ProductionState.GRINDING
					process_timer = GRINDING_TIME
				else:
					production_state = ProductionState.IDLE
					if current_bread >= BREAD_PRODUCTION_MIN:
						phase = Phase.SELL
					else:
						phase = Phase.RESTOCK
					pending_target = market_location
					route.wait(WAIT_TIME)


## Called once per game day by main._on_calendar_day_changed.
func on_day_changed(_day: int) -> void:
	_person_day = _day
	_roll_cashflow()
	_progress_skills("Baker")
	# Daily snapshot for life-history panel
	var _br: int  = inv.get_qty("bread") if inv else 0
	var _fl: int  = inv.get_qty("flour") if inv else 0
	log_event("── $%.0f  br=%d  fl=%d" % [get_cash(), _br, _fl])
	# Evaluate yesterday's cashflow BEFORE paying today's maintenance
	var cur_money: float = wallet.money if wallet else 0.0
	if day_money_start >= 0.0:
		if cur_money <= day_money_start:
			consecutive_days_negative_cashflow += 1
		else:
			consecutive_days_negative_cashflow = 0
	
	if wallet and maintenance_cost_per_day > 0.0:
		wallet.debit(maintenance_cost_per_day)
		cashflow_today_expense += maintenance_cost_per_day
	
	day_money_start = wallet.money if wallet else 0.0
	bread_produced_today = 0


func _check_travel_timeout() -> void:
	if route == null:
		return
	if route.is_traveling:
		travel_ticks += 1
		if travel_ticks > MAX_TRAVEL_TICKS:
			var tname: String = route.target.name if route.target else "null"
			print("[BUGFIX] Baker: travel timeout reset after %d ticks (target=%s)" % [travel_ticks, tname])
			if event_bus:
				event_bus.log("[TRAVEL] Tick %d: Baker travel timeout reset (travel_ticks=%d, target=%s)" % [current_tick, travel_ticks, tname])
			route.stop()
			travel_ticks = 0
			production_state = ProductionState.IDLE
			phase = Phase.RESTOCK
			pending_target = market_location
			route.wait(WAIT_TIME)
	else:
		travel_ticks = 0


func _check_idle_and_pause_guard() -> void:
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
	if production_state != ProductionState.IDLE:
		idle_ticks = 0
		return
	idle_ticks += 1
	if idle_ticks < MAX_IDLE_TICKS:
		return
	idle_ticks = 0
	if market and not market.can_producer_produce("bread"):
		hysteresis_cooldown_ticks = randi_range(5, 15)
		print("[BUGFIX] Baker: idle during production pause → cooldown %d ticks" % hysteresis_cooldown_ticks)
		if event_bus:
			event_bus.log("[HYSTERESIS] Tick %d: Baker idle during production pause, cooldown %d ticks" % [current_tick, hysteresis_cooldown_ticks])
	else:
		print("[STATE] Baker: idle guard triggered, forcing RESTOCK")
		if event_bus:
			event_bus.log("[STATE] Tick %d: Baker idle guard triggered, forcing RESTOCK" % current_tick)
		phase = Phase.RESTOCK
		pending_target = market_location
		route.wait(WAIT_TIME)


func get_status_text() -> String:
	
	match production_state:
		ProductionState.GRINDING:
			return "Grinding wheat"
		ProductionState.BAKING:
			return "Baking bread"
	
	if route.target == bakery_location:
		if route.is_waiting:
			return "Waiting at Bakery"
		return "Walking to Bakery"
	elif route.target == market_location:
		if route.is_waiting:
			return "Waiting at Market"
		return "Walking to Market"
	
	return route.get_status_text()
