extends JobBase
class_name BakerJob

## Baker job component - buys wheat, grinds flour, bakes bread, sells at market.
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

const GRIND_BATCH_SIZE: int = 5
const BAKE_BATCH_SIZE: int = 5
const FLOUR_PER_WHEAT: int = 2
const BREAD_PER_FLOUR: int = 1

const WHEAT_LOW_WATERMARK: int = 5
const WHEAT_TARGET_STOCK: int = 30
const BREAD_SELL_THRESHOLD: int = 20
const BREAD_PRODUCTION_MIN: int = 2

const BREAD_RECIPE: Dictionary = {
	"output_good": "bread",
	"output_quantity": 2,
	"inputs": {"wheat": 1}
}

var process_timer: float = 0.0

# Role-specific components (resolved from agent in activate)
var prod: ProductionBatch = null
var profit: ProductionProfitability = null
var margin_compression = null
var inventory_throttle = null

var last_phase_error_tick: int = -1
var phase_error_cooldown: int = 100

var last_diagnostic_day: int = -1
var bread_produced_today: int = 0

var oven_capacity_per_day: int = 15
var maintenance_cost_per_day: float = 0.3
var consecutive_days_negative_cashflow: int = 0
var day_money_start: float = -1.0

var hysteresis_cooldown_ticks: int = 0

# ── Inter-village trade evaluation ────────────────────────────────────────────
## Evaluate trade every 30 ticks (0.3 in-game days, 3 evals/day max).
## Reduces log noise and churn; baker remains reactive without over-evaluating.
const TRADE_EVAL_INTERVAL: int = 30
## Minimum profit edge over staying local before baker commits to travel.
const MIN_PROFIT_THRESHOLD: float = 0.3
## Travel cost per world unit of distance. Villages are ~2000 units apart.
const TRAVEL_COST_PER_DISTANCE: float = 0.0002
## Ticks the baker must stay at a village after arrival before re-evaluating trade.
## Set to 200 — ~2 in-game days at 100 ticks/day; ~20% of inter-village travel time.
const TRADE_MIN_STAY_TICKS: int = 200

## True while the baker is actively traveling to or operating at a foreign village.
var trade_route_active: bool = false
## Target village for the current cross-village trip (null when not traveling).
var trade_target_village: Node = null
## Market node in the target village used as the routing destination.
var _trade_target_market_node: Node2D = null
## Bypass flag for _validate_target(): set true only during intentional trade travel.
var _intentional_cross_village: bool = false
## Tick at or after which a new trade evaluation is permitted (commitment window).
## Deterministic: set to current_tick + TRADE_MIN_STAY_TICKS on every trade arrival.
var trade_commit_until_tick: int = 0
## False while a sale attempt at the current destination is still pending.
## Evaluation is blocked until true. Initialized true (no pending cycle at start).
var trade_sale_completed: bool = true
## Tick on which the baker last initiated a cross-village trade move.
## Used for [TRADE DEBUG] log to detect ping-ponging.
var _last_trade_move_tick: int = -1
## Number of completed cross-village arrivals (incremented only in _on_trade_arrival).
## Canonical migration-complete counter: non-zero means at least one trip finished.
var trade_arrival_count: int = 0

func get_display_name() -> String:
	return "Baker"


func get_job_inspector_data() -> Dictionary:
	var d: Dictionary = {}
	d["role"] = "Baker"
	var phase_names: Array[String] = ["RESTOCK", "PRODUCE", "SELL"]
	var phase_str: String = phase_names[phase] if phase < phase_names.size() else "?"
	var state_str := phase_str
	if trade_route_active and trade_target_village != null:
		var vname: String = trade_target_village.get("village_name") if trade_target_village.get("village_name") else trade_target_village.name
		state_str = "trade→%s" % vname
	elif route:
		if route.is_traveling:
			state_str = "traveling→" + (route.target.name if route.target else "?")
		elif agent.pending_target != null:
			state_str = phase_str + " (waiting→" + agent.pending_target.name + ")"
	d["state"] = state_str
	d["wheat"] = inv.get_qty("wheat") if inv else 0
	d["flour"] = inv.get_qty("flour") if inv else 0
	d["neg_cashflow_days"] = consecutive_days_negative_cashflow
	d["prod_mult"] = clamp(lerp(0.85, 1.25, agent.skill_baker), 0.85, 1.25)
	d["trade_active"] = trade_route_active
	d["trade_target"] = trade_target_village.get("village_name") if trade_target_village and trade_target_village.get("village_name") else ""
	d["current_village"] = agent.current_village_ref.get("village_name") if agent.current_village_ref and agent.current_village_ref.get("village_name") else ""
	return d


