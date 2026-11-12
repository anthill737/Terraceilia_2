class_name Recovery
extends RefCounted
## How a town gets a farmer back (docs/RECOVERY.md). Three ways, each with a dev-mode switch:
##
## 1. farm_takeover: the land does not vanish with the farmer. The fields, the seed and the
##    farmhouse are still there, so when a town has no farmer someone takes the farm over the
##    next morning. No savings are needed, but the farm is not free (see "What the farm costs").
##    People who worked for the farmer come first, then people without work, then anyone else
##    with no shop.
## 2. hunger_switch: hunger moves people. With no farmer, someone who has coins for a loaf and
##    nothing to eat (none at home, none on the shelf) turns to farming. This is the only time
##    a shop owner changes trade. A town's only baker never does.
## 3. outside_help: when wheat stays dear, or a town has gone days with no farmer, a farmer
##    comes from outside with an owner's purse. (The other half of outside help is in
##    Housing._keep_back: merchants keep the coins they trade with, so they can carry grain in.)
##
## What the farm costs: whoever takes it, by any of the three ways, pays the town the same fee
## as for opening any shop (LaborMarket.STARTUP_COST, 50 coins), the way a new tenant paid an
## entry fine for a holding. They pay what they can at once, keeping KEEP_DAYS of bread and
## firewood in the purse, and the rest each morning out of what the farm earns.

const FARM_FIELDS: int = 2           # fields that go with a farm that is taken over
const CALL_PRICE: float = 1.25       # wheat at this many times its floor counts as dear
const CALL_DEAR_DAYS: int = 3        # dear this many days in a row before a farmer comes
const CALL_NO_FARMER_DAYS: int = 5   # or this many days with no farmer at all
const CALL_GAP_DAYS: int = 10        # at most one farmer from outside in this many days
const KEEP_DAYS: float = 3.0         # days of bread and firewood a new farmer keeps before paying the fee

var village = null
## People who worked for a farmer who is gone: first in line for the farm.
var heirs: Array = []
var days_without_farmer: int = 0
var dear_days: int = 0
var last_call_day: int = -999
var stats := {"takeovers": 0, "hunger_switches": 0, "farmers_called": 0, "fees_paid": 0.0}


func _log(line: String) -> void:
	if village != null and village.event_bus != null:
		village.event_bus.emit_log(line)


func _live(list: Array) -> Array:
	var out: Array = []
	for a in list:
		if a != null and is_instance_valid(a) and not a.is_queued_for_deletion():
			out.append(a)
	return out


## Called when someone dies or leaves, before their hands are released.
func remember_heirs(gone) -> void:
	if village == null or gone == null or not is_instance_valid(gone) or str(gone.current_role) != "Farmer":
		return
	for h in village.households:
		if h == null or not is_instance_valid(h) or h == gone or bool(h.get_meta("servant", false)):
			continue
		if h.has_meta("employer") and h.get_meta("employer") == gone and not heirs.has(h):
			heirs.append(h)


## Once a day, after the labour market's own update.
func on_day(day: int) -> void:
	if village == null or village.market == null:
		return
	var m = village.market
	for f in _live(village.all_farmers):
		if f.has_meta("farm_owed"):
			_pay_owed(f)
	var farmers: int = _live(village.all_farmers).size()
	days_without_farmer = days_without_farmer + 1 if farmers == 0 else 0
	dear_days = dear_days + 1 if m.wheat_price >= Market.WHEAT_PRICE_FLOOR * CALL_PRICE else 0
	heirs = _live(heirs)
	if farmers == 0:
		if Tuning.on("farm_takeover", true) and not village._free_fields().is_empty():
			var who = _takeover_candidate()
			if who != null:
				var was_heir: bool = heirs.has(who)
				var who_name: String = str(who.name)
				if _give_farm(who):
					_pay_owed(who)
					stats.takeovers += 1
					_log("[RECOVERY] day=%d %s takes over the empty farm (%s) and %s" % [day, who_name,
						"they worked those fields" if was_heir else "nobody was farming", _fee_words(who)])
					return
		if Tuning.on("hunger_switch", true):
			var hungry = _hungry_candidate()
			if hungry != null:
				var old_role: String = str(hungry.current_role).to_lower()
				var hungry_name: String = str(hungry.name)
				if _give_farm(hungry):
					_pay_owed(hungry)
					stats.hunger_switches += 1
					_log("[RECOVERY] day=%d %s, a %s with coins and nothing to eat, turns to farming and %s" % [day, hungry_name, old_role, _fee_words(hungry)])
					return
	if Tuning.on("outside_help", true) and day - last_call_day >= CALL_GAP_DAYS \
			and (dear_days >= CALL_DEAR_DAYS or days_without_farmer >= CALL_NO_FARMER_DAYS) and _room_for_farmer():
		_call_farmer(day)


