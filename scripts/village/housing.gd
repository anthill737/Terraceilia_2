extends RefCounted
class_name Housing
## Houses. Every person lives in one. A newcomer only arrives when a house stands empty.
##
## One price runs everything: a house is worth what it costs to put one up, 20 logs at the
## market's firewood price plus 5 days of a worker's wage. Buying an empty house costs that.
## Building one costs the same: the builder buys the logs and pays a day's wage to someone
## out of work for each of the 5 days (if nobody is free, the builder does it and keeps the
## wage). Rent is that same value spread over RENT_PAYBACK_DAYS.
##
## The building work is real: each house has one worker for the whole job, who walks to the
## site and spends the day there instead of at home. A household with no employer builds its
## own house; anyone else hires someone out of work and pays them a day's wage per work day.
## A day with no worker on site is a day with no progress.
##
## Money needed, all with CUSHION_DAYS of bread and firewood left over: buying, or building
## with a hired worker, takes the house's whole value; a household doing its own building
## pays the logs in coin and the 5 days in its own time, so it needs only the wood cost.
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
## Home improvements: someone who owns the house they live in and has money to spare makes
## it better, one level at a time: cottage, house, fine house, hall, great hall, manor, and
## after that a manor keeps getting rooms added. Steps stay affordable (a few weeks of an
## owner's profit), so the spending is a steady stream, not a rare lump. It takes logs
## and builder days (index = the level it starts from). This is where profit goes back
## into the town: it pays the woodworker and a builder, who spend it on bread.
const UP_WOOD: Array = [0, 10, 12, 14, 16, 16]   # from level 5 on every step costs the same
const UP_DAYS: Array = [0, 4, 5, 6, 7, 7]
const MAX_LEVEL: int = 99                       # no real limit: there is always a room to add
const MAX_IMPROVING: int = 2          # homes being improved at once in one village
const LEVEL_NAMES: Array = ["", "cottage", "house", "fine house", "hall", "great hall", "manor"]
const OWNER_WAGE_DAYS: float = 10.0   # a business owner keeps this many days of wages per hand (and one more) before improving
## Servants: someone who owns the house they live in, once it is more than a cottage, keeps a
## servant when they can afford one (two in a hall or bigger). The servant is a household
## with no other work, paid the daily wage from the first day, who spends the day at the
## master's house. It is the other way profit goes back into the town, and a steady one.
const SERVANT_START_DAYS: float = 15.0   # wages in hand, beyond the owner's reserve, before taking one on
const STALL_DAYS: int = 20             # a half-built house with no wood or worker this long is given up
const WOOD_PILE_KEEP: float = 1.0     # builders only buy firewood above the full target: heating first
const HOUSE_ORIGIN := Vector2(440, 400)  # village-local spot of the first house
const HOUSE_COLS: int = 5
const HOUSE_DX: float = 44.0
const HOUSE_DY: float = 48.0

var village = null
var market = null
var event_bus = null
var houses: Array = []                # {id, owner, occupant, wood, work, done, unpaid, pos, node}
## Shop extensions under way (docs/SHOP_LEVELS.md): {id, owner, to_level, wood, wood_need,
## work, days_need, stall, idle_days, worker, node}. Built like a home improvement.
var shop_works: Array = []
var _next_shop_work: int = 1
var next_id: int = 1
var initialized: bool = false
var stats := {"servant_days": 0, "servant_wages": 0.0, "improve_started": 0, "improved": 0, "abandoned": 0, "idle_days": 0, "self_days": 0, "hired_days": 0, "moved_into_own": 0, "wages_paid": 0.0, "built": 0, "started": 0, "sold": 0, "rented_out": 0, "rent_paid": 0.0, "evicted": 0, "homeless_max": 0}


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
	var h := {"id": next_id, "owner": owner, "occupant": occupant, "wood": Tuning.i("house_logs", HOUSE_WOOD) if done else 0,
		"work": Tuning.i("house_build_days", BUILD_DAYS) if done else 0, "done": done, "unpaid": 0}
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
	return float(Tuning.i("house_logs", HOUSE_WOOD)) * (market.firewood_price if market else 1.0)


## A worker's wages for the days it takes to build.
func labour_cost() -> float:
	return float(Tuning.i("house_build_days", BUILD_DAYS)) * LaborMarket.daily_wage(market)


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