func set_tick(t: int) -> void:
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
			var at_bakery: bool = route and route.target == null and bakery_location != null and agent.position.distance_to(bakery_location.global_position) <= 10.0
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
	_maybe_evaluate_trade(t)


const STARTING_CASH: float = 500.0

func activate() -> void:
	if wallet and wallet.money <= 0.0:
		wallet.credit(STARTING_CASH)
	if inv:
		inv.items = {"wheat": 0, "flour": 0, "bread": 5}
	prod = agent.get_node_or_null("ProductionBatch") as ProductionBatch
	profit = agent.get_node_or_null("ProductionProfitability") as ProductionProfitability
	margin_compression = agent.get_node_or_null("MarginCompression")
	inventory_throttle = agent.get_node_or_null("InventoryThrottle")
	if prod and cap:
		prod.bind(inv, cap)
	route.bind(agent)
	route.speed = SPEED
	route.arrival_distance = ARRIVAL_DISTANCE
	route.arrived.connect(_on_arrived)
	route.wait_finished.connect(_on_wait_finished)
	route.travel_timeout.connect(_on_travel_timeout)


func deactivate() -> void:
	if route:
		if route.arrived.is_connected(_on_arrived):
			route.arrived.disconnect(_on_arrived)
		if route.wait_finished.is_connected(_on_wait_finished):
			route.wait_finished.disconnect(_on_wait_finished)
		if route.travel_timeout.is_connected(_on_travel_timeout):
			route.travel_timeout.disconnect(_on_travel_timeout)


## Returns true if target is village-local (safe to route to), false if cross-village (blocked).
## Uses the "village_id" meta stamped on bakery_spot and market nodes by village.gd.
## Targets without the meta pass through (backward-compatible with unstamped nodes).
## Bypassed when _intentional_cross_village is true (trade travel).
func _validate_target(target: Node2D) -> bool:
	if target == null:
		return false
	# Allow intentional cross-village travel (trade routes set _intentional_cross_village=true).
	if _intentional_cross_village:
		return true
	var target_vid: int = target.get_meta("village_id", -1)
	var agent_vid: int = agent.home_village_id
	if target_vid != -1 and target_vid != agent_vid:
		push_error("[ERROR] CROSS-VILLAGE TARGET BLOCKED: agent=%s (village=%d) -> target=%s (village=%d)" % [agent.name, agent_vid, target.name, target_vid])
		if event_bus:
			event_bus.log("[ERROR] CROSS-VILLAGE TARGET BLOCKED: agent=%s (village=%d) -> target=%s (village=%d)" % [agent.name, agent_vid, target.name, target_vid])
		return false
	if event_bus:
		event_bus.log("[TARGET] agent=%s village=%d -> target=%s" % [agent.name, agent_vid, target.name])
	return true


func set_locations(bakery: Node2D, market_node: Node2D) -> void:
	# Hard village-locality check: block cross-village bakery or market assignment.
	if not _validate_target(bakery):
		push_error("[ERROR] Baker(%s, village=%d): set_locations rejected bakery %s" % [agent.name, agent.home_village_id, bakery.name if bakery else "null"])
		return
	if not _validate_target(market_node):
		push_error("[ERROR] Baker(%s, village=%d): set_locations rejected market %s" % [agent.name, agent.home_village_id, market_node.name if market_node else "null"])
		return
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


func physics_tick(delta: float) -> void:
	if hunger.is_starving:
		route.stop()
		return
	match production_state:
		ProductionState.GRINDING:
			process_grinding(delta)
		ProductionState.BAKING:
			process_baking(delta)


func _on_arrived(t: Node2D) -> void:
	agent.travel_ticks = 0
	agent.idle_ticks = 0
	# Cross-village trade arrival takes priority over normal routing.
	if _trade_target_market_node != null and t == _trade_target_market_node:
		_on_trade_arrival()
		return
	if t == market_location and market != null:
		perform_market_transactions()
		if _validate_target(bakery_location):
			agent.pending_target = bakery_location
		route.wait(WAIT_TIME)
	elif t == bakery_location:
		handle_bakery_arrival()


func _on_wait_finished() -> void:
	if production_state == ProductionState.IDLE and agent.pending_target != null:
		# Final safety net: validate pending_target before routing.
		if not _validate_target(agent.pending_target):
			agent.pending_target = null
			return
		route.set_target(agent.pending_target)
		agent.pending_target = null


