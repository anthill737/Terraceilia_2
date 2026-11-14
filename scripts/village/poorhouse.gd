class_name Poorhouse
extends RefCounted
## The poorhouse (docs/POORHOUSE.md). In SAELIG someone with no job waits in a free bunkhouse
## and never leaves; here they spent their purse on rent, bread and firewood and left town
## broke (75 to 83 in 100 newcomers did). The town's shelter is now a poorhouse, kept by the
## town's purse: the taxes it takes in (rent and sales of town houses, shop fees and upkeep,
## and the coins of people who left or died), which until now it never spent.
##
## - Who goes in: someone with no shop and no work who would otherwise leave town broke (no
##   bread in the house and not the price of a loaf left, or four days behind on rent). They
##   give up the house they lived in and move into the poorhouse instead, if the town's purse
##   can pay a day's bread and firewood. If it can't, they leave, as before. Someone who owns
##   the house they live in pays no rent there, so they stay in it and are kept the same way.
## - Living there: no rent. Each day the town buys a resident with no work what they can't buy
##   themselves: a loaf when there is none in the house, a log when the hearth is empty, at the
##   market's price, paid to the maker like any other sale. A resident with the coins buys
##   their own. A resident the town can no longer keep leaves, and so does one the town could
##   not get a loaf for (an empty shelf), as anyone with no bread and no coins would.
## - Places: the poorhouse keeps at most PLACES people. When they are all taken, the next person
##   with nothing left leaves town, as before.
## - Getting out: residents have no work, and employers, house builders and masters wanting a
##   servant take the poorest person free, so they are first in line. Someone with work takes
##   the next empty house the usual way (rent or buy) and leaves the poorhouse. Someone with no
##   work does not take a house (they would only fall behind on rent), so they do not hold one
##   back from a newcomer either.
## - It brings nobody to town: newcomers still come only when a house stands empty.

const PLACES: int = 6   # people the poorhouse can keep (SAELIG players see 5 to 10 jobless in a town of 45)

var village = null
var market = null
var event_bus = null
var stats := {"taken_in": 0, "moved_out": 0, "loaves": 0, "logs": 0, "paid": 0.0, "turned_away": 0, "full": 0, "sent_away": 0}


static func places() -> int:
	return Tuning.i("poorhouse_places", PLACES)


static func on() -> bool:
	return Tuning.on("poorhouse", true)


static func lives_there(a) -> bool:
	return a != null and is_instance_valid(a) and a.has_meta("poorhouse")


func residents() -> Array:
	var out: Array = []
	if village == null:
		return out
	for a in village.households:
		if lives_there(a):
			out.append(a)
	return out


## What a day's keep costs the town at today's prices: a loaf and a log.
func day_cost() -> float:
	return market.bread_price + market.firewood_price


func _has_work(a) -> bool:
	return village.labor_market != null and not village.labor_market.is_idle(a)


## `a` has nothing left: they move into the poorhouse instead of leaving town. False, and they
## leave as before, when the switch is off, they are not someone with no shop and no work, or
## the town's purse can't keep them today.
func take_in(a, day: int, why: String) -> bool:
	if not on() or market == null or village == null or a == null or not is_instance_valid(a):
		return false
	if lives_there(a):
		return true
	if not village.households.has(a) or a.has_meta("merchant") or _has_work(a):
		return false
	if residents().size() >= places():
		stats.full += 1
		_log("[POORHOUSE] day=%d the poorhouse is full (%d places), so %s leaves" % [day, places(), a.name])
		return false
	if market.money < day_cost():
		stats.turned_away += 1
		_log("[POORHOUSE] day=%d the town's purse can't keep %s ($%.1f in it), so they leave" % [day, a.name, market.money])
		return false
	a.set_meta("poorhouse", day)
	stats.taken_in += 1
	if _owns_home(a):
		# They pay no rent in their own house, so they stay in it and are kept the same way.
		_log("[POORHOUSE] day=%d %s is kept by the town in the house they own: %s ($%.1f)" % [day, a.name, why, a.get_cash()])
		if a.has_method("log_event"):
			a.log_event("Kept by the town (%s): it buys their bread and firewood while they have no work and no coins." % why)
		return true
	if village.housing:
		village.housing.move_out(a)
	var shelter = village.get_node_or_null("HouseholdHome")
	if shelter != null and village.housing:
		village.housing._set_home(a, shelter)
	_log("[POORHOUSE] day=%d %s moves into the poorhouse: %s ($%.1f)" % [day, a.name, why, a.get_cash()])
	if a.has_method("log_event"):
		a.log_event("Moved into the poorhouse (%s). No rent there, and the town buys their bread and firewood while they have no work and no coins." % why)
	return true