func improve_cost(level: int) -> float:
	var l: int = clampi(level, 1, UP_WOOD.size() - 1)
	return float(UP_WOOD[l]) * market.firewood_price + float(UP_DAYS[l]) * LaborMarket.daily_wage(market)


## "house", "hall", ... and past a manor "manor with 3 more rooms".
static func level_name(level: int) -> String:
	var top: int = LEVEL_NAMES.size() - 1
	if level <= top:
		return str(LEVEL_NAMES[maxi(1, level)])
	return "%s with %d more room%s" % [LEVEL_NAMES[top], level - top, "" if level - top == 1 else "s"]


## What `a` keeps back before spending on an improvement: the cushion, and for a business
## owner the money the business runs on.
func _reserve_of(a) -> float:
	var r: float = _keep_back(a)
	if not village.households.has(a):
		r += OWNER_WAGE_DAYS * LaborMarket.wage_of(a) * float(1 + LaborMarket.hands_of(a))
	return r


## What `a` holds back before putting coins into a house: the cushion, and for a merchant the
## coins they trade with. Merchants used to spend their whole purse on houses and home
## improvements, and then had 0 to 5 coins when the next town needed grain carried in.
func _keep_back(a) -> float:
	var k: float = cushion()
	if a != null and is_instance_valid(a) and a.has_meta("merchant") and Tuning.on("outside_help", true):
		k += Tuning.f("merchant_start_coins", MerchantJob.OWNER_CASH)
	return k


func can_afford_house(a) -> bool:
	return a != null and a.wallet != null and a.wallet.money >= house_value() + _keep_back(a)


## A household with no employer can do its own building work.
func _self_builder(a) -> bool:
	if a == null or not is_instance_valid(a) or not village.households.has(a) or a.has_meta("merchant"):
		return false
	return not (a.has_meta("employer") and is_instance_valid(a.get_meta("employer")))


## Money `a` needs before starting a house: the logs (and wages, unless they build it
## themselves) plus the cushion.
func can_afford_to_build(a) -> bool:
	if a == null or a.wallet == null:
		return false
	var cost: float = wood_cost() if _self_builder(a) else house_value()
	return a.wallet.money >= cost + _keep_back(a)


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
		return 0   # nobody arrives before the houses are handed out on day 1
	var homeless := 0
	for a in _people():
		if _home_of(a).is_empty():
			homeless += 1
	return _vacant().size() - homeless


func _pay(from, to, amount: float, invest: bool = false) -> bool:
	if from == null or from.wallet == null or from.wallet.money < amount:
		return false
	if invest:
		_invested(from, amount)
	from.wallet.debit(amount)
	from.cashflow_today_expense += amount   # rent, wages and house prices show in the day's books
	if to != null and is_instance_valid(to) and to.wallet:
		to.wallet.credit(amount)
		to.cashflow_today_income += amount
	elif market:
		market.money += amount   # the town's houses pay into the town purse
	return true