func _on_travel_timeout(_t: Node2D) -> void:
	agent.travel_ticks = 0
	agent.idle_ticks = 0
	if trade_route_active:
		trade_route_active = false
		trade_target_village = null
		_trade_target_market_node = null
		_intentional_cross_village = false
		trade_sale_completed = true
		# Open commit window so agent cannot immediately retry the failed trip.
		_begin_trade_commit_window()
		if event_bus:
			event_bus.log("[TRAVEL] Baker: trade travel timed out — trade state reset")
	print("[BUGFIX] Baker: travel timeout, forcing RESTOCK")
	if event_bus:
		event_bus.log("[TRAVEL] Tick %d: Baker travel timeout recovery - forcing RESTOCK phase" % agent.current_tick)
	production_state = ProductionState.IDLE
	phase = Phase.RESTOCK
	if _validate_target(market_location):
		agent.pending_target = market_location
	route.wait(WAIT_TIME)


func perform_market_transactions() -> void:
	if food_reserve and food_reserve.is_survival_mode:
		var bought: int = food_reserve.attempt_survival_purchase()
		if bought > 0 and not food_reserve.is_survival_mode:
			pass
		elif bought > 0 and food_reserve.is_survival_mode:
			if _validate_target(market_location):
				agent.pending_target = market_location
			route.wait(WAIT_TIME)
			return
	match phase:
		Phase.RESTOCK:
			if not market.can_producer_produce("bread"):
				hysteresis_cooldown_ticks = randi_range(5, 15)
				print("[BUGFIX] Baker BUY blocked by hysteresis → cooldown %d ticks" % hysteresis_cooldown_ticks)
				if event_bus:
					event_bus.log("[HYSTERESIS] Tick %d: Baker BUY blocked → cooldown %d ticks (bread production paused)" % [agent.current_tick, hysteresis_cooldown_ticks])
				phase = Phase.PRODUCE
				if _validate_target(bakery_location):
					agent.pending_target = bakery_location
				route.wait(WAIT_TIME)
			else:
				var current_wheat: int = inv.get_qty("wheat")
				if current_wheat < WHEAT_LOW_WATERMARK:
					var base_target: int = WHEAT_TARGET_STOCK - current_wheat
					var adjusted_target: int = base_target
					if inventory_throttle:
						var throttle_factor: float = inventory_throttle.production_throttle
						adjusted_target = max(1, int(float(base_target) * throttle_factor))
					var _cf_wbuy_snap: float = agent.get_cash()
					var _bw: int = market.sell_wheat_to_baker(agent, adjusted_target)
					agent.cashflow_today_expense += max(0.0, _cf_wbuy_snap - agent.get_cash())
					var wtr: Dictionary = market.last_trade_result
					if _bw > 0:
						agent.log_event(
							"Bought %d wheat at $%.2f each (%s)." % [_bw, wtr.get("price", 0.0), wtr.get("reason", "?")]
						)
					elif adjusted_target > 0:
						agent.log_event(
							"Could not buy wheat (wanted %d units; %s)." %
							[adjusted_target, wtr.get("reason", "unknown")]
						)
				phase = Phase.PRODUCE
				if _validate_target(bakery_location):
					agent.pending_target = bakery_location
				route.wait(WAIT_TIME)
		Phase.SELL:
			if not market.can_producer_sell("bread"):
				hysteresis_cooldown_ticks = randi_range(5, 15)
				print("[BUGFIX] Baker SELL blocked by hysteresis → cooldown %d ticks" % hysteresis_cooldown_ticks)
				if event_bus:
					event_bus.log("[HYSTERESIS] Tick %d: Baker SELL blocked → cooldown %d ticks" % [agent.current_tick, hysteresis_cooldown_ticks])
				phase = Phase.PRODUCE
				if _validate_target(bakery_location):
					agent.pending_target = bakery_location
				route.wait(WAIT_TIME)
				return
			if margin_compression and margin_compression.should_throttle_selling(BREAD_RECIPE):
				phase = Phase.PRODUCE
				if _validate_target(bakery_location):
					agent.pending_target = bakery_location
				route.wait(WAIT_TIME)
				return
			if market.is_saturated("bread"):
				if event_bus:
					var info = market.get_saturation_info("bread")
					event_bus.log("Tick %d: Baker skipping sell - market bread storage saturated (%d/%d)" % [agent.current_tick, info["current"], info["capacity"]])
				if _validate_target(market_location):
					agent.pending_target = market_location
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
				var _cf_bsale_snap: float = agent.get_cash()
				var _bs: int = market.buy_bread_from_agent(agent, sellable, min_price, false)
				agent.cashflow_today_income += max(0.0, agent.get_cash() - _cf_bsale_snap)
				var btr: Dictionary = market.last_trade_result
				if _bs > 0:
					agent.log_event(
						"Sold %d bread at $%.2f each (%s)." %
						[
							_bs,
							btr.get("price", 0.0),
							btr.get("reason", "?"),
						]
					)
				else:
					agent.log_event(
						"Could not sell bread (tried to sell %d loaves; %s)." %
						[sellable, btr.get("reason", "unknown")]
					)
			var current_wheat: int = inv.get_qty("wheat")
			if current_wheat < WHEAT_LOW_WATERMARK:
				phase = Phase.RESTOCK
				if _validate_target(market_location):
					agent.pending_target = market_location
				route.wait(WAIT_TIME)
			else:
				phase = Phase.PRODUCE
				if _validate_target(bakery_location):
					agent.pending_target = bakery_location
				route.wait(WAIT_TIME)
		Phase.PRODUCE:
			if event_bus and (agent.current_tick - last_phase_error_tick) >= phase_error_cooldown:
				event_bus.log("ERROR Tick %d: Baker at market during PRODUCE phase (state machine leak)" % agent.current_tick)
				last_phase_error_tick = agent.current_tick
			phase = Phase.RESTOCK
			if _validate_target(market_location):
				agent.pending_target = market_location
			route.wait(WAIT_TIME)