## Hand `who` the farm: they become a farmer (free: nothing is built) and get the idle fields.
func _give_farm(who) -> bool:
	if who == null or not is_instance_valid(who) or who.has_meta("merchant"):
		return false
	village._perform_role_conversion(who, "farmer", true)
	if not village.all_farmers.has(who):
		return false
	var job = who.current_job
	var have: int = job.get_field_count() if job != null and job.has_method("get_field_count") else 1
	for fn in village._free_fields():
		if have >= FARM_FIELDS:
			break
		village._assign_field_to_farmer(fn, who)
		have += 1
	heirs.erase(who)
	who.set_meta("farm_owed", Tuning.f("shop_opening_fee", LaborMarket.STARTUP_COST))
	who.set_meta("farm_paid", 0.0)
	return true


## Pay the town what is owed for the farm, as far as the purse allows today.
func _pay_owed(who) -> void:
	var owed: float = float(who.get_meta("farm_owed", 0.0))
	var m = village.market
	if owed <= 0.0 or who.wallet == null or m == null:
		who.remove_meta("farm_owed")
		return
	var keep: float = KEEP_DAYS * (m.bread_price + m.firewood_price)
	var pay: float = clampf(who.wallet.money - keep, 0.0, owed)
	if pay > 0.0 and who.wallet.debit(pay):
		m.money += pay
		who.cashflow_today_expense += pay
		stats.fees_paid += pay
		who.set_meta("farm_paid", float(who.get_meta("farm_paid", 0.0)) + pay)
		owed -= pay
	if owed <= 0.005:
		who.remove_meta("farm_owed")
		if who.has_method("log_event"):
			who.log_event("Paid off the fee for the farm.")
	else:
		who.set_meta("farm_owed", owed)


func _fee_words(who) -> String:
	var paid: float = float(who.get_meta("farm_paid", 0.0))
	var owed: float = float(who.get_meta("farm_owed", 0.0))
	if owed <= 0.005:
		return "pays the town $%.0f for it" % paid
	return "pays the town $%.0f for it now, with $%.0f still owed" % [paid, owed]


static func _richest_first(a, b) -> bool:
	return a.get_cash() > b.get_cash()


## Who takes over an empty farm: the old farmer's hands, then people without work, then anyone
## else with no shop of their own. Within each group, whoever has the most coins.
func _takeover_candidate():
	var pool: Array = []
	for h in _live(village.households):
		if not h.has_meta("merchant"):
			pool.append(h)
	if pool.is_empty():
		return null
	var groups: Array = [[], [], []]
	for h in pool:
		if heirs.has(h):
			groups[0].append(h)
		elif village.labor_market != null and village.labor_market.is_idle(h):
			groups[1].append(h)
		else:
			groups[2].append(h)
	for g in groups:
		if not g.is_empty():
			g.sort_custom(_richest_first)
			return g[0]
	return null


func _nothing_to_eat(a) -> bool:
	var m = village.market
	if m == null or m.bread > 0 or a.inv == null or a.inv.get_qty("bread") > 0:
		return false
	return a.get_cash() >= m.bread_price


## Someone with coins for a loaf and nothing to eat. People with no shop first, then a
## woodworker or a baker when the town has another, then the last woodworker. Never the town's
## only baker: wheat is no use without one.
func _hungry_candidate():
	var groups: Array = [[], [], [], []]
	for h in _live(village.households):
		if not h.has_meta("merchant") and _nothing_to_eat(h):
			groups[0].append(h)
	var woods: Array = _live(village.all_woodworkers)
	var bakers: Array = _live(village.all_bakers)
	for w in woods:
		if _nothing_to_eat(w):
			groups[1 if woods.size() >= 2 else 3].append(w)
	if bakers.size() >= 2:
		for b in bakers:
			if _nothing_to_eat(b):
				groups[2].append(b)
	for g in groups:
		if not g.is_empty():
			g.sort_custom(_richest_first)
			return g[0]
	return null


func _room_for_farmer() -> bool:
	if village.pop_mgr != null and village.pop_mgr.is_at_pop_cap():
		return false
	if village._free_fields().is_empty() and village.all_field_nodes.size() >= int(village.MAX_FIELDS):
		return false
	if village.housing != null and Tuning.on("arrival_needs_free_house", true) and village.housing.free_slots() <= 0:
		return false
	return true


## A farmer comes from outside, with an owner's purse, and takes the idle fields (or ploughs one).
func _call_farmer(day: int) -> void:
	last_call_day = day
	var h = await village.spawn_household_at(village.get_spawn_point_for_role("farmer"))
	if h == null or not is_instance_valid(h):
		return
	var h_name: String = str(h.name)
	if not _give_farm(h):
		return
	var purse: float = Tuning.f("owner_start_coins", FarmerJob.STARTING_CASH)
	if h.wallet != null and h.wallet.money < purse:
		Village.note_brought(h, purse - h.wallet.money)
		h.wallet.credit(purse - h.wallet.money)
	_pay_owed(h)
	stats.farmers_called += 1
	_log("[RECOVERY] day=%d %s comes from outside to farm (wheat is $%.2f, %d days without a farmer) and %s" % [
		day, h_name, village.market.wheat_price, days_without_farmer, _fee_words(h)])