## Coins `a` has put into buildings. An employer's books count it as money kept, not lost
## (LaborMarket lets a hand go after days of falling cash; building is not a loss).
func _invested(a, amount: float) -> void:
	if a != null and is_instance_valid(a):
		a.set_meta("invested_total", float(a.get_meta("invested_total", 0.0)) + amount)


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
		for i in Tuning.i("houses_spare_at_start", START_SPARE):
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
			_release_servants(h, "their master is gone")
			if h.get("up") != null:
				_release_worker(h.up)
				h.up = null
			if h.done:
				h.owner = null
			else:
				_release_worker(h)
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
			_pay(a, null, price, true)
			h.owner = a
			stats.sold += 1
			_log("[HOUSING] day=%d %s bought house %d for $%.1f" % [day, a.name, h.id, price])
		else:
			stats.rented_out += 1
			_log("[HOUSING] day=%d %s rents house %d" % [day, a.name, h.id])
	stats.homeless_max = maxi(stats.homeless_max, homeless)

	# Rent. Everyone who lives in a house they do not own pays it, whatever they do for a
	# living (Anthony, 2026-11-13: "I only don't pay rent if I own the house"). Whoever can't
	# pay for RENT_DAYS_TO_LEAVE days leaves town, shop owners included. Until then people
	# with no work were asked no rent, and shop owners were never put out.
	var rent: float = rent_per_day()
	for h in houses:
		if not h.done or h.occupant == null or h.occupant == h.owner or not is_instance_valid(h.occupant):
			continue
		if h.owner != null and not is_instance_valid(h.owner):
			continue
		if _pay(h.occupant, h.owner, rent):
			stats.rent_paid += rent
			h.unpaid = 0
			continue
		h.unpaid += 1
		var a = h.occupant
		if h.unpaid >= RENT_DAYS_TO_LEAVE and village.labor_market:
			stats.evicted += 1
			_log("[HOUSING] day=%d %s leaving: %d days of rent unpaid ($%.1f)" % [day, a.name, h.unpaid, a.get_cash()])
			h.occupant = null
			h.unpaid = 0
			var had_shop: bool = not a.is_in_group("households")
			village.labor_market.migrate_requested.emit(a, "no_rent")
			if had_shop:
				village.labor_market._release_hands(a, "employer left")   # after the shop is noted empty (Recovery)

	# A renter who has saved the price buys the town house they live in.
	for h in houses:
		if not h.done or h.owner != null or h.occupant == null or _building_by(h.occupant):
			continue
		if can_afford_house(h.occupant):
			var price2: float = sale_price()
			if _pay(h.occupant, null, price2, true):
				h.owner = h.occupant
				h.unpaid = 0
				stats.sold += 1
				_log("[HOUSING] day=%d %s bought house %d, which they were renting, for $%.1f" % [day, h.owner.name, h.id, price2])

	# Building: buy the wood a bit at a time from what heating doesn't need, then 5 days of
	# work by one worker on site (see the top of this file).
	var wage: float = LaborMarket.daily_wage(market)
	for h in houses.duplicate():
		if h.done:
			continue
		var b = h.owner
		if b == null or not is_instance_valid(b):
			continue   # the owner died or left today; tomorrow's tidy-up drops the house
		if h.wood < Tuning.i("house_logs", HOUSE_WOOD):
			var spare: int = int(market.firewood - float(market.firewood_target) * WOOD_PILE_KEEP)
			var want: int = mini(Tuning.i("house_logs", HOUSE_WOOD) - h.wood, spare)
			var got: int = 0
			if want > 0:
				var wood_price: float = market.firewood_price
				got = market.sell_firewood_to_agent(b, want)
				h.wood += got
				b.cashflow_today_expense += float(got) * wood_price
				_invested(b, float(got) * wood_price)
			# A house that gets no wood for STALL_DAYS is given up, so it stops blocking others.
			h.stall = 0 if got > 0 else int(h.get("stall", 0)) + 1
			if int(h.stall) >= STALL_DAYS:
				_abandon(h, day, "no wood for %d days" % STALL_DAYS)
			continue
		var w = _worker_for(h, b, day)
		if w == null:
			h.idle_days = int(h.get("idle_days", 0)) + 1
			stats.idle_days += 1
			if int(h.idle_days) >= STALL_DAYS:
				_abandon(h, day, "no worker for %d days" % STALL_DAYS)
			continue
		if w != b:
			if not _pay(b, w, wage, true):
				_log("[HOUSING] day=%d %s can't pay %s's wage; work on house %d stops" % [day, b.name, w.name, h.id])
				_release_worker(h)
				stats.idle_days += 1
				continue
			stats.wages_paid += wage
		if w == b:
			stats.self_days += 1
		else:
			stats.hired_days += 1
		h.work += 1
		if h.work < Tuning.i("house_build_days", BUILD_DAYS):
			continue
		h.done = true
		_release_worker(h)
		stats.built += 1
		var old: Dictionary = _home_of(b)
		if old.is_empty() or old.owner != b:
			if not old.is_empty():
				old.occupant = null  # a renter moves into their own new house
				old.unpaid = 0
			h.occupant = b
			stats.moved_into_own += 1
			_log("[HOUSING] day=%d %s finished house %d and moved in" % [day, b.name, h.id])
		else:
			_log("[HOUSING] day=%d %s finished house %d to rent out" % [day, b.name, h.id])

	# Improvements under way: wood from what heating and house building leave, then work days.
	for h in houses:
		if h.get("up") == null:
			continue
		var up: Dictionary = h.up
		var ob = h.owner
		if ob == null or not is_instance_valid(ob):
			_release_worker(up)
			h.up = null
			continue
		if int(up.wood) < int(up.wood_need):
			var spare2: int = int(market.firewood - float(market.firewood_target) * WOOD_PILE_KEEP)
			var want2: int = mini(int(up.wood_need) - int(up.wood), spare2)
			var got2: int = 0
			if want2 > 0:
				var wp: float = market.firewood_price
				got2 = market.sell_firewood_to_agent(ob, want2)
				up.wood = int(up.wood) + got2
				ob.cashflow_today_expense += float(got2) * wp
				_invested(ob, float(got2) * wp)
			up.stall = 0 if got2 > 0 else int(up.stall) + 1
			if int(up.stall) >= STALL_DAYS:
				_log("[HOUSING] day=%d %s gives up improving house %d (no wood for %d days)" % [day, ob.name, h.id, STALL_DAYS])
				_release_worker(up)
				h.up = null
			continue
		var uw = _worker_for(up, ob, day)
		if uw == null:
			up.idle_days = int(up.idle_days) + 1
			stats.idle_days += 1
			continue
		if uw != ob:
			if not _pay(ob, uw, wage, true):
				_release_worker(up)
				stats.idle_days += 1
				continue
			stats.wages_paid += wage
			stats.hired_days += 1
		else:
			stats.self_days += 1
		up.work = int(up.work) + 1
		if int(up.work) >= int(up.days_need):
			_release_worker(up)
			h.level = int(h.get("level", 1)) + 1
			h.up = null
			stats.improved += 1
			_log("[HOUSING] day=%d %s finished improving house %d: it is now a %s" % [day, ob.name, h.id, level_name(int(h.level))])

	_shop_works(day, wage)

	_servants(day, wage)

	_sync_homes()

	if day % 5 == 0:
		var line := "[HOUSING] day=%d houses=%d empty=%d building=%d renters=%d homeless=%d built=%d evicted=%d" % [
			day, summary().houses, summary().empty, summary().building, summary().renters, homeless, stats.built, stats.evicted]
		print(line)
		_log(line)