func handle_bakery_arrival() -> void:
	if not hunger.is_starving:
		phase = Phase.PRODUCE
		start_production()
	else:
		phase = Phase.RESTOCK
		if _validate_target(market_location):
			agent.pending_target = market_location
		route.wait(WAIT_TIME)


func start_production() -> void:
	if bakery_location == null or not _validate_target(bakery_location):
		if event_bus:
			event_bus.log("Tick %d: Baker start_production blocked — bakery_location null or cross-village" % agent.current_tick)
		return
	if agent.global_position.distance_to(bakery_location.global_position) > ARRIVAL_DISTANCE * 2:
		if event_bus:
			event_bus.log("Tick %d: Baker attempting production while not at bakery" % agent.current_tick)
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
		if _validate_target(market_location):
			agent.pending_target = market_location
		route.wait(WAIT_TIME)


func process_grinding(delta: float) -> void:
	if prod == null:
		production_state = ProductionState.IDLE
		phase = Phase.RESTOCK
		if _validate_target(market_location):
			agent.pending_target = market_location
		route.wait(WAIT_TIME)
		return
	process_timer -= delta
	if process_timer <= 0.0:
		if not market.can_producer_produce("bread"):
			production_state = ProductionState.IDLE
			phase = Phase.SELL if inv.get_qty("bread") >= BREAD_PRODUCTION_MIN else Phase.RESTOCK
			if _validate_target(market_location):
				agent.pending_target = market_location
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
			if _validate_target(market_location):
				agent.pending_target = market_location
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
					if _validate_target(market_location):
						agent.pending_target = market_location
					route.wait(WAIT_TIME)
			else:
				production_state = ProductionState.IDLE
				phase = Phase.SELL
				if _validate_target(market_location):
					agent.pending_target = market_location
				route.wait(WAIT_TIME)
		else:
			var ok: bool = prod.convert("wheat", "flour", units, FLOUR_PER_WHEAT)
			if not ok:
				if event_bus:
					event_bus.log("ERROR Tick %d: Baker grinding failed due to capacity/rollback safety" % agent.current_tick)
				production_state = ProductionState.IDLE
				phase = Phase.RESTOCK
				if _validate_target(market_location):
					agent.pending_target = market_location
				route.wait(WAIT_TIME)
			else:
				var flour_produced: int = units * FLOUR_PER_WHEAT
				if event_bus:
					event_bus.log("Tick %d: Baker ground %d wheat into %d flour" % [agent.current_tick, units, flour_produced])
				agent.log_event("Ground %d wheat into %d flour." % [units, flour_produced])
				var current_bread: int = inv.get_qty("bread")
				var current_flour: int = inv.get_qty("flour")
				var current_wheat: int = inv.get_qty("wheat")
				if current_bread >= BREAD_SELL_THRESHOLD:
					if market.is_saturated("bread"):
						if event_bus:
							var info = market.get_saturation_info("bread")
							event_bus.log("Tick %d: Baker pausing production - market bread saturated (%d/%d)" % [agent.current_tick, info["current"], info["capacity"]])
						production_state = ProductionState.IDLE
						phase = Phase.SELL
						if _validate_target(market_location):
							agent.pending_target = market_location
						route.wait(WAIT_TIME)
					else:
						production_state = ProductionState.IDLE
						phase = Phase.SELL
						if _validate_target(market_location):
							agent.pending_target = market_location
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
					if _validate_target(market_location):
						agent.pending_target = market_location
					route.wait(WAIT_TIME)


