extends HouseholdJob
class_name MerchantJob

## Travelling merchant. Lives like any household in the home village and carries goods
## between the two village markets with their own coins: buys where a good is cheap and
## plentiful, walks it to the other market, and sells where that market pays more.
## Producers stay home and keep selling to their own market (their own trips never happened
## in normal play, and a town's only baker walking off with the bread starved it).
## This is how SAELIG and X4 move goods: each market prices from its own stock, and traders
## chase the gap.
##
## Rules
## - Twice a day the merchant checks the home market. A deal needs the far market to pay at
##   least MIN_GAIN_SHARE more than the near price (and MIN_GAIN_PER_UNIT coins), and the whole
##   load to earn MIN_TRIP_PROFIT.
## - Never strips a market: only takes stock above half that market's target.
## - Carries up to CART units. At the far market, sells, then looks for a load to bring home.
## - With no deal for a few days the merchant lives off a garden plot like a cottager
##   (LaborMarket._update_cottagers), so a quiet spell does not ruin them.

const OWNER_CASH: float = 150.0
const CART: int = 20
const MIN_GAIN_SHARE: float = 0.10
const MIN_GAIN_PER_UNIT: float = 0.25
const MIN_TRIP_PROFIT: float = 4.0
const KEEP_BREAD: int = 3
const KEEP_FIREWOOD: int = 3
const EVAL_EVERY_TICKS: int = 5
const GOODS: Array = ["wheat", "bread", "firewood"]

var cargo_good: String = ""
var cargo_qty: int = 0
var cargo_unit_cost: float = 0.0
var far_village = null            # the other village, while on a trip
var far_market_node: Node2D = null
var on_trip: bool = false
var _last_eval_tick: int = -999


func get_display_name() -> String:
	return "Merchant"


func activate() -> void:
	super.activate()
	if route:
		route.max_travel_time = 600.0   # the walk to the other village is long (wall-clock limit)
	if wallet and wallet.money < OWNER_CASH and not agent.has_meta("merchant_purse"):
		wallet.credit(OWNER_CASH - wallet.money)
	agent.set_meta("merchant_purse", true)
	agent.set_meta("merchant", true)
	for k in ["trade_trips", "days_since_trade"]:
		if not agent.has_meta(k):
			agent.set_meta(k, 0)
	if not agent.has_meta("trade_profit_total"):
		agent.set_meta("trade_profit_total", 0.0)
	if not agent.has_meta("trade_last"):
		agent.set_meta("trade_last", "")


func _world() -> Node:
	var scene = Engine.get_main_loop().current_scene if Engine.get_main_loop() else null
	return scene.get_node_or_null("World") if scene else null


func _trading_allowed() -> bool:
	var w = _world()
	return w != null and w.get("trade_enabled") == true and not w.get_meta("no_merchants", false)


func _other_village():
	var w = _world()
	if w == null or agent.home_village_ref == null:
		return null
	for v in w.villages:
		if v != null and is_instance_valid(v) and v != agent.home_village_ref and v.market != null and not v.sim_failed:
			return v
	return null


static func _stock(m, good: String) -> int:
	return int(m.get(good))


static func _target(m, good: String) -> int:
	return int(m.get(good + "_target"))


static func _capacity(m, good: String) -> int:
	return int(m.get(good + "_capacity"))


static func _shelf_price(m, good: String) -> float:
	return float(m.get(good + "_price"))


static func _bid(m, good: String) -> float:
	return m.firewood_bid() if good == "firewood" else m.get_bid_price(good)


## The best load to carry from market `src` to market `dst`, or {} when nothing pays.
func best_deal(src, dst) -> Dictionary:
	var best: Dictionary = {}
	if src == null or dst == null or wallet == null:
		return best
	for good in GOODS:
		var buy: float = _shelf_price(src, good)
		var sell: float = _bid(dst, good)
		var gain: float = sell - buy
		if buy <= 0.0 or gain < maxf(MIN_GAIN_PER_UNIT, MIN_GAIN_SHARE * buy):
			continue
		var spare: int = _stock(src, good) - int(ceil(float(_target(src, good)) * 0.5))
		var room: int = _capacity(dst, good) - _stock(dst, good)
		var qty: int = mini(mini(CART, spare), mini(room, int(floor(wallet.money / buy))))
		if qty <= 0:
			continue
		# The far market pays a little less for each further unit; count on 80% of the gap.
		var profit: float = float(qty) * gain * 0.8
		if profit < MIN_TRIP_PROFIT:
			continue
		if best.is_empty() or profit > float(best.profit):
			best = {"good": good, "qty": qty, "buy": buy, "sell": sell, "profit": profit}
	return best