# ── Shop extensions ──────────────────────────────────────────────────────────

## What it costs to take a shop from `level` to the next: the same logs and builder's days as
## improving a home from that level.
func shop_extend_cost(level: int) -> float:
	return improve_cost(level)


func extending_shop(owner) -> bool:
	for w in shop_works:
		if w.owner == owner:
			return true
	return false


## The owner of a full shop wants one more hand (LaborMarket._update_hands). They start an
## extension if they can pay for it and still keep the money the business runs on.
func start_shop_extension(owner, day: int) -> bool:
	if market == null or owner == null or not is_instance_valid(owner) or owner.wallet == null or extending_shop(owner):
		return false
	var lvl: int = LaborMarket.shop_level(owner)
	if lvl >= LaborMarket.SHOP_MAX_LEVEL or owner.wallet.money < shop_extend_cost(lvl) + _reserve_of(owner):
		return false
	var site = null
	var job = owner.get("current_job")
	if job != null:
		for key in ["bakery_location", "yard_location", "house_node"]:
			var spot = job.get(key)
			if spot != null and is_instance_valid(spot):
				site = spot
				break
	shop_works.append({"id": -_next_shop_work, "owner": owner, "to_level": lvl + 1, "node": site, "wood": 0, "work": 0, "worker": null, "idle_days": 0, "stall": 0,
		"wood_need": int(UP_WOOD[mini(lvl, UP_WOOD.size() - 1)]), "days_need": int(UP_DAYS[mini(lvl, UP_DAYS.size() - 1)])})
	_next_shop_work += 1
	stats["shops_started"] = int(stats.get("shops_started", 0)) + 1
	_log("[SHOP] day=%d %s starts extending the %s to hold %d hands ($%.1f in hand, about $%.0f to spend)" % [
		day, owner.name, shop_name(owner), LaborMarket.staff_room(owner) + 1, owner.get_cash(), shop_extend_cost(lvl)])
	return true