func process_baking(delta: float) -> void:
	if prod == null:
		production_state = ProductionState.IDLE
		phase = Phase.RESTOCK
		if _validate_target(market_location):
			agent.pending_target = market_location
		route.wait(WAIT_TIME)
		return
	process_timer -= delta
	if process_timer <= 0.0:
		if not market.can_producer_produce("bread"):
			production_state = ProductionState.IDLE
			phase = Phase.SELL if inv.get_qty("bread") >= BREAD_PRODUCTION_MIN else Phase.RESTOCK
			if _validate_target(market_location):
				agent.pending_target = market_location
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
			if _validate_target(market_location):
				agent.pending_target = market_location
			route.wait(WAIT_TIME)
			return
		if bread_produced_today >= oven_capacity_per_day:
			if event_bus:
				event_bus.log("Tick %d: Baker [CAP] oven capacity reached (%d/%d) - going to sell" % [
					agent.current_tick, bread_produced_today, oven_capacity_per_day])
			production_state = ProductionState.IDLE
			phase = Phase.SELL if inv.get_qty("bread") >= BREAD_PRODUCTION_MIN else Phase.RESTOCK
			if _validate_target(market_location):
				agent.pending_target = market_location
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
					if _validate_target(market_location):
						agent.pending_target = market_location
					route.wait(WAIT_TIME)
			else:
				production_state = ProductionState.IDLE
				phase = Phase.SELL
				if _validate_target(market_location):
					agent.pending_target = market_location
				route.wait(WAIT_TIME)
		else:
			var ok: bool = prod.convert("flour", "bread", units, BREAD_PER_FLOUR)
			if not ok:
				if event_bus:
					event_bus.log("ERROR Tick %d: Baker baking failed due to capacity/rollback safety" % agent.current_tick)
				production_state = ProductionState.IDLE
				phase = Phase.RESTOCK
				if _validate_target(market_location):
					agent.pending_target = market_location
				route.wait(WAIT_TIME)
			else:
				var _base_bread: int = units * BREAD_PER_FLOUR
				var _sk_mult: float = clamp(lerp(0.85, 1.25, agent.skill_baker), 0.85, 1.25)
				var bread_produced: int = maxi(1, roundi(float(_base_bread) * _sk_mult))
				var _diff: int = bread_produced - _base_bread
				if _diff > 0:
					inv.add("bread", _diff)
				elif _diff < 0:
					inv.remove("bread", mini(-_diff, inv.get_qty("bread")))
				bread_produced_today += bread_produced
				if event_bus:
					event_bus.log("Tick %d: Baker baked %d flour into %d bread (skill=%.2f)" % [agent.current_tick, units, bread_produced, agent.skill_baker])
				agent.log_event(
					"Baked %d loaves of bread (baker skill %.2f, yield ×%.2f)." %
					[bread_produced, agent.skill_baker, _sk_mult]
				)
				var current_bread: int = inv.get_qty("bread")
				var current_flour: int = inv.get_qty("flour")
				var current_wheat: int = inv.get_qty("wheat")
				if current_bread >= BREAD_SELL_THRESHOLD:
					if market.is_saturated("bread"):
						if event_bus:
							var info = market.get_saturation_info("bread")
							event_bus.log("Tick %d: Baker pausing production - market bread saturated (%d/%d)" % [agent.current_tick, info["current"], info["capacity"]])
						production_state = ProductionState.IDLE
						phase = Phase.SELL
						if _validate_target(market_location):
							agent.pending_target = market_location
						route.wait(WAIT_TIME)
					else:
						production_state = ProductionState.IDLE
						phase = Phase.SELL
						if _validate_target(market_location):
							agent.pending_target = market_location
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
					if _validate_target(market_location):
						agent.pending_target = market_location
					route.wait(WAIT_TIME)


func on_day_changed(_day: int) -> void:
	var _br: int = inv.get_qty("bread") if inv else 0
	var _fl: int = inv.get_qty("flour") if inv else 0
	agent.log_event(
		"End of day: has $%.0f, %d bread, %d flour in stock." % [agent.get_cash(), _br, _fl]
	)
	var cur_money: float = wallet.money if wallet else 0.0
	if day_money_start >= 0.0:
		if cur_money <= day_money_start:
			consecutive_days_negative_cashflow += 1
		else:
			consecutive_days_negative_cashflow = 0
	if wallet and maintenance_cost_per_day > 0.0:
		wallet.debit(maintenance_cost_per_day)
		agent.cashflow_today_expense += maintenance_cost_per_day
	day_money_start = wallet.money if wallet else 0.0
	bread_produced_today = 0


