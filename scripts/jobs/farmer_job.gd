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


func get_display_name() -> String:
	return "Farmer"


func get_job_inspector_data() -> Dictionary:
	var d: Dictionary = {}
	d["role"] = "Farmer"
	var state_str := "idle"
	if route:
		if route.is_traveling:
			state_str = "traveling→" + (route.target.name if route.target else "?")
		elif agent.pending_target != null:
			state_str = "waiting→" + agent.pending_target.name
	d["state"] = state_str
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


func get_field_count() -> int:
	return fields.size()


func physics_tick(_delta: float) -> void:
	if hunger.is_starving:
		route.stop()


func _on_arrived(t: Node2D) -> void:
	agent.travel_ticks = 0
	agent.idle_ticks = 0
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
		agent.log_event("Harvested %d wht + %d seeds (sk=%.2f ×%.2f)" % [actual_wheat, actual_seeds, agent.skill_farmer, _sk_mult])
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
			agent.log_event("Planted field")
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
			agent.log_event("Sold %d wheat @$%.2f (%s)" % [_ws, wtr.get("price", 0.0), wtr.get("reason", "?")])
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
			agent.log_event("Bread buy FAILED: wanted=%d, mkt=%d, reason=%s" % [needed, btr.get("market_bread", -1), btr.get("reason", "unknown")])
		else:
			agent.log_event("Bread buy: got=%d/%d @$%.2f (%s)" % [bought, needed, btr.get("price", 0.0), btr.get("reason", "?")])


func on_day_changed(_day: int) -> void:
	var _w: float = inv.get_qty("wheat") if inv else 0
	var _b: int   = inv.get_qty("bread") if inv else 0
	agent.log_event("── $%.0f  wht=%d  br=%d" % [agent.get_cash(), _w, _b])
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
