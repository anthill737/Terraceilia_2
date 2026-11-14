extends HouseholdJob
class_name SmithJob

## Smith (docs/SMITH.md): walks to the smithy, makes tools and puts them out at the market.
## Farms, bakeries and lumber yards make more with tools and wear them out, so a shop's upkeep
## is now tools bought from the smith instead of a daily charge paid to nobody.
##
## The forge burns firewood: one log for every TOOLS_PER_LOG tools, bought at the market like
## anyone's. Hands and skill raise what a smithy makes the way they do in any shop. It lives
## like a household (buys bread, keeps a hearth) and so extends HouseholdJob. The price it will
## sell at covers its fuel, its hands' wages and its own keep, plus the same 25% margin the
## other trades ask.

const OWNER_CASH: float = 150.0      # a business owner's purse
const TOOLS_PER_DAY: int = 6         # one person's day at the anvil
const TOOLS_PER_LOG: int = 3         # the forge burns one log for every three tools
const FORGE_LOGS: int = 3            # logs kept by for the forge, beyond the hearth's
const MIN_MARGIN: float = 0.25

var smithy_location: Node2D = null
var tools_made_today: int = 0
var forge_heat: int = 0              # tools the log now in the forge can still make
var consecutive_days_negative_cashflow: int = 0
var day_money_start: float = -1.0
var cost_per_unit: float = 1.5
## Kept for the code that reads every shop's upkeep; a smithy has none of its own.
var maintenance_cost_per_day: float = 0.0


func get_display_name() -> String:
	return "Smith"


func get_job_inspector_data() -> Dictionary:
	var d: Dictionary = super.get_job_inspector_data()
	d["role"] = "Smith"
	d["tools_made_today"] = tools_made_today
	d["cost_per_unit"] = snappedf(cost_per_unit, 0.01)
	d["prod_mult"] = LaborMarket.hand_mult(agent)
	return d


func activate() -> void:
	if wallet and wallet.money <= 0.0:
		wallet.credit(Tuning.f("owner_start_coins", OWNER_CASH))
		Village.note_brought(agent, Tuning.f("owner_start_coins", OWNER_CASH))
	super.activate()
	if inv:
		inv.items = {"bread": 2, "firewood": 6, "tools": 0}
	_update_cost()


func _capacity() -> int:
	var own: float = SkillSet.factor(agent.skill_in("Smith")) if Tuning.on("worker_skill", true) else 1.0
	return roundi(float(Tuning.i("smith_tools_per_day", TOOLS_PER_DAY)) * own * LaborMarket.hand_mult(agent))


func _spare() -> int:
	return inv.get_qty("tools") if inv else 0


func _min_price() -> float:
	return cost_per_unit * (1.0 + MIN_MARGIN)


## True when the market's stock of tools is not already over its target and it pays enough.
func _market_wants() -> bool:
	if market == null or not market.has_good("tools"):
		return false
	if float(market.good_stock("tools")) > float(market.good_target("tools")) * (1.0 + float(market.TARGET_BAND_PCT)):
		return false
	return market.good_bid("tools") >= _min_price()


func _has_fuel() -> bool:
	return forge_heat > 0 or (inv != null and inv.get_qty("firewood") > HOME_FIREWOOD)


func _wants_to_forge() -> bool:
	if smithy_location == null or inv == null:
		return false
	if tools_made_today >= _capacity():
		return false
	return _spare() < _capacity() and _market_wants() and _has_fuel()


func _forge() -> void:
	var n: int = mini(_capacity() - tools_made_today, _capacity() - _spare())
	if n <= 0 or not _market_wants():
		return
	while forge_heat < n and inv.get_qty("firewood") > HOME_FIREWOOD:   # the hearth's logs stay
		inv.remove("firewood", 1)
		forge_heat += TOOLS_PER_LOG
	n = mini(n, forge_heat)
	if n <= 0:
		return
	forge_heat -= n
	inv.add("tools", n)
	tools_made_today += n
	agent.log_event("Made %d tools at the smithy." % n)


func _sell_spare() -> void:
	var spare: int = _spare()
	if spare <= 0 or market == null or not market.has_good("tools"):
		return
	var bid: float = market.good_bid("tools")
	var put: int = market.put_out(agent, "tools", spare, _min_price())
	if put > 0:
		agent.log_event("Put %d tools out at the market at $%.2f each." % [put, bid])
		if event_bus:
			event_bus.emit_log("Tick %d: %s put out %d tools at $%.2f" % [agent.current_tick, agent.name, put, bid])


func _on_arrived(t: Node2D) -> void:
	agent.travel_ticks = 0
	agent.idle_ticks = 0
	if smithy_location != null and t == smithy_location:
		_forge()
		agent.pending_target = market_location if (_spare() > 0 or needs_food_trip() or not _has_fuel()) else home_location
	elif t == market_location:
		_sell_spare()
		buy_firewood_to(HOME_FIREWOOD + FORGE_LOGS)
		attempt_buy_bread()
		phase = Phase.AT_MARKET
		agent.pending_target = home_location
	else:
		phase = Phase.AT_HOME
		if _wants_to_forge():
			agent.pending_target = smithy_location
		elif needs_food_trip() or (_spare() > 0 and _market_wants()) or (not _has_fuel() and tools_made_today < _capacity()):
			agent.pending_target = market_location
		else:
			agent.pending_target = home_location
	route.wait(WAIT_TIME)


func _on_wait_finished() -> void:
	if agent.pending_target == null:
		return
	var t: Node2D = agent.pending_target
	agent.pending_target = null
	if t == market_location:
		last_market_trip_tick = agent.current_tick
	route.set_target(t)


func get_status_text() -> String:
	if smithy_location != null and route.target == smithy_location:
		return "Working at the anvil" if route.is_waiting else "Going to the smithy"
	return super.get_status_text()


func on_day_changed(day: int) -> void:
	super.on_day_changed(day)
	if wallet:
		if day_money_start >= 0.0:
			if wallet.money < day_money_start - 0.01:
				consecutive_days_negative_cashflow += 1
			else:
				consecutive_days_negative_cashflow = 0
		day_money_start = wallet.money
	set_meta("output_ema", 0.3 * float(tools_made_today) + 0.7 * float(get_meta("output_ema", float(tools_made_today))))
	LaborMarket.note_day_made(self, float(tools_made_today))
	tools_made_today = 0
	_update_cost()


## What a tool costs to make: the forge's firewood, the hands' wages and the smith's own keep
## (food, firewood, rent and clothes), spread over what today's crew will make (the morning
## price, LaborMarket.costing_volume).
func _update_cost() -> void:
	if market == null:
		return
	var can: float = float(_capacity())
	var per_day: float = LaborMarket.costing_volume(self, can, LaborMarket.COSTING_FLOOR * can)
	var keep: float = LaborMarket.keep_of(self)   # what it costs the owner to live: food, firewood, rent, clothes
	cost_per_unit = (float(LaborMarket.hands_of(agent)) * LaborMarket.wage_of(agent) + keep) / maxf(1.0, per_day) \
			+ float(market.firewood_price) / float(TOOLS_PER_LOG)