func _check_travel_timeout() -> void:
	if route == null:
		return
	if route.is_traveling:
		agent.travel_ticks += 1
		# Cross-village trips are long — don't abort intentional trade travel.
		if trade_route_active:
			return
		if agent.travel_ticks > agent.MAX_TRAVEL_TICKS:
			var tname: String = route.target.name if route.target else "null"
			print("[BUGFIX] Baker: travel timeout reset after %d ticks (target=%s)" % [agent.travel_ticks, tname])
			if event_bus:
				event_bus.log("[TRAVEL] Tick %d: Baker travel timeout reset (travel_ticks=%d, target=%s)" % [agent.current_tick, agent.travel_ticks, tname])
			route.stop()
			agent.travel_ticks = 0
			production_state = ProductionState.IDLE
			phase = Phase.RESTOCK
			if _validate_target(market_location):
				agent.pending_target = market_location
			route.wait(WAIT_TIME)
	else:
		agent.travel_ticks = 0


func _check_idle_and_pause_guard() -> void:
	if hunger == null or hunger.is_starving:
		agent.idle_ticks = 0
		return
	if hysteresis_cooldown_ticks > 0:
		agent.idle_ticks = 0
		return
	# Suppress idle guard during active cross-village trade trips.
	if trade_route_active:
		agent.idle_ticks = 0
		return
	# Suppress idle guard when at a foreign village (commit window running).
	# Without this the guard fires after MAX_IDLE_TICKS and forces RESTOCK +
	# routes baker to market_location (home market) before the window expires.
	if agent.current_village_ref != null and agent.current_village_ref != agent.home_village_ref:
		agent.idle_ticks = 0
		return
	if route == null:
		return
	if route.is_traveling or route.is_waiting or route.target != null or agent.pending_target != null:
		agent.idle_ticks = 0
		return
	if production_state != ProductionState.IDLE:
		agent.idle_ticks = 0
		return
	agent.idle_ticks += 1
	if agent.idle_ticks < agent.MAX_IDLE_TICKS:
		return
	agent.idle_ticks = 0
	if market and not market.can_producer_produce("bread"):
		hysteresis_cooldown_ticks = randi_range(5, 15)
		print("[BUGFIX] Baker: idle during production pause → cooldown %d ticks" % hysteresis_cooldown_ticks)
		if event_bus:
			event_bus.log("[HYSTERESIS] Tick %d: Baker idle during production pause, cooldown %d ticks" % [agent.current_tick, hysteresis_cooldown_ticks])
	else:
		print("[STATE] Baker: idle guard triggered, forcing RESTOCK")
		if event_bus:
			event_bus.log("[STATE] Tick %d: Baker idle guard triggered, forcing RESTOCK" % agent.current_tick)
		phase = Phase.RESTOCK
		if _validate_target(market_location):
			agent.pending_target = market_location
		route.wait(WAIT_TIME)


func get_status_text() -> String:
	if trade_route_active and trade_target_village != null:
		var vname: String = trade_target_village.get("village_name") if trade_target_village.get("village_name") else "?"
		if route and route.is_traveling:
			return "Trading→ %s" % vname
		return "At %s (trade)" % vname
	match production_state:
		ProductionState.GRINDING:
			return "Grinding wheat"
		ProductionState.BAKING:
			return "Baking bread"
	if bakery_location and route.target == bakery_location:
		if route.is_waiting:
			return "Waiting at Bakery"
		return "Walking to Bakery"
	elif market_location and route.target == market_location:
		if route.is_waiting:
			return "Waiting at Market"
		return "Walking to Market"
	return route.get_status_text()


# ── Inter-village trade evaluation ────────────────────────────────────────────

## Returns the WorldManager node, or null if not found.
func _get_world() -> Node:
	return Engine.get_main_loop().current_scene.get_node_or_null("World")