static func shop_name(owner) -> String:
	var role: String = str(owner.current_role) if owner != null and is_instance_valid(owner) else ""
	return str(Recovery.TRADES[role].shop) if Recovery.TRADES.has(role) else "shop"


## Extensions under way: logs from what heating leaves, then a builder's days, as for homes.
func _shop_works(day: int, wage: float) -> void:
	for w in shop_works.duplicate():
		var ob = w.owner
		if ob == null or not is_instance_valid(ob) or ob.is_queued_for_deletion() or not Recovery.TRADES.has(str(ob.current_role)):
			_release_worker(w)
			shop_works.erase(w)   # the owner is gone or closed the shop: the work is dropped
			continue
		if int(w.wood) < int(w.wood_need):
			var spare: int = int(market.firewood - float(market.firewood_target) * WOOD_PILE_KEEP)
			var want: int = mini(int(w.wood_need) - int(w.wood), spare)
			var got: int = 0
			if want > 0:
				var wp: float = market.firewood_price
				got = market.sell_firewood_to_agent(ob, want)
				w.wood = int(w.wood) + got
				ob.cashflow_today_expense += float(got) * wp
				_invested(ob, float(got) * wp)
			w.stall = 0 if got > 0 else int(w.stall) + 1
			if int(w.stall) >= STALL_DAYS:
				_log("[SHOP] day=%d %s gives up extending the %s (no wood for %d days)" % [day, ob.name, shop_name(ob), STALL_DAYS])
				_release_worker(w)
				shop_works.erase(w)
			continue
		var bw = _worker_for(w, ob, day)
		if bw == null:
			w.idle_days = int(w.idle_days) + 1
			continue
		if bw != ob:
			if not _pay(ob, bw, wage, true):
				_release_worker(w)
				continue
			stats.wages_paid += wage
			stats.hired_days += 1
		w.work = int(w.work) + 1
		if int(w.work) >= int(w.days_need):
			_release_worker(w)
			shop_works.erase(w)
			ob.set_meta("shop_level", int(w.to_level))
			stats["shops_extended"] = int(stats.get("shops_extended", 0)) + 1
			_log("[SHOP] day=%d %s finished extending the %s: level %d, room for %d hands" % [day, ob.name, shop_name(ob), int(w.to_level), LaborMarket.staff_room(ob)])


## Morning, before employers hire: at most one person decides to start a house today.
## (A household that starts its own is then busy with it and isn't taken on as a hand.)
func start_new_builds(day: int) -> void:
	if market == null or village == null or not initialized:
		return
	var people: Array = _people()
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
			if home.owner == null and not _self_builder(a):
				continue   # they buy the town house they rent instead (on_day)
			if can_afford_to_build(a):
				builder = a
				why = "a home of their own"
				break
		var pm = village.prosperity_meter
		if builder == null and _vacant().is_empty() and pm and pm.prosperity_score >= pm.PROSPERITY_THRESHOLD_TO_GROW:
			var best: float = house_value() + cushion()
			for a in people:
				var spare: float = (a.wallet.money - (_keep_back(a) - cushion())) if a.wallet else 0.0
				if a.wallet and spare >= best and not _building_by(a):
					best = spare
					builder = a
					why = "to rent out"
		if builder != null:
			var nh: Dictionary = _new_house(builder, null, false)
			if _self_builder(builder):
				# Busy with their own house from now on: nobody takes them on as a hand until
				# it is done (LaborMarket._free_hand skips builds_house).
				builder.set_meta("builds_house", nh.id)
			stats.started += 1
			_log("[HOUSING] day=%d %s starts a house %s ($%.1f)" % [day, builder.name, why, builder.get_cash()])

	# Improvements: the richest owner-occupier with money to spare starts one.
	var improving: int = 0
	for h in houses:
		if h.get("up") != null:
			improving += 1
	if Tuning.on("home_improvements", true) and improving < MAX_IMPROVING:
		var pick: Dictionary = {}
		var pick_cash: float = 0.0
		for h in houses:
			if not h.done or h.owner == null or h.occupant != h.owner or h.get("up") != null:
				continue
			var lvl: int = int(h.get("level", 1))
			var a = h.owner
			if lvl >= MAX_LEVEL or not is_instance_valid(a) or a.wallet == null or _building_by(a):
				continue
			if a.wallet.money >= improve_cost(lvl) + _reserve_of(a) and a.wallet.money > pick_cash:
				pick = h
				pick_cash = a.wallet.money
		if not pick.is_empty():
			var lv: int = int(pick.get("level", 1))
			pick.up = {"id": pick.id, "node": pick.get("node"), "wood": 0, "work": 0, "worker": null,
				"idle_days": 0, "stall": 0, "wood_need": int(UP_WOOD[mini(lv, UP_WOOD.size() - 1)]), "days_need": int(UP_DAYS[mini(lv, UP_DAYS.size() - 1)])}
			stats.improve_started += 1
			_log("[HOUSING] day=%d %s starts improving house %d into a %s ($%.1f in hand, about $%.0f to spend)" % [
				day, pick.owner.name, pick.id, level_name(lv + 1), pick_cash, improve_cost(lv)])



