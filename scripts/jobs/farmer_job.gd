extends JobBase
class_name FarmerJob

## Farmer job component - plants seeds, harvests wheat, sells at market, buys bread.
## Movement is handled by RouteRunner component.
## All role-specific logic extracted from Farmer agent.

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

# Inter-village trade constants
const TRADE_EVAL_INTERVAL: int = 10
const MIN_PROFIT_THRESHOLD: float = 0.3
const TRAVEL_COST_PER_DISTANCE: float = 0.0002
## Ticks an agent must remain in the arrived village before re-evaluating trade.
## Prevents immediate ping-pong after arrival.
const TRADE_MIN_STAY_TICKS: int = 200

const WHEAT_RECIPE: Dictionary = {
	"output_good": "wheat",
	"output_quantity": 10,
	"inputs": {"seeds": 5}
}

# Producer mechanics (role-specific, resolved from agent in activate)
var profit: ProductionProfitability = null
var inventory_throttle: InventoryThrottle = null

# Capital constraints (B)
var field_work_capacity_per_day: int = 3
var fields_worked_today: int = 0
var maintenance_cost_per_day: float = 0.2
var consecutive_days_negative_cashflow: int = 0
var day_money_start: float = -1.0

# Hysteresis cooldown
var hysteresis_cooldown_ticks: int = 0

var _initialized: bool = false
var warned_no_field_today: bool = false

# Inter-village trade state
var trade_route_active: bool = false
var trade_target_village: Node = null
var _trade_target_market_node: Node2D = null

## Tick at which the commitment window expires and re-evaluation is allowed.
var trade_commit_until_tick: int = 0
## True once the sale attempt at the current destination has completed.
## Reset to false when a new trip begins; set to true after _on_trade_arrival() sells.
var trade_sale_completed: bool = true
## Tick of the last cross-village move. Used for [TRADE DEBUG] ping-pong detection.
var _last_trade_move_tick: int = -1


func get_display_name() -> String:
	return "Farmer"


func get_job_inspector_data() -> Dictionary:
	var d: Dictionary = {}
	d["role"] = "Farmer"
	var state_str := "idle"
	if trade_route_active and trade_target_village != null:
		state_str = "trade→" + trade_target_village.village_name
	elif route:
		if route.is_traveling:
			state_str = "traveling→" + (route.target.name if route.target else "?")
		elif agent.pending_target != null:
			state_str = "waiting→" + agent.pending_target.name
	d["state"] = state_str
	d["trade_active"] = trade_route_active
	d["trade_target"] = trade_target_village.village_name if trade_target_village else ""
	d["seeds"] = inv.get_qty("seeds") if inv else 0
	d["wheat"] = inv.get_qty("wheat") if inv else 0
	d["fields"] = fields.size()
	d["neg_cashflow_days"] = consecutive_days_negative_cashflow
	d["prod_mult"] = clamp(lerp(0.85, 1.25, agent.skill_farmer), 0.85, 1.25)
	return d


func set_tick(t: int) -> void:
	if profit:
		profit.set_tick(t)
	if inventory_throttle:
		inventory_throttle.set_tick(t)
		inventory_throttle.calculate_throttle(WHEAT_RECIPE)
	if food_reserve:
		food_reserve.set_tick(t)
		food_reserve.check_survival_mode()
		food_reserve.update_survival_override()
	if t == 0 and event_bus:
		event_bus.log("Tick 0: Farmer starting food=%d" % inv.get_qty("bread"))
	if hysteresis_cooldown_ticks > 0:
		hysteresis_cooldown_ticks -= 1
	_check_travel_timeout()
	_check_idle_guard()
	_maybe_evaluate_trade(t)


const STARTING_CASH: float = 500.0

func activate() -> void:
	if wallet and wallet.money <= 0.0:
		wallet.credit(STARTING_CASH)
	if inv:
		inv.items = {"seeds": 50, "wheat": 0, "bread": 2}
	profit = agent.get_node_or_null("ProductionProfitability") as ProductionProfitability
	inventory_throttle = agent.get_node_or_null("InventoryThrottle") as InventoryThrottle
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