## Called every tick. Checks whether the baker should travel to a better bread market.
## Guards: trade must be enabled, no active trip, eval interval respected.
func _maybe_evaluate_trade(tick: int) -> void:
	# Guard: trade disabled globally.
	var world = _get_world()
	if world == null or not world.get("trade_enabled"):
		return
	# Guard: mid-travel — never evaluate while physically moving between villages.
	if trade_route_active and (route != null and route.is_traveling):
		return
	# Guard: respect evaluation cadence (silent — fires every tick, no log spam).
	if tick - agent.last_trade_eval_tick < TRADE_EVAL_INTERVAL:
		return
	# Advance the timer now so blocked logs below fire at cadence, not every tick.
	agent.last_trade_eval_tick = tick
	# Guard: sale cycle not yet complete at current destination.
	if not trade_sale_completed:
		if event_bus:
			event_bus.log("[TRADE EVAL BLOCKED] agent=Baker reason=sale_cycle_incomplete")
		return
	# Guard: commitment window — must stay at current village until tick expires.
	if tick < trade_commit_until_tick:
		if event_bus:
			event_bus.log("[TRADE EVAL BLOCKED] agent=Baker reason=commit_window")
		return

	var current_village = agent.current_village_ref
	if current_village == null or not current_village.has_method("get_trade_snapshot"):
		return

	var local_snap: Dictionary = current_village.get_trade_snapshot()
	var local_bid: float = local_snap.get("bread_price", 0.0)
	# Use the authoritative market blocked flag from the snapshot.
	var can_sell_locally: bool = not local_snap.get("bread_buy_blocked", false)
	var local_profit: float    = local_bid if can_sell_locally else 0.0

	var best_village = null
	var best_profit: float = local_profit + MIN_PROFIT_THRESHOLD

	for village in world.get_all_villages():
		if not (village and is_instance_valid(village)):
			continue
		if village == current_village:
			continue
		var snap: Dictionary = village.get_trade_snapshot()
		var foreign_bid: float = snap.get("bread_price", 0.0)
		var dist: float = agent.global_position.distance_to(village.global_position)
		var travel_cost: float = dist * TRAVEL_COST_PER_DISTANCE
		var expected_profit: float = foreign_bid - local_bid - travel_cost
		var vname: String = snap.get("village_name", village.name)
		if event_bus:
			event_bus.log("[TRADE EVAL] agent=Baker local=%.2f best=%.2f target=%s" % [local_bid, foreign_bid, vname])
		if expected_profit > best_profit or not can_sell_locally:
			best_profit = expected_profit
			best_village = village

	if best_village != null:
		_start_trade_travel(best_village, "profit")
		return

	# If currently away from home, evaluate returning.
	var home_village = agent.home_village_ref
	if current_village != home_village and home_village != null and home_village.has_method("get_trade_snapshot"):
		var home_snap: Dictionary = home_village.get_trade_snapshot()
		var home_bid: float = home_snap.get("bread_price", 0.0)
		if home_bid > local_bid + MIN_PROFIT_THRESHOLD:
			_start_trade_travel(home_village, "return")


## Initiates travel to target_village's market.
## Sets all trade state, flags intentional cross-village, and routes via market_node.
func _start_trade_travel(target_village: Node, reason: String) -> void:
	if target_village == null or not is_instance_valid(target_village):
		return
	var target_market_node: Node2D = target_village.get("market_node") as Node2D
	if target_market_node == null:
		if event_bus:
			event_bus.log("[TRADE] Baker: cannot travel to %s — market_node not found" % target_village.name)
		return

	trade_target_village = target_village
	_trade_target_market_node = target_market_node
	trade_route_active = true
	_intentional_cross_village = true
	trade_sale_completed = false  # block re-evaluation until sale attempt resolves

	var from_name: String = agent.current_village_ref.get("village_name") if agent.current_village_ref else "?"
	var to_name: String = target_village.get("village_name") if target_village.get("village_name") else target_village.name
	var is_return: bool = (target_village == agent.home_village_ref)
	if event_bus:
		event_bus.log("[TRADE DEBUG] agent=%s last_move_tick=%d current_tick=%d" % [agent.name, _last_trade_move_tick, agent.current_tick])
	_last_trade_move_tick = agent.current_tick
	var depart_tag: String = "[TRADE RETURN DEPART]" if is_return else "[TRADE DEPART]"
	if event_bus:
		event_bus.log("%s agent=Baker from=%s to=%s reason=%s" % [depart_tag, from_name, to_name, reason])
	else:
		print("%s agent=Baker from=%s to=%s reason=%s" % [depart_tag, from_name, to_name, reason])
	# Emit departure signal. current_village_ref is still ORIGIN here.
	if is_return:
		trade_return_departed.emit(agent.current_village_ref, target_village)
	else:
		trade_departed.emit(agent.current_village_ref, target_village)

	# Stop current activity and route to the target village's market.
	production_state = ProductionState.IDLE
	agent.pending_target = null  # prevent post-wait re-routing to home village nodes
	route.stop()
	route.set_target(target_market_node)


## Sets the commitment window so baker cannot re-evaluate trade until
## current_tick + TRADE_MIN_STAY_TICKS. Emits [TRADE COMMIT] log.
func _begin_trade_commit_window() -> void:
	trade_commit_until_tick = agent.current_tick + TRADE_MIN_STAY_TICKS
	var vid: String = agent.current_village_ref.get("village_name") if agent.current_village_ref else "?"
	if event_bus:
		event_bus.log("[TRADE COMMIT] agent=Baker village=%s until_tick=%d" % [vid, trade_commit_until_tick])