## Today's worker for house `h`: whoever already works on it if still free to, else the
## builder (a household with no employer), else the poorest person out of work. Null when
## nobody is free; the house then waits.
func _worker_for(h: Dictionary, b, day: int):
	var w = h.get("worker")
	if w != null and (not is_instance_valid(w) or not village.households.has(w) or (w.has_meta("employer") and is_instance_valid(w.get_meta("employer")))):
		_release_worker(h)
		w = null
	if w == null and _self_builder(b):
		w = b
	if w == null and village.labor_market:
		w = village.labor_market._free_hand()
	if w == null:
		return null
	if h.get("worker") != w:
		h.worker = w
		w.set_meta("builds_house", h.id)
		if w != b:
			w.set_meta("hired_builder", true)
		if w != b and w.has_method("log_event"):
			w.log_event("Hired by %s to build house %d at $%.2f a day." % [b.name, h.id, LaborMarket.daily_wage(market)])
		_log("[HOUSING] day=%d %s works on house %d for %s" % [day, w.name, h.id, "themselves" if w == b else b.name])
	if h.get("node") != null:
		_send_to_site(w, h.node)
	return w


func _abandon(h: Dictionary, day: int, why: String) -> void:
	_log("[HOUSING] day=%d house %d of %s given up (%s)" % [day, h.id, h.owner.name if h.owner != null and is_instance_valid(h.owner) else "?", why])
	_release_worker(h)
	if h.owner != null and is_instance_valid(h.owner) and h.owner.has_meta("builds_house") and int(h.owner.get_meta("builds_house")) == int(h.id):
		h.owner.remove_meta("builds_house")
	if h.get("node") != null and is_instance_valid(h.node):
		h.node.queue_free()
	houses.erase(h)
	stats.abandoned += 1


func _release_worker(h: Dictionary) -> void:
	var w = h.get("worker")
	h.worker = null
	if w == null or not is_instance_valid(w):
		return
	for k in ["builds_house", "hired_builder"]:
		if w.has_meta(k):
			w.remove_meta(k)
	_send_to_site(w, null)


## Point a worker's day at the building site (null: back to their own home).
func _send_to_site(w, spot) -> void:
	var j = w.get("current_job")
	if j is HouseholdJob:
		j.set_work_site(spot)


func servants_wanted(h: Dictionary) -> int:
	var lvl: int = int(h.get("level", 1))
	if not h.done or h.owner == null or h.occupant != h.owner or lvl < 2:
		return 0
	return 2 if lvl >= 4 else 1


func servant_count() -> int:
	var n: int = 0
	for h in houses:
		n += (h.get("servants", []) as Array).size()
	return n


func _release_servants(h: Dictionary, why: String) -> void:
	for s in h.get("servants", []):
		_release_servant(s, why)
	h.servants = []


func _release_servant(s, why: String) -> void:
	if s == null or not is_instance_valid(s):
		return
	for k in ["employer", "servant"]:
		if s.has_meta(k):
			s.remove_meta(k)
	_send_to_site(s, null)
	if s.has_method("log_event"):
		s.log_event("No longer a servant: %s." % why)