func _owns_home(a) -> bool:
	if village.housing == null:
		return false
	var home: Dictionary = village.housing._home_of(a)
	return not home.is_empty() and home.owner == a


## A day in the poorhouse for `a`: the town buys what they can't. False when the town's purse
## can't pay for what they need, and they have to leave. With no loaf on the shelf for the town
## to buy they have no bread and no coins, and LaborMarket sends them away as it would anyone.
func keep(a, day: int) -> bool:
	if not lives_there(a) or market == null:
		return true
	if _has_work(a):
		if _owns_home(a):
			moved_out(a, day, int(village.housing._home_of(a).id))   # back on their feet at home
		return true   # they buy their own
	var ok: bool = true
	if a.inv.get_qty("bread") == 0 and a.get_cash() < market.bread_price:
		ok = _town_buys(a, "bread") and ok
	if a.inv.get_qty("firewood") == 0 and a.get_cash() < market.firewood_price:
		ok = _town_buys(a, "firewood") and ok
	if not ok:
		stats.sent_away += 1
		_log("[POORHOUSE] day=%d the town's purse can't keep %s any longer ($%.1f in it)" % [day, a.name, market.money])
	elif a.inv.get_qty("bread") > 0:
		# Fed today: a trip to market with no coins for a second loaf is not a hungry day, so
		# it does not count towards leaving for want of food.
		a.consecutive_failed_food_days = 0
		a.days_in_survival_mode = 0
	return ok


## The town buys one `good` for `a` at today's price, from a maker's stall like any buyer: the
## coins go from the town's purse through `a`'s hands to the maker at once. False only when the
## purse is short; an empty shelf is true (nothing bought, nothing paid).
func _town_buys(a, good: String) -> bool:
	var price: float = market.bread_price if good == "bread" else market.firewood_price
	if market.money < price:
		return false
	market.money -= price
	a.wallet.credit(price)
	var before: float = a.get_cash()
	var got: int = market.sell_bread_to_household(a, 1) if good == "bread" else market.sell_firewood_to_agent(a, 1)
	var spent: float = before - a.get_cash()
	var back: float = price - spent
	if back > 0.0:
		a.wallet.debit(back)   # nothing on the shelf: the coins go back to the purse
		market.money += back
	if got > 0:
		if good == "bread":
			a.inv.add("bread", got)
			stats.loaves += got
		else:
			a.inv.items["firewood"] = a.inv.get_qty("firewood") + got
			stats.logs += got
		stats.paid += spent
	return true


## `a` has work and a house (one they took, rented or bought, or their own): the town stops
## keeping them.
func moved_out(a, day: int, house_id: int) -> void:
	if not lives_there(a):
		return
	a.remove_meta("poorhouse")
	stats.moved_out += 1
	_log("[POORHOUSE] day=%d %s leaves the poorhouse for house %d" % [day, a.name, house_id])
	if a.has_method("log_event"):
		a.log_event("No longer kept by the town: has work, and lives in house %d." % house_id)


func _log(msg: String) -> void:
	if event_bus:
		event_bus.emit_log(msg)