func set_route_nodes(house: Node2D, market_pos: Node2D) -> void:
	house_node = house
	market_node = market_pos
	if profit and market and event_bus:
		profit.bind(market, event_bus, get_display_name())
	if inventory_throttle and market and event_bus:
		inventory_throttle.bind(market, event_bus, get_display_name())
	_rebuild_route()


func _rebuild_route() -> void:
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
		_initialized = true
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


func clear_fields_for_removal() -> void:
	fields.clear()
	field_nodes.clear()


func get_field_count() -> int:
	return fields.size()


func physics_tick(_delta: float) -> void:
	if hunger.is_starving:
		route.stop()


func _on_arrived(t: Node2D) -> void:
	agent.travel_ticks = 0
	agent.idle_ticks = 0
	if trade_route_active and t == _trade_target_market_node:
		_on_trade_arrival()
		if route_targets.size() > 0:
			agent.pending_target = get_next_target()
		route.wait(WAIT_TIME)
		return
	handle_arrival(t)
	agent.pending_target = get_next_target()
	route.wait(WAIT_TIME)


func _on_wait_finished() -> void:
	if agent.pending_target != null:
		route.set_target(agent.pending_target)
		agent.pending_target = null


func get_next_target() -> Node2D:
	route_index = (route_index + 1) % route_targets.size()
	return route_targets[route_index]


func handle_arrival(t: Node2D) -> void:
	if t == house_node:
		handle_house_arrival()
	elif t == market_node:
		handle_market_arrival()
	else:
		var idx = field_nodes.find(t)
		if idx != -1:
			handle_field_arrival(fields[idx], t.name)


func handle_house_arrival() -> void:
	pass


func handle_field_arrival(field: FieldPlot, field_name: String) -> void:
	if fields.size() == 0:
		if not warned_no_field_today:
			print("[ERROR] Farmer_%s has no fields; skipping production" % agent.name)
			warned_no_field_today = true
		return
	if fields_worked_today >= field_work_capacity_per_day:
		if event_bus:
			event_bus.log("Tick %d: Farmer [CAP] skipping %s - daily field capacity reached (%d/%d)" % [
				agent.current_tick, field_name, fields_worked_today, field_work_capacity_per_day])
		return
	fields_worked_today += 1
	if field.is_mature():
		var harvest_result = field.harvest()
		var _sk_mult: float = clamp(lerp(0.85, 1.25, agent.skill_farmer), 0.85, 1.25)
		var actual_wheat: int = maxi(1, roundi(float(harvest_result.wheat) * _sk_mult))
		var actual_seeds: int = maxi(0, roundi(float(harvest_result.seeds) * _sk_mult))
		inv.add("wheat", actual_wheat)
		inv.add("seeds", actual_seeds)
		if event_bus:
			event_bus.log("Tick %d: Farmer harvested %s (+%d wheat, +%d seeds, skill=%.2f)" % [agent.current_tick, field_name, actual_wheat, actual_seeds, agent.skill_farmer])
		agent.log_event(
			"Harvested %d wheat and %d seeds (farmer skill %.2f, yield ×%.2f)." %
			[actual_wheat, actual_seeds, agent.skill_farmer, _sk_mult]
		)
	elif field.state == FieldPlot.State.EMPTY and inv.get_qty("seeds") >= 5:
		if not market.can_producer_produce("wheat"):
			if event_bus:
				event_bus.log("Tick %d: Farmer SKIPPED planting %s (wheat production paused by hysteresis)" % [agent.current_tick, field_name])
			return
		var should_plant: bool = true
		if inventory_throttle:
			var throttle_factor: float = inventory_throttle.production_throttle
			should_plant = randf() < throttle_factor
		if should_plant and field.plant():
			inv.remove("seeds", 5)
			if event_bus:
				event_bus.log("Tick %d: Farmer planted %s (-5 seeds)" % [agent.current_tick, field_name])
			agent.log_event("Planted a field (spent 5 seeds).")
		elif inventory_throttle and not should_plant:
			if event_bus:
				event_bus.log("Tick %d: Farmer SKIPPED planting %s (throttle %.0f%%)" % [agent.current_tick, field_name, inventory_throttle.production_throttle * 100.0])