## Daily: pay each servant, let them go when the master cannot pay or has slipped under
## their reserve, and take one on when the master has money to spare and someone is free.
func _servants(day: int, wage: float) -> void:
	for h in houses:
		var kept: Array = []
		var master = h.owner
		var want: int = servants_wanted(h) if Tuning.on("servants", true) and master != null and is_instance_valid(master) else 0
		for s in h.get("servants", []):
			if s == null or not is_instance_valid(s) or not village.households.has(s) or s.get_meta("employer", null) != master:
				continue   # died, left, or changed trade
			if master == null or not is_instance_valid(master):
				_release_servant(s, "the master of the house is gone")   # died or left town
				continue
			if kept.size() >= want or master.wallet.money < _reserve_of(master) or not _pay(master, s, wage):
				_release_servant(s, "%s could no longer keep one" % master.name)
				_log("[SERVANT] day=%d %s lets %s go ($%.1f in hand)" % [day, master.name, s.name, master.get_cash()])
				continue
			stats.servant_days += 1
			stats.servant_wages += wage
			kept.append(s)
			_send_servant(s, h, master)
		if kept.size() < want and master.wallet != null \
				and master.wallet.money >= _reserve_of(master) + SERVANT_START_DAYS * wage * float(kept.size() + 1):
			var s2 = village.labor_market._free_hand() if village.labor_market else null
			if s2 != null and s2 != master and _pay(master, s2, wage):
				s2.set_meta("employer", master)
				s2.set_meta("servant", true)
				kept.append(s2)
				_send_servant(s2, h, master)
				stats.servant_days += 1
				stats.servant_wages += wage
				if s2.has_method("log_event"):
					s2.log_event("Taken on as a servant by %s at $%.2f a day." % [master.name, wage])
				_log("[SERVANT] day=%d %s takes on %s as a servant at $%.2f a day ($%.1f in hand)" % [day, master.name, s2.name, wage, master.get_cash()])
		h.servants = kept


func _send_servant(s, h: Dictionary, master) -> void:
	var j = s.get("current_job")
	if j is HouseholdJob and h.get("node") != null:
		j.set_work_site(h.node, "Keeping house for %s" % master.name)


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
	elif home.owner == null or not is_instance_valid(home.owner):
		parts.append("Rents house %d from the town ($%.2f a day)." % [home.id, rent_per_day()])
	else:
		parts.append("Rents house %d from %s ($%.2f a day)." % [home.id, home.owner.name, rent_per_day()])
	if not home.is_empty() and int(home.unpaid) > 0:
		parts.append("[color=#ff8844]%d day(s) behind on rent.[/color]" % home.unpaid)
	var let_out := 0
	for h in houses:
		if not h.done and h.owner == a:
			var wk = h.get("worker")
			var who: String = ""
			if wk != null and is_instance_valid(wk):
				who = ", building it themselves" if wk == a else ", %s working on it" % wk.name
			elif h.wood >= Tuning.i("house_logs", HOUSE_WOOD):
				who = ", waiting for a worker"
			parts.append("Building house %d: wood %d/%d, work %d/%d days%s." % [h.id, h.wood, Tuning.i("house_logs", HOUSE_WOOD), h.work, Tuning.i("house_build_days", BUILD_DAYS), who])
		elif h.done and h.owner == a and h.occupant != a:
			let_out += 1
	if let_out > 0:
		parts.append("Lets out %d house(s)." % let_out)
	if not home.is_empty() and home.owner == a:
		var lvl2: int = int(home.get("level", 1))
		if lvl2 > 1:
			parts.append("Their home is a %s." % level_name(lvl2))
		if home.get("up") != null:
			parts.append("Improving it into a %s: wood %d/%d, work %d/%d days." % [level_name(lvl2 + 1),
				int(home.up.wood), int(home.up.wood_need), int(home.up.work), int(home.up.days_need)])
	if a.has_meta("builds_house"):
		parts.append("Working on building house %d." % int(a.get_meta("builds_house")))
	if not home.is_empty() and home.owner == a and not (home.get("servants", []) as Array).is_empty():
		var names: Array = []
		for s in home.servants:
			if is_instance_valid(s):
				names.append(str(s.name))
		parts.append("Keeps a servant: %s." % ", ".join(names))
	parts.append("A house is worth $%.0f (wood $%.0f + 5 days' wages $%.0f)." % [house_value(), wood_cost(), labour_cost()])
	return " ".join(parts)