func _carried(good: String) -> int:
	var have: int = inv.get_qty(good) if inv else 0
	if good == "bread":
		return maxi(0, have - KEEP_BREAD)
	if good == "firewood":
		return maxi(0, have - KEEP_FIREWOOD)
	return have


func _buy_load(m, deal: Dictionary, to_name: String) -> bool:
	var good: String = deal.good
	var before: float = wallet.money
	var got: int = 0
	match good:
		"wheat":
			got = m.sell_wheat_to_baker(agent, int(deal.qty))   # puts it in the pack itself
		"bread":
			got = m.sell_bread_to_agent(agent, int(deal.qty))
			if got > 0:
				inv.add("bread", got)
		"firewood":
			got = m.sell_firewood_to_agent(agent, int(deal.qty))
			if got > 0:
				inv.items["firewood"] = inv.get_qty("firewood") + got
	if got <= 0:
		return false
	cargo_good = good
	cargo_qty = got
	cargo_unit_cost = (before - wallet.money) / float(got)
	agent.cashflow_today_expense += before - wallet.money
	agent.log_event("Bought %d %s at $%.2f each to sell in %s." % [got, good, cargo_unit_cost, to_name])
	if event_bus:
		event_bus.emit_log("[MERCHANT] %s bought %d %s at $%.2f each to carry to %s (they pay about $%.2f)" % [
			agent.name, got, good, cargo_unit_cost, to_name, float(deal.sell)])
	return true


func _sell_load(m, where: String) -> void:
	if cargo_good == "" or cargo_qty <= 0:
		cargo_good = ""
		cargo_qty = 0
		return
	var offer: int = mini(cargo_qty, _carried(cargo_good))
	if offer <= 0:
		cargo_good = ""
		cargo_qty = 0
		return
	var before: float = wallet.money
	var sold: int = 0
	match cargo_good:
		"wheat":
			sold = m.buy_wheat_from_farmer(agent, 0.0, false)
		"bread":
			sold = m.buy_bread_from_agent(agent, offer, 0.0, false)
		"firewood":
			sold = m.buy_firewood_from_agent(agent, offer, 0.0)
	if sold <= 0:
		return
	var revenue: float = wallet.money - before
	var profit: float = revenue - float(sold) * cargo_unit_cost
	agent.cashflow_today_income += revenue
	agent.set_meta("trade_trips", int(agent.get_meta("trade_trips", 0)) + 1)
	agent.set_meta("trade_profit_total", float(agent.get_meta("trade_profit_total", 0.0)) + profit)
	agent.set_meta("days_since_trade", 0)
	var line: String = "sold %d %s in %s at $%.2f each (bought at $%.2f, profit $%.2f)" % [
		sold, cargo_good, where, revenue / float(sold), cargo_unit_cost, profit]
	agent.set_meta("trade_last", line)
	agent.log_event(line.capitalize() + ".")
	if event_bus:
		event_bus.emit_log("[MERCHANT] %s %s" % [agent.name, line])
	var home_v = agent.home_village_ref
	if home_v != null and is_instance_valid(home_v) and home_v.get("trade_stats") != null:
		home_v.trade_stats.trips += 1
		home_v.trade_stats.units += sold
		home_v.trade_stats.profit += profit
	cargo_qty -= sold
	if cargo_qty <= 0:
		cargo_good = ""
		cargo_qty = 0


func needs_food_trip() -> bool:
	if on_trip or cargo_qty > 0:
		return true
	if _trading_allowed() and agent.current_tick - _last_eval_tick >= EVAL_EVERY_TICKS:
		return true   # time to look at the market again
	return super.needs_food_trip()


