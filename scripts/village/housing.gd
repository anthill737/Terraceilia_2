extends RefCounted
class_name Housing
## Houses. Every person lives in one. A newcomer only arrives when a house stands empty.
## Anyone who can afford the wood builds a house and works on it themselves. Someone who
## can't afford to buy rents from whoever owns a spare house; the town owns houses nobody
## else does (the starting spares and those left behind) and sells or rents them.
##
## Data only: houses have no map position yet and everyone still walks to the one House spot.

const START_SPARE: int = 2            # empty houses each village starts with
const HOUSE_WOOD: int = 20            # logs a house takes, bought from the market's firewood pile
const BUILD_DAYS: int = 5             # days of the builder's own work once the wood is in
const RENT_PER_DAY: float = 0.5
const SALE_MARKUP: float = 1.5        # the town sells an empty house at wood cost x this
const OWN_RESERVE: float = 60.0       # a renter buys or builds only if this much is left after
const INVEST_RESERVE: float = 150.0   # someone building a house to rent keeps this much
const RENT_DAYS_TO_LEAVE: int = 4     # a household that can't pay rent this long leaves town
const MAX_BUILDS: int = 2             # houses going up at once in one village
const WOOD_PILE_KEEP: float = 0.5     # builders leave this share of the firewood target for heating

var village = null
var market = null
var event_bus = null
var houses: Array = []                # {id, owner, occupant, wood, work, done, unpaid}
var next_id: int = 1
var initialized: bool = false
var stats := {"built": 0, "started": 0, "sold": 0, "rented_out": 0, "rent_paid": 0.0, "evicted": 0, "homeless_max": 0}


func _people() -> Array:
	var out: Array = []
	if village == null:
		return out
	for group in [village.households, village.all_farmers, village.all_bakers, village.all_woodworkers]:
		for a in group:
			if a != null and is_instance_valid(a) and not out.has(a):
				out.append(a)
	return out


func _new_house(owner, occupant, done: bool) -> Dictionary:
	var h := {"id": next_id, "owner": owner, "occupant": occupant, "wood": HOUSE_WOOD if done else 0,
		"work": BUILD_DAYS if done else 0, "done": done, "unpaid": 0}
	next_id += 1
	houses.append(h)
	return h


func wood_cost() -> float:
	return float(HOUSE_WOOD) * (market.firewood_price if market else 1.0)


func sale_price() -> float:
	return wood_cost() * SALE_MARKUP


func _home_of(a) -> Dictionary:
	for h in houses:
		if h.done and h.occupant == a:
			return h
	return {}


func _building_by(a) -> bool:
	for h in houses:
		if not h.done and h.owner == a:
			return true
	return false


func _vacant() -> Array:
	var out: Array = []
	for h in houses:
		if h.done and h.occupant == null:
			out.append(h)
	return out


## Empty houses not already spoken for by someone in town without a home. The spawn check
## uses this: no free house, no newcomer.
func free_slots() -> int:
	if not initialized:
		return START_SPARE
	var homeless := 0
	for a in _people():
		if _home_of(a).is_empty():
			homeless += 1
	return _vacant().size() - homeless


func _pay(from, to, amount: float) -> bool:
	if from == null or from.wallet == null or from.wallet.money < amount:
		return false
	from.wallet.debit(amount)
	if to != null and is_instance_valid(to) and to.wallet:
		to.wallet.credit(amount)
	elif market:
		market.money += amount   # the town's houses pay into the town purse
	return true


func _log(msg: String) -> void:
	if event_bus:
		event_bus.emit_log(msg)


