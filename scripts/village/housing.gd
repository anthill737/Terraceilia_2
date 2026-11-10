extends RefCounted
class_name Housing
## Houses. Every person lives in one. A newcomer only arrives when a house stands empty.
##
## One price runs everything: a house is worth what it costs to put one up, 20 logs at the
## market's firewood price plus 5 days of a worker's wage. Buying an empty house costs that.
## Building one costs the same: the builder buys the logs and pays a day's wage to someone
## out of work for each of the 5 days (if nobody is free, the builder does it and keeps the
## wage). Rent is that same value spread over RENT_PAYBACK_DAYS. Whoever buys or builds,
## a renter for themselves or a richer person to let out, needs the same amount: the
## house's value plus CUSHION_DAYS of bread and firewood left over.
## The town owns houses nobody else does (the starting spares and those left behind).
##
## Each house has a spot on the map (a grid south-east of the market) and the people living
## in it walk home to it. People with no house sleep at the shelter (the old shared home).

const START_SPARE: int = 2            # empty houses each village starts with
const HOUSE_WOOD: int = 20            # logs a house takes, bought from the market's firewood pile
const BUILD_DAYS: int = 5             # days of the builder's own work once the wood is in
const RENT_PAYBACK_DAYS: float = 120.0  # rent a day = house value / this
const CUSHION_DAYS: float = 10.0       # buyers and builders keep this many days of bread + firewood
const RENT_DAYS_TO_LEAVE: int = 4     # a household that can't pay rent this long leaves town
const MAX_BUILDS: int = 2             # houses going up at once in one village
const WOOD_PILE_KEEP: float = 1.0     # builders only buy firewood above the full target: heating first
const HOUSE_ORIGIN := Vector2(440, 400)  # village-local spot of the first house
const HOUSE_COLS: int = 5
const HOUSE_DX: float = 44.0
const HOUSE_DY: float = 48.0

var village = null
var market = null
var event_bus = null
var houses: Array = []                # {id, owner, occupant, wood, work, done, unpaid, pos, node}
var next_id: int = 1
var initialized: bool = false
var stats := {"wages_paid": 0.0, "built": 0, "started": 0, "sold": 0, "rented_out": 0, "rent_paid": 0.0, "evicted": 0, "homeless_max": 0}


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
	var slot: int = next_id - 1
	h.pos = HOUSE_ORIGIN + Vector2((slot % HOUSE_COLS) * HOUSE_DX, (slot / HOUSE_COLS) * HOUSE_DY)
	if village != null:
		var spot := Node2D.new()
		spot.name = "Home%d" % h.id
		spot.position = h.pos
		spot.set_meta("village_id", village.village_id)
		village.add_child(spot)
		h.node = spot
	next_id += 1
	houses.append(h)
	return h


func wood_cost() -> float:
	return float(HOUSE_WOOD) * (market.firewood_price if market else 1.0)


## A worker's wages for the days it takes to build.
func labour_cost() -> float:
	return float(BUILD_DAYS) * LaborMarket.daily_wage(market)


## What a house is worth: what it costs to build one today.
func house_value() -> float:
	return wood_cost() + labour_cost()


func sale_price() -> float:
	return house_value()


func rent_per_day() -> float:
	return house_value() / RENT_PAYBACK_DAYS


## Money a buyer or builder keeps back for food and heat.
func cushion() -> float:
	return CUSHION_DAYS * (market.bread_price + market.firewood_price)


func can_afford_house(a) -> bool:
	return a != null and a.wallet != null and a.wallet.money >= house_value() + cushion()


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
		_sync_homes()
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
				if h.get("node") != null and is_instance_valid(h.node):
					h.node.queue_free()
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
		if h.owner == null and can_afford_house(a):
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
	var rent: float = rent_per_day()
	for h in houses:
		if not h.done or h.occupant == null or h.occupant == h.owner:
			continue
		if _pay(h.occupant, h.owner, rent):
			stats.rent_paid += rent
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

	# Building: buy the wood a bit at a time from what heating doesn't need, then 5 days of
	# work. Each work day the builder pays a day's wage to someone out of work.
	var wage: float = LaborMarket.daily_wage(market)
	var hired_today: Array = []
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
		var worker = village.labor_market._free_hand() if village.labor_market else null
		if worker != null and worker != b and not hired_today.has(worker) and b.wallet and b.wallet.money >= wage:
			b.wallet.debit(wage)
			worker.wallet.credit(wage)
			b.cashflow_today_expense += wage
			worker.cashflow_today_income += wage
			hired_today.append(worker)
			stats.wages_paid += wage
			h.worker = str(worker.name)
		else:
			h.worker = ""
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
			if can_afford_house(a):
				builder = a
				why = "a home of their own"
				break
		var pm = village.prosperity_meter
		if builder == null and _vacant().is_empty() and pm and pm.prosperity_score >= pm.PROSPERITY_THRESHOLD_TO_GROW:
			var best: float = house_value() + cushion()
			for a in people:
				if a.wallet and a.wallet.money >= best and not _building_by(a):
					best = a.wallet.money
					builder = a
					why = "to rent out"
		if builder != null:
			_new_house(builder, null, false)
			stats.started += 1
			_log("[HOUSING] day=%d %s starts a house %s ($%.1f)" % [day, builder.name, why, builder.get_cash()])

	_sync_homes()

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


## Point each resident's walk home at their own house. Someone already on the way to, or
## waiting at, the old home is redirected.
func _sync_homes() -> void:
	for h in houses:
		if h.done and h.occupant != null and is_instance_valid(h.occupant) and h.get("node") != null:
			_set_home(h.occupant, h.node)


func _set_home(a, spot: Node2D) -> void:
	var j = a.current_job
	if not (j is HouseholdJob) or j.home_location == spot:
		return
	var old: Node2D = j.home_location
	j.home_location = spot
	if a.pending_target == old:
		a.pending_target = spot
	if j.route != null and j.route.target == old:
		j.route.set_target(spot)


## One line for the person inspector.
func describe(a) -> String:
	var parts: Array = []
	var home: Dictionary = _home_of(a)
	if home.is_empty():
		parts.append("No house; sleeps at the shelter.")
	elif home.owner == a:
		parts.append("Owns house %d." % home.id)
	elif home.owner == null:
		parts.append("Rents house %d from the town ($%.2f a day)." % [home.id, rent_per_day()])
	else:
		parts.append("Rents house %d from %s ($%.2f a day)." % [home.id, home.owner.name, rent_per_day()])
	if not home.is_empty() and int(home.unpaid) > 0:
		parts.append("[color=#ff8844]%d day(s) behind on rent.[/color]" % home.unpaid)
	var let_out := 0
	for h in houses:
		if not h.done and h.owner == a:
			parts.append("Building house %d: wood %d/%d, work %d/%d days%s." % [h.id, h.wood, HOUSE_WOOD, h.work, BUILD_DAYS,
				(", hired " + str(h.get("worker", ""))) if str(h.get("worker", "")) != "" else ""])
		elif h.done and h.owner == a and h.occupant != a:
			let_out += 1
	if let_out > 0:
		parts.append("Lets out %d house(s)." % let_out)
	parts.append("A house is worth $%.0f (wood $%.0f + 5 days' wages $%.0f)." % [house_value(), wood_cost(), labour_cost()])
	return " ".join(parts)