func handle_market_arrival() -> void:
	if food_reserve and food_reserve.is_survival_mode:
		var _bought: int = food_reserve.attempt_survival_purchase()
	if inv.get_qty("wheat") > 0:
		var min_price: float = 0.0
		if profit:
			min_price = profit.get_min_acceptable_price(WHEAT_RECIPE)
		else:
			min_price = market.SEED_PRICE * 1.5
		var _cf_wheat_snap: float = agent.get_cash()
		var _ws: int = market.buy_wheat_from_farmer(agent, min_price)
		agent.cashflow_today_income += max(0.0, agent.get_cash() - _cf_wheat_snap)
		if _ws > 0:
			var wtr: Dictionary = market.last_trade_result
			agent.log_event(
				"Sold %d wheat at $%.2f each (%s)." % [_ws, wtr.get("price", 0.0), wtr.get("reason", "?")]
			)
	if inv.get_qty("seeds") < 20:
		var _cf_seeds_snap: float = agent.get_cash()
		market.sell_seeds_to_farmer(agent)
		agent.cashflow_today_expense += max(0.0, _cf_seeds_snap - agent.get_cash())
	var needed: int = food_stockpile.needed_to_reach_target()
	if needed > 0:
		var bought: int = market.sell_bread_to_agent(agent, needed)
		var btr: Dictionary = market.last_trade_result
		if bought > 0:
			agent.cashflow_today_expense += float(bought) * (market.bread_price if market else 0.0)
		inv.add("bread", bought)
		if bought > 0 and event_bus:
			event_bus.log("Tick %d: Farmer bought %d bread for food buffer" % [agent.current_tick, bought])
		if bought == 0:
			agent.log_event(
				"Could not buy bread (wanted %d loaves; market had %d; %s)." %
				[needed, btr.get("market_bread", -1), btr.get("reason", "unknown")]
			)
		else:
			agent.log_event(
				"Bought %d of %d loaves of bread at $%.2f each (%s)." %
				[bought, needed, btr.get("price", 0.0), btr.get("reason", "?")]
			)