## Called when baker arrives at the trade destination (foreign village or home on return).
## Handles: switching current_village_ref, rebinding components, selling bread,
## and resuming normal operation on home return.
func _on_trade_arrival() -> void:
	_intentional_cross_village = false

	var arrived_village = trade_target_village
	var is_home_return: bool = (arrived_village == agent.home_village_ref)

	# Switch village context: ONLY point where current_village_ref may change.
	agent.current_village_ref = arrived_village
	var vname_arrive: String = arrived_village.get("village_name") if arrived_village.get("village_name") else arrived_village.name
	var arrived_market: Market = arrived_village.get("market") as Market
	var arrived_event_bus: EventBus = arrived_village.get("event_bus") as EventBus
	if arrived_market:
		market = arrived_market
		agent.market = arrived_market
	if arrived_event_bus:
		event_bus = arrived_event_bus
		agent.event_bus = arrived_event_bus

	# Rebind all sub-components so their market/event_bus refs stay consistent.
	if profit and arrived_market and arrived_event_bus:
		profit.bind(arrived_market, arrived_event_bus, get_display_name())
	if margin_compression and arrived_market and arrived_event_bus:
		margin_compression.bind(arrived_market, arrived_event_bus, get_display_name())
	if inventory_throttle and arrived_market and arrived_event_bus:
		inventory_throttle.bind(arrived_market, arrived_event_bus, get_display_name())
	if food_reserve and arrived_market:
		food_reserve.bind(inv, hunger, arrived_market, wallet, arrived_event_bus, get_display_name())

	# Clear trip state now that we've arrived.
	trade_target_village = null
	_trade_target_market_node = null
	trade_route_active = false

	if is_home_return:
		# ── Home return arrival ──────────────────────────────────────────────
		if event_bus:
			event_bus.log("[TRADE RETURN ARRIVE] agent=Baker village=%s" % vname_arrive)
		else:
			print("[TRADE RETURN ARRIVE] agent=Baker village=%s" % vname_arrive)
		trade_return_arrived.emit(arrived_village)
		# Returned home — restore market_location ref and resume normal cycle.
		var home_market_node: Node2D = agent.home_village_ref.get("market_node") as Node2D
		if home_market_node:
			market_location = home_market_node
		# Mark cycle complete and start commitment window so we don't immediately leave again.
		trade_sale_completed = true
		_begin_trade_commit_window()
		production_state = ProductionState.IDLE
		phase = Phase.SELL if inv.get_qty("bread") >= BREAD_PRODUCTION_MIN else Phase.RESTOCK
		if _validate_target(market_location):
			agent.pending_target = market_location
		route.wait(WAIT_TIME)
	else:
		# ── Foreign village arrival (migration complete) ──────────────────────
		trade_arrival_count += 1
		if event_bus:
			event_bus.log("[TRADE ARRIVE] agent=Baker village=%s arrival_count=%d" % [vname_arrive, trade_arrival_count])
		else:
			print("[TRADE ARRIVE] agent=Baker village=%s arrival_count=%d" % [vname_arrive, trade_arrival_count])
		trade_arrived.emit(arrived_village)
		# Arrived at foreign village — attempt to sell all available bread.
		var sellable: int = inv.get_qty("bread")
		var sold: int = 0
		if sellable > 0 and arrived_market != null:
			var snap_before: float = agent.get_cash()
			sold = arrived_market.buy_bread_from_agent(agent, sellable, 0.0, false)
			var earned: float = agent.get_cash() - snap_before
			if event_bus:
				event_bus.log("[TRADE SALE COMPLETE] agent=Baker village=%s qty=%d profit=+%.1f" % [vname_arrive, sold, earned])
			agent.log_event("Cross-village sale: sold %d bread at %s (+$%.1f)." % [sold, vname_arrive, earned])
		elif event_bus:
			event_bus.log("[TRADE SALE COMPLETE] agent=Baker village=%s qty=%d profit=+0.0" % [vname_arrive, 0])
		# Sale attempt is now resolved (success, partial, or blocked) — mark complete.
		trade_sale_completed = true
		# Start commitment window so baker stays long enough for the market to react.
		_begin_trade_commit_window()
		# Explicitly clear route state before waiting (ensures is_traveling=false).
		route.stop()
		# Wait at destination — next trade eval tick will decide whether to return.
		route.wait(WAIT_TIME)
