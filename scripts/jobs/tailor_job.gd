extends HouseholdJob
class_name TailorJob

## Tailor (docs/CLOTHES.md): walks to the tailor's shop, makes clothes and puts them out at the
## market. Everyone wears clothes out; people buy new ones when the set is worth its price to
## them (Clothing).
##
## Clothes are made of linen. The tailor buys flax at the market (grown by the farmers), and
## the day's work turns it into clothes: breaking and combing the stalks, spinning the fibre,
## weaving the cloth and sewing it. FLAX_PER_SET flax make one set. Hands, skill and tools
## (shears and needles, bought from the smith) raise what a shop makes the way they do in any shop. It
## lives like a household (buys bread, keeps a hearth) and so extends HouseholdJob. The price it
## will sell at covers its hands' wages, its tools and its own keep over a normal day's work,
## plus the same 25% margin the other trades ask.

const OWNER_CASH: float = 150.0      # a business owner's purse
const CLOTHES_PER_DAY: int = 4       # sets one tailor makes in a day, working alone
const FLAX_PER_SET: int = 3          # flax that goes into one set of clothes
const MIN_MARGIN: float = 0.25

var shop_location: Node2D = null
var made_today: int = 0
var consecutive_days_negative_cashflow: int = 0
var day_money_start: float = -1.0
var cost_per_unit: float = 2.0
## A shop's upkeep is the tools it wears out (docs/SMITH.md).
var maintenance_cost_per_day: float:
	get: return LaborMarket.tool_cost_per_day(agent)


func get_display_name() -> String:
	return "Tailor"


func get_job_inspector_data() -> Dictionary:
	var d: Dictionary = super.get_job_inspector_data()
	d["role"] = "Tailor"
	d["clothes_made_today"] = made_today
	d["cost_per_unit"] = snappedf(cost_per_unit, 0.01)
	d["prod_mult"] = LaborMarket.hand_mult(agent)
	return d


func activate() -> void:
	if wallet and wallet.money <= 0.0:
		wallet.credit(Tuning.f("owner_start_coins", OWNER_CASH))
		Village.note_brought(agent, Tuning.f("owner_start_coins", OWNER_CASH))
	super.activate()
	if inv:
		inv.items = {"bread": 2, "firewood": 6, "clothes": 0, "flax": 0}
	_update_cost()


func _capacity() -> int:
	var own: float = SkillSet.factor(agent.skill_in("Tailor")) if Tuning.on("worker_skill", true) else 1.0
	return roundi(float(Tuning.i("tailor_clothes_per_day", CLOTHES_PER_DAY)) * own * LaborMarket.hand_mult(agent) * LaborMarket.tool_factor(agent))


func _spare() -> int:
	return inv.get_qty("clothes") if inv else 0


func _min_price() -> float:
	return cost_per_unit * (1.0 + MIN_MARGIN)


## True when the market's stock of clothes is not already over its target and it pays enough.
func _market_wants() -> bool:
	if market == null or not market.has_good("clothes"):
		return false
	if float(market.good_stock("clothes")) > float(market.good_target("clothes")) * (1.0 + float(market.TARGET_BAND_PCT)):
		return false
	return market.good_bid("clothes") >= _min_price()


func _wants_to_work() -> bool:
	if shop_location == null or inv == null:
		return false
	if made_today >= _capacity():
		return false
	return _spare() < _capacity() and _market_wants() and inv.get_qty("flax") >= FLAX_PER_SET


## Flax for the next day's work, bought at the market (the buyer pays the farmer).
func _buy_flax() -> void:
	if market == null or not market.has_good("flax") or not _market_wants():
		return
	var want: int = _capacity() * FLAX_PER_SET - inv.get_qty("flax")
	if want > 0:
		market.buy_good(agent, "flax", want)


func _make() -> void:
	var n: int = mini(_capacity() - made_today, _capacity() - _spare())
	n = mini(n, inv.get_qty("flax") / FLAX_PER_SET)
	if n <= 0 or not _market_wants():
		return
	inv.remove("flax", n * FLAX_PER_SET)
	inv.add("clothes", n)
	made_today += n
	agent.log_event("Made %d sets of clothes." % n)


func _sell_spare() -> void:
	var spare: int = _spare()
	if spare <= 0 or market == null or not market.has_good("clothes"):
		return
	var bid: float = market.good_bid("clothes")
	var put: int = market.put_out(agent, "clothes", spare, _min_price())
	if put > 0:
		agent.log_event("Put %d sets of clothes out at the market at $%.2f each." % [put, bid])
		if event_bus:
			event_bus.emit_log("Tick %d: %s put out %d sets of clothes at $%.2f" % [agent.current_tick, agent.name, put, bid])


func _on_arrived(t: Node2D) -> void:
	agent.travel_ticks = 0
	agent.idle_ticks = 0
	if shop_location != null and t == shop_location:
		_make()
		agent.pending_target = market_location if (_spare() > 0 or needs_food_trip()) else home_location
	elif t == market_location:
		_sell_spare()
		_buy_flax()
		buy_firewood_to(HOME_FIREWOOD)
		attempt_buy_bread()
		phase = Phase.AT_MARKET
		agent.pending_target = home_location
	else:
		phase = Phase.AT_HOME
		if _wants_to_work():
			agent.pending_target = shop_location
		elif needs_food_trip() or (_spare() > 0 and _market_wants()) or (_market_wants() and inv.get_qty("flax") < FLAX_PER_SET):
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
	if shop_location != null and route.target == shop_location:
		return "Sewing at the tailor's" if route.is_waiting else "Going to the tailor's shop"
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
	set_meta("output_ema", 0.3 * float(made_today) + 0.7 * float(get_meta("output_ema", float(made_today))))
	LaborMarket.note_day_made(self, float(made_today))
	made_today = 0
	_update_cost()


## What a set of clothes costs to make: its flax, the hands' wages, the tools worn out and the tailor's
## own keep (food, firewood, rent and clothes), spread over what today's crew will make (the
## morning price, LaborMarket.costing_volume).
func _update_cost() -> void:
	if market == null:
		return
	var can: float = float(_capacity())
	var per_day: float = LaborMarket.costing_volume(self, can, LaborMarket.COSTING_FLOOR * can)
	var keep: float = LaborMarket.keep_of(self)   # what it costs the owner to live: food, firewood, rent, clothes
	cost_per_unit = (float(LaborMarket.hands_of(agent)) * LaborMarket.wage_of(agent) + maintenance_cost_per_day + keep) / per_day \
			+ (float(FLAX_PER_SET) * market.good_price("flax") if market.has_good("flax") else 0.0)
