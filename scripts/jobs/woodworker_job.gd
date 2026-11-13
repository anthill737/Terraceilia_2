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
	get: return LaborMarket.tool_cost_per_day(agent) if Market.direct() else Tuning.f("upkeep_woodworker", 0.2)   # upkeep is the tools it wears out (docs/SMITH.md)
var consecutive_days_negative_cashflow: int = 0
var day_money_start: float = -1.0
var cost_per_unit: float = 0.7
var turned_away_today: bool = false   # the market would not take wood at some point today


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
	# The owner's own skill counts in every trade (docs/SKILL.md); it did not at the yard.
	var own: float = SkillSet.factor(agent.skill_in("Woodworker")) if Tuning.on("worker_skill", true) else 1.0
	return roundi(float(Tuning.i("woodworker_logs_per_day", FIREWOOD_PER_DAY)) * own * LaborMarket.hand_mult(agent) * LaborMarket.tool_factor(agent))


## Firewood beyond what the woodworker keeps for its own hearth.
func _spare() -> int:
	return maxi(0, inv.get_qty("firewood") - HOME_FIREWOOD) if inv else 0


func _min_price() -> float:
	return cost_per_unit * (1.0 + MIN_MARGIN)


## True when the market's pile is not already over its target and it pays enough.
func _market_wants() -> bool:
	if market == null:
		return false
	var wants: bool = float(market.firewood) <= float(market.firewood_target) * (1.0 + float(market.TARGET_BAND_PCT)) and market.firewood_bid() >= _min_price()
	if not wants:
		turned_away_today = true
	return wants


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
		if not Market.direct():
			agent.cashflow_today_income += float(sold) * bid   # with buyers paying makers, the takings are booked when the wood sells
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
		if maintenance_cost_per_day > 0.0 and not Market.direct():   # with buyers paying makers the town collects no upkeep: it was coins going to nobody (docs/BUY_FROM_MAKERS.md)
			# Upkeep is paid to the town (the market's purse), not lost: coins only change hands.
			var upkeep: float = minf(maintenance_cost_per_day, wallet.money)
			if upkeep > 0.0 and wallet.debit(upkeep):
				if market:
					market.money += upkeep
				agent.cashflow_today_expense += upkeep
		day_money_start = wallet.money
	_note_day_of_cutting()
	firewood_made_today = 0
	turned_away_today = false
	_update_cost()


## What a normal day's cutting comes to, kept as a running average. A day the market turned the
## woodworker away says nothing about what a log costs to cut, so it does not count (unless
## they cut more than usual anyway). It used to: one idle day cut the average by 30%, the cost
## of a log rose 42% overnight, and the woodworker stayed priced out while the pile ran down
## to nothing (138 such jumps in a 1,000-day probe of two towns, 2026-11-13).
func _note_day_of_cutting() -> void:
	var usual: float = float(get_meta("output_ema", float(firewood_made_today)))
	if turned_away_today and float(firewood_made_today) < usual:
		return
	set_meta("output_ema", 0.3 * float(firewood_made_today) + 0.7 * usual)


## What a firewood costs to make: the hands' wages, the yard's upkeep and the woodworker's own
## keep (what it costs them to live: food, firewood, rent and clothes; until 2026-11-13 only a
## loaf and a log, so a woodworker sold wood for less than they needed and went broke),
## spread over a normal day's cutting.
func _update_cost() -> void:
	if market == null:
		return
	var per_day: float = maxf(float(get_meta("output_ema", 0.0)), 0.6 * float(_capacity()))
	var keep: float = LaborMarket.keep_of(self)   # what it costs the owner to live: food, firewood, rent, clothes
	cost_per_unit = (float(LaborMarket.hands_of(agent)) * LaborMarket.wage_of(agent) + maintenance_cost_per_day + keep) / maxf(1.0, per_day)
