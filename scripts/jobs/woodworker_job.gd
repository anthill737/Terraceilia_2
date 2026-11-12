extends HouseholdJob
class_name WoodworkerJob

## Woodworker (batch 3): walks to the lumber yard, cuts firewood and sells it at the market.
## The yard's wood is free and never runs out; the woodworker's day is the limit. Hands raise
## that limit the way they do for a baker (half again, then a quarter more).
##
## It lives like a household (buys bread, keeps a hearth) and so extends HouseholdJob. Because
## the wood itself costs nothing, the price it will sell at counts the woodworker's own keep
## (a loaf and a firewood a day) as a cost, plus hands' wages and upkeep, plus the same 25%
## margin the other trades ask. Without that, firewood would sit on its price floor.

const OWNER_CASH: float = 150.0      # a business owner's purse
const FIREWOOD_PER_DAY: int = 12     # one person's day of cutting; 18 and 21 with hands
const MIN_MARGIN: float = 0.25

var yard_location: Node2D = null
var firewood_made_today: int = 0
var maintenance_cost_per_day: float:
	get: return Tuning.f("upkeep_woodworker", 0.2)
var consecutive_days_negative_cashflow: int = 0
var day_money_start: float = -1.0
var cost_per_unit: float = 0.7


func get_display_name() -> String:
	return "Woodworker"


func get_job_inspector_data() -> Dictionary:
	var d: Dictionary = super.get_job_inspector_data()
	d["role"] = "Woodworker"
	d["firewood_made_today"] = firewood_made_today
	d["cost_per_unit"] = snappedf(cost_per_unit, 0.01)
	d["prod_mult"] = LaborMarket.hand_mult(agent)
	return d


func activate() -> void:
	if wallet and wallet.money <= 0.0:
		wallet.credit(Tuning.f("owner_start_coins", OWNER_CASH))
		Village.note_brought(agent, Tuning.f("owner_start_coins", OWNER_CASH))
	super.activate()
	if inv:
		inv.items = {"bread": 2, "firewood": 6}
	_update_cost()


func _capacity() -> int:
	return roundi(float(Tuning.i("woodworker_logs_per_day", FIREWOOD_PER_DAY)) * LaborMarket.hand_mult(agent))


## Firewood beyond what the woodworker keeps for its own hearth.
func _spare() -> int:
	return maxi(0, inv.get_qty("firewood") - HOME_FIREWOOD) if inv else 0


func _min_price() -> float:
	return cost_per_unit * (1.0 + MIN_MARGIN)


## True when the market's pile is not already over its target and it pays enough.
func _market_wants() -> bool:
	if market == null:
		return false
	if float(market.firewood) > float(market.firewood_target) * (1.0 + float(market.TARGET_BAND_PCT)):
		return false
	return market.firewood_bid() >= _min_price()


func _wants_to_chop() -> bool:
	if yard_location == null or inv == null:
		return false
	if firewood_made_today >= _capacity():
		return false
	if inv.get_qty("firewood") <= 1:
		return true   # its own hearth comes first
	return _spare() < _capacity() and _market_wants()


## The woodworker never buys firewood: it cuts its own.
func needs_firewood() -> bool:
	return false


func _chop() -> void:
	var room: int = _capacity() - firewood_made_today
	var n: int = 0
	if _market_wants():
		n = mini(room, _capacity() - _spare())
	n = maxi(n, mini(room, HOME_FIREWOOD + 1 - inv.get_qty("firewood")))
	if n <= 0:
		return
	inv.items["firewood"] = inv.get_qty("firewood") + n
	firewood_made_today += n
	agent.log_event("Cut %d firewood at the lumber yard." % n)


func _sell_spare() -> void:
	var spare: int = _spare()
	if spare <= 0 or market == null:
		return
	var bid: float = market.firewood_bid()
	var sold: int = market.buy_firewood_from_agent(agent, spare, _min_price())
	if sold > 0:
		agent.cashflow_today_income += float(sold) * bid
		agent.log_event("Sold %d firewood at $%.2f each." % [sold, bid])
		if event_bus:
			event_bus.emit_log("Tick %d: %s sold %d firewood at $%.2f" % [agent.current_tick, agent.name, sold, bid])


func _on_arrived(t: Node2D) -> void:
	agent.travel_ticks = 0
	agent.idle_ticks = 0
	if yard_location != null and t == yard_location:
		_chop()
		agent.pending_target = market_location if (_spare() > 0 or needs_food_trip()) else home_location
	elif t == market_location:
		_sell_spare()
		attempt_buy_bread()
		phase = Phase.AT_MARKET
		agent.pending_target = home_location
	else:
		phase = Phase.AT_HOME
		if _wants_to_chop():
			agent.pending_target = yard_location
		elif needs_food_trip() or (_spare() > 0 and market != null and market.firewood < market.firewood_capacity and market.firewood_bid() >= _min_price()):
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
	if yard_location != null and route.target == yard_location:
		return "Cutting firewood" if route.is_waiting else "Going to the lumber yard"
	return super.get_status_text()


func on_day_changed(day: int) -> void:
	super.on_day_changed(day)
	if wallet:
		if day_money_start >= 0.0:
			if wallet.money < day_money_start - 0.01:
				consecutive_days_negative_cashflow += 1
			else:
				consecutive_days_negative_cashflow = 0
		if maintenance_cost_per_day > 0.0:
			# Upkeep is paid to the town (the market's purse), not lost: coins only change hands.
			var upkeep: float = minf(maintenance_cost_per_day, wallet.money)
			if upkeep > 0.0 and wallet.debit(upkeep):
				if market:
					market.money += upkeep
				agent.cashflow_today_expense += upkeep
		day_money_start = wallet.money
	set_meta("output_ema", 0.3 * float(firewood_made_today) + 0.7 * float(get_meta("output_ema", float(firewood_made_today))))
	firewood_made_today = 0
	_update_cost()


## What a firewood costs to make: the hands' wages, the yard's upkeep and the woodworker's own
## keep (a loaf and a firewood a day), spread over a normal day's cutting.
func _update_cost() -> void:
	if market == null:
		return
	var per_day: float = maxf(float(get_meta("output_ema", 0.0)), 0.6 * float(_capacity()))
	var keep: float = float(market.bread_price) + float(market.firewood_price)
	cost_per_unit = (float(LaborMarket.hands_of(agent)) * LaborMarket.daily_wage(market) + maintenance_cost_per_day + keep) / maxf(1.0, per_day)