func _on_arrived(t: Node2D) -> void:
	if far_market_node != null and t == far_market_node and far_village != null and is_instance_valid(far_village):
		_at_far_market()
		return
	if t == market_location:
		var was_trip: bool = on_trip
		on_trip = false
		far_village = null
		far_market_node = null
		agent.current_village_ref = agent.home_village_ref
		if cargo_qty > 0:
			_sell_load(market, _village_name(agent.home_village_ref))
		super._on_arrived(t)        # own bread and firewood; sets the walk home
		_last_eval_tick = agent.current_tick
		if not was_trip or cargo_qty <= 0:
			_try_export()
		return
	super._on_arrived(t)


func _village_name(v) -> String:
	if v == null or not is_instance_valid(v):
		return "the other village"
	var n = v.get("village_name")
	return str(n) if n != null and str(n) != "" else "Village %d" % int(v.village_id)


## At the home market with no load: is there something worth carrying to the other village?
func _try_export() -> void:
	if not _trading_allowed() or cargo_qty > 0 or market == null:
		return
	var other = _other_village()
	if other == null:
		return
	var deal: Dictionary = best_deal(market, other.market)
	if deal.is_empty():
		# Nothing to carry out. Is it worth walking over empty to bring something back?
		var back: Dictionary = best_deal(other.market, market)
		if back.is_empty() or float(back.profit) < MIN_TRIP_PROFIT * 2.0:
			return
	elif not _buy_load(market, deal, _village_name(other)):
		return
	far_village = other
	far_market_node = other.market_node
	on_trip = true
	agent.pending_target = far_market_node
	agent.log_event("Set off for %s." % _village_name(other))


func _at_far_market() -> void:
	agent.travel_ticks = 0
	agent.idle_ticks = 0
	agent.current_village_ref = far_village
	var fm = far_village.market
	_sell_load(fm, _village_name(far_village))
	# Own food for the road.
	if inv.get_qty("bread") < KEEP_BREAD and fm != null:
		var got: int = fm.sell_bread_to_household(agent, KEEP_BREAD - inv.get_qty("bread"))
		if got > 0:
			inv.add("bread", got)
	# A load for the way home, if one pays.
	if cargo_qty <= 0 and _trading_allowed():
		var deal: Dictionary = best_deal(fm, market)
		if not deal.is_empty():
			_buy_load(fm, deal, _village_name(agent.home_village_ref))
	phase = Phase.AT_MARKET
	agent.pending_target = market_location
	route.wait(WAIT_TIME)


func _on_wait_finished() -> void:
	# Keep heading for the far market or back to the home market; the household rule
	# "market trip cancelled" must not turn a trip around.
	if agent.pending_target != null and (agent.pending_target == far_market_node or on_trip):
		route.set_target(agent.pending_target)
		agent.pending_target = null
		return
	super._on_wait_finished()


func on_day_changed(day: int) -> void:
	super.on_day_changed(day)
	agent.set_meta("days_since_trade", int(agent.get_meta("days_since_trade", 0)) + 1)


func get_status_text() -> String:
	if on_trip and route.target == far_market_node:
		return "Carrying %d %s to %s" % [cargo_qty, cargo_good, _village_name(far_village)] if cargo_qty > 0 else "Walking to %s to buy" % _village_name(far_village)
	if on_trip and route.target == market_location:
		return "Bringing %d %s home" % [cargo_qty, cargo_good] if cargo_qty > 0 else "Walking home from %s" % _village_name(far_village)
	return super.get_status_text()


func get_job_inspector_data() -> Dictionary:
	var d: Dictionary = super.get_job_inspector_data()
	d["merchant_trips"] = int(agent.get_meta("trade_trips", 0))
	d["merchant_profit"] = float(agent.get_meta("trade_profit_total", 0.0))
	d["merchant_last"] = str(agent.get_meta("trade_last", ""))
	d["merchant_cargo"] = "%d %s" % [cargo_qty, cargo_good] if cargo_qty > 0 else "nothing"
	return d