func on_day_changed(_day: int) -> void:
	var _w: float = inv.get_qty("wheat") if inv else 0
	var _b: int   = inv.get_qty("bread") if inv else 0
	agent.log_event(
		"End of day: has $%.0f, %d wheat in stock, %d bread in stock." % [agent.get_cash(), _w, _b]
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
	fields_worked_today = 0
	warned_no_field_today = false


func _on_travel_timeout(_t: Node2D) -> void:
	agent.travel_ticks = 0
	if trade_route_active:
		trade_route_active = false
		trade_target_village = null
		_trade_target_market_node = null
		trade_sale_completed = true
		print("[BUGFIX] Farmer: trade travel timed out — trade state reset")
	print("[BUGFIX] Farmer: travel timeout, restarting route")
	if event_bus:
		event_bus.log("[TRAVEL] Tick %d: Farmer travel timeout recovery - restarting route" % agent.current_tick)
	agent.pending_target = route_targets[route_index] if route_targets.size() > 0 else null
	if agent.pending_target:
		route.wait(WAIT_TIME)


func _check_travel_timeout() -> void:
	if route == null:
		return
	if route.is_traveling:
		agent.travel_ticks += 1
		# Cross-village trade trips are long — don't abort intentional trade travel.
		if trade_route_active:
			return
		if agent.travel_ticks > agent.MAX_TRAVEL_TICKS:
			var tname: String = route.target.name if route.target else "null"
			print("[BUGFIX] Farmer: travel timeout reset after %d ticks (target=%s)" % [agent.travel_ticks, tname])
			if event_bus:
				event_bus.log("[TRAVEL] Tick %d: Farmer travel timeout reset (travel_ticks=%d, target=%s)" % [agent.current_tick, agent.travel_ticks, tname])
			route.stop()
			agent.travel_ticks = 0
			agent.pending_target = route_targets[route_index] if route_targets.size() > 0 else null
			if agent.pending_target:
				route.wait(WAIT_TIME)
	else:
		agent.travel_ticks = 0


func _check_idle_guard() -> void:
	if hunger == null or hunger.is_starving:
		agent.idle_ticks = 0
		return
	if hysteresis_cooldown_ticks > 0:
		agent.idle_ticks = 0
		return
	if trade_route_active:
		agent.idle_ticks = 0
		return
	if route == null:
		return
	if route.is_traveling or route.is_waiting or route.target != null or agent.pending_target != null:
		agent.idle_ticks = 0
		return
	agent.idle_ticks += 1
	if agent.idle_ticks < agent.MAX_IDLE_TICKS:
		return
	agent.idle_ticks = 0
	print("[BUGFIX] Farmer: idle guard triggered, restarting route")
	if event_bus:
		event_bus.log("[STATE] Tick %d: Farmer idle guard triggered, restarting route" % agent.current_tick)
	if route_targets.size() > 0:
		route.set_target(route_targets[route_index])


func get_status_text() -> String:
	if hunger.is_starving:
		return "STARVING (inactive)"
	if trade_route_active and trade_target_village != null:
		return "Trading→" + trade_target_village.village_name
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


# ==============================================================================
#  Inter-village trade logic
# ==============================================================================

func _get_world() -> Node:
	return Engine.get_main_loop().current_scene.get_node_or_null('World')


## Returns true when conditions allow a new trade evaluation.
## trade_route_active is checked separately (before interval) so not re-checked here.
func _can_run_trade_evaluation(tick: int) -> bool:
	if not trade_sale_completed:
		if event_bus:
			event_bus.log("[TRADE EVAL BLOCKED] agent=Farmer reason=sale_cycle_incomplete")
		return false
	if tick < trade_commit_until_tick:
		if event_bus:
			event_bus.log("[TRADE EVAL BLOCKED] agent=Farmer reason=commit_window")
		return false
	return true


## Sets the commitment window after arriving at a village.
## Prevents re-evaluation for TRADE_MIN_STAY_TICKS ticks.
func _begin_trade_commit_window(tick: int, village_name: String) -> void:
	trade_commit_until_tick = tick + TRADE_MIN_STAY_TICKS
	if event_bus:
		event_bus.log("[TRADE COMMIT] agent=Farmer village=%s until_tick=%d" % [village_name, trade_commit_until_tick])


## Marks the sale cycle as complete and logs accordingly.
func _mark_trade_sale_completed(village_name: String, qty: int) -> void:
	trade_sale_completed = true
	if event_bus:
		event_bus.log("[TRADE SALE COMPLETE] agent=Farmer village=%s qty=%d" % [village_name, qty])


func _maybe_evaluate_trade(tick: int) -> void:
	var world = _get_world()
	if world == null or not world.trade_enabled:
		return
	if agent.current_village_ref == null or agent.home_village_ref == null:
		return
	if trade_route_active:
		return
	if tick - agent.last_trade_eval_tick < TRADE_EVAL_INTERVAL:
		return
	# Update tick before gate so blocked logs fire at most once per TRADE_EVAL_INTERVAL
	agent.last_trade_eval_tick = tick
	if not _can_run_trade_evaluation(tick):
		return

	var local_snap: Dictionary = agent.current_village_ref.get_trade_snapshot()
	if local_snap.is_empty():
		return
	var local_price: float = local_snap['wheat_price']
	# If local market won't accept wheat at all, treat local profit as worthless
	var local_profit: float = local_price if (market == null or not market.is_market_buy_blocked('wheat')) else -INF

	var best_village: Node = null
	var best_profit: float = local_profit + MIN_PROFIT_THRESHOLD

	for village in world.get_all_villages():
		if not is_instance_valid(village) or village == agent.current_village_ref:
			continue
		var snap: Dictionary = village.get_trade_snapshot()
		if snap.is_empty():
			continue
		var dist: float = local_snap['world_pos'].distance_to(snap['world_pos'])
		var travel_cost: float = dist * TRAVEL_COST_PER_DISTANCE
		var expected_profit: float = snap['wheat_price'] - local_price - travel_cost
		print('[TRADE EVAL] agent=Farmer local=%.2f best=%.2f target=%s' % [local_price, snap['wheat_price'], village.village_name])
		if expected_profit > best_profit:
			best_profit = expected_profit
			best_village = village

	if best_village != null:
		_start_travel_to(best_village, 'profit')
	elif agent.current_village_ref != agent.home_village_ref:
		# Check if home is now more profitable — trigger return
		var home_snap: Dictionary = agent.home_village_ref.get_trade_snapshot()
		if not home_snap.is_empty():
			var home_profit: float = home_snap['wheat_price']
			if home_profit > local_profit + MIN_PROFIT_THRESHOLD:
				print('[TRADE RETURN] agent=Farmer returning to %s reason=price_shift' % agent.home_village_ref.village_name)
				_start_travel_to(agent.home_village_ref, 'price_shift')


func _start_travel_to(target_village: Node, reason: String) -> void:
	if trade_route_active and trade_target_village == target_village:
		return  # Already heading there
	if agent.current_village_ref == null:
		return
	var target_mkt_node: Node2D = target_village.get('market_node') as Node2D
	if target_mkt_node == null:
		push_warning("FarmerJob: trade target '%s' has no market_node — skipping" % target_village.village_name)
		return
	trade_target_village = target_village
	_trade_target_market_node = target_mkt_node
	trade_route_active = true
	trade_sale_completed = false
	print('[TRADE DEBUG] agent=%s last_move_tick=%d current_tick=%d' % [
		agent.name, _last_trade_move_tick, agent.current_tick])
	_last_trade_move_tick = agent.current_tick
	print('[TRADE MOVE] agent=Farmer from=%s to=%s reason=%s' % [
		agent.current_village_ref.village_name, target_village.village_name, reason])
	agent.pending_target = null
	route.set_target(_trade_target_market_node)


func _on_trade_arrival() -> void:
	var arrived_village: Node = trade_target_village
	var arrived_market_node: Node2D = _trade_target_market_node

	# Clear trade state before switching context
	trade_route_active = false
	trade_target_village = null
	_trade_target_market_node = null

	# Switch village context: all further market ops use the new village
	agent.current_village_ref = arrived_village
	market = arrived_village.market
	agent.market = arrived_village.market
	market_node = arrived_market_node

	# Rebind profit/throttle/food_reserve calculators to new market
	if profit and market and event_bus:
		profit.bind(market, event_bus, get_display_name())
	if inventory_throttle and market and event_bus:
		inventory_throttle.bind(market, event_bus, get_display_name())
	if food_reserve and market and event_bus:
		food_reserve.bind(inv, hunger, market, wallet, event_bus, get_display_name())

	# Sell all wheat at new market (sale attempt always completes — full, partial, or zero)
	var sold_qty: int = 0
	if inv.get_qty("wheat") > 0:
		var min_price: float = 0.0
		if profit:
			min_price = profit.get_min_acceptable_price(WHEAT_RECIPE)
		var _cf_snap: float = agent.get_cash()
		sold_qty = market.buy_wheat_from_farmer(agent, min_price)
		agent.cashflow_today_income += max(0.0, agent.get_cash() - _cf_snap)
		var trade_profit: float = max(0.0, agent.get_cash() - _cf_snap)
		print('[TRADE SALE] agent=Farmer village=%s qty=%d profit=+%.1f' % [
			arrived_village.village_name, sold_qty, trade_profit])
	# Mark cycle complete and open commitment window regardless of sale outcome
	_mark_trade_sale_completed(arrived_village.village_name, sold_qty)
	_begin_trade_commit_window(agent.current_tick, arrived_village.village_name)