## Once a day, after everyone's own day.
func on_day(day: int) -> void:
	if market == null or village == null:
		return
	var people: Array = _people()
	if not initialized:
		for a in people:
			_new_house(a, a, true)
		for i in START_SPARE:
			_new_house(null, null, true)
		initialized = true
		_log("[HOUSING] day=%d started with %d houses for %d people" % [day, houses.size(), people.size()])
		return

	# Whoever left town no longer lives in or owns anything here. Half-built houses of
	# someone who left are given up; finished ones pass to the town.
	for h in houses.duplicate():
		if h.occupant != null and not people.has(h.occupant):
			h.occupant = null
			h.unpaid = 0
		if h.owner != null and not people.has(h.owner):
			if h.done:
				h.owner = null
			else:
				houses.erase(h)

	# People without a home take an empty one: buy it from the town if they can afford it
	# with some left over, otherwise rent it.
	var homeless := 0
	for a in people:
		if not _home_of(a).is_empty():
			continue
		var vac: Array = _vacant()
		if vac.is_empty():
			homeless += 1
			continue
		var h: Dictionary = vac[0]
		for v in vac:
			if v.owner == null:
				h = v
				break
		h.occupant = a
		h.unpaid = 0
		if h.owner == null and a.wallet and a.wallet.money >= sale_price() + OWN_RESERVE:
			var price: float = sale_price()
			_pay(a, null, price)
			h.owner = a
			stats.sold += 1
			_log("[HOUSING] day=%d %s bought house %d for $%.1f" % [day, a.name, h.id, price])
		else:
			stats.rented_out += 1
			_log("[HOUSING] day=%d %s rents house %d" % [day, a.name, h.id])
	stats.homeless_max = maxi(stats.homeless_max, homeless)

	# Rent. A household that can't pay for RENT_DAYS_TO_LEAVE days leaves town. Owners in
	# business are not put out; their unpaid rent just isn't collected.
	for h in houses:
		if not h.done or h.occupant == null or h.occupant == h.owner:
			continue
		if _pay(h.occupant, h.owner, RENT_PER_DAY):
			stats.rent_paid += RENT_PER_DAY
			h.unpaid = 0
			continue
		h.unpaid += 1
		var a = h.occupant
		if h.unpaid >= RENT_DAYS_TO_LEAVE and a.is_in_group("households") and village.labor_market:
			stats.evicted += 1
			_log("[HOUSING] day=%d %s leaving: %d days of rent unpaid ($%.1f)" % [day, a.name, h.unpaid, a.get_cash()])
			h.occupant = null
			h.unpaid = 0
			village.labor_market.migrate_requested.emit(a, "no_rent")

	# Building: buy the wood a bit at a time from what heating doesn't need, then work.
	for h in houses:
		if h.done:
			continue
		var b = h.owner
		if h.wood < HOUSE_WOOD:
			var spare: int = int(market.firewood - float(market.firewood_target) * WOOD_PILE_KEEP)
			var want: int = mini(HOUSE_WOOD - h.wood, spare)
			if want > 0:
				h.wood += market.sell_firewood_to_agent(b, want)
			continue
		h.work += 1
		if h.work < BUILD_DAYS:
			continue
		h.done = true
		stats.built += 1
		var old: Dictionary = _home_of(b)
		if not old.is_empty() and old.owner != b:
			old.occupant = null      # a renter moves into their own new house
			old.unpaid = 0
			h.occupant = b
			_log("[HOUSING] day=%d %s finished house %d and moved in" % [day, b.name, h.id])
		else:
			_log("[HOUSING] day=%d %s finished house %d to rent out" % [day, b.name, h.id])

	# Start at most one new house a day. First a renter who can afford a home of their own,
	# then, if the town is full and doing well, the richest person builds one to rent out.
	var going: int = 0
	for h in houses:
		if not h.done:
			going += 1
	if going < MAX_BUILDS:
		var builder = null
		var why := ""
		for a in people:
			var home: Dictionary = _home_of(a)
			if home.is_empty() or home.owner == a or _building_by(a):
				continue
			if a.wallet and a.wallet.money >= wood_cost() + OWN_RESERVE:
				builder = a
				why = "a home of their own"
				break
		var pm = village.prosperity_meter
		if builder == null and _vacant().is_empty() and pm and pm.prosperity_score >= pm.PROSPERITY_THRESHOLD_TO_GROW:
			var best: float = wood_cost() + INVEST_RESERVE
			for a in people:
				if a.wallet and a.wallet.money >= best and not _building_by(a):
					best = a.wallet.money
					builder = a
					why = "to rent out"
		if builder != null:
			_new_house(builder, null, false)
			stats.started += 1
			_log("[HOUSING] day=%d %s starts a house %s ($%.1f)" % [day, builder.name, why, builder.get_cash()])

	if day % 5 == 0:
		var line := "[HOUSING] day=%d houses=%d empty=%d building=%d renters=%d homeless=%d built=%d evicted=%d" % [
			day, summary().houses, summary().empty, summary().building, summary().renters, homeless, stats.built, stats.evicted]
		print(line)
		_log(line)


func summary() -> Dictionary:
	var done := 0
	var empty := 0
	var building := 0
	var renters := 0
	for h in houses:
		if not h.done:
			building += 1
			continue
		done += 1
		if h.occupant == null:
			empty += 1
		elif h.occupant != h.owner:
			renters += 1
	return {"houses": done, "empty": empty, "building": building, "renters": renters}
