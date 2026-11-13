class_name Recovery
extends RefCounted
## Empty shops (docs/RECOVERY.md). One mechanic for every trade a town has, now and later.
##
## A shop does not vanish with its owner. When an owner dies, leaves town, closes or changes
## trade, the shop stands empty: the fields, the oven, the saws are still there.
##
##   - When the town has nobody left in that trade, an empty shop is taken over the next
##     morning.
##   - A shop that was working when it lost its owner (they died or left town) is taken over
##     once the market has been short of what it makes for LaborMarket.OPEN_SHORT_DAYS, the
##     same signal that lets anyone open a new shop.
##   - A shop that closed for want of trade, whose owner changed trade, or whose owner was
##     broke when they died or left, is not handed on:
##     it is reopened the normal way, by someone with the savings to open a shop (they take
##     the empty one instead of building). Handing those on for nothing put 19 bakers in a
##     town of 46.
##
## Who takes it: people who worked in a shop of that trade whose owner is gone, then people
## without work, then anyone else with no shop. Within a group, whoever has the most coins.
## No savings are needed, because nothing has to be built, but it is not free: the new owner
## pays the town the usual fee for opening a shop (LaborMarket.STARTUP_COST), what they can at
## once, keeping KEEP_DAYS of bread and firewood in the purse plus what the shop needs to work
## for a day (a job says so with shop_stock_cost(): a baker's wheat and oven wood), and the
## rest each morning out of what the shop earns.
##
## Going without moves people: when the town has nobody in a trade and nobody without a shop
## takes the empty one, a shop owner who has coins and cannot buy what that trade gives the
## town (bread, firewood) takes it. This is the only time an owner changes trade.
##
## Nobody is sent from outside. Newcomers come the way they always do (the town's prosperity)
## and take an empty shop like anyone else in town.
##
## Dev-mode switches: farm_takeover (empty shops are taken over), hunger_switch (going
## without moves owners). Housing._keep_back (merchants keep the coins they trade with) is
## under outside_help.

## The trades a town has. A new trade is one more row; nothing else in this file names one.
##   list:   the village's list of that trade's owners
##   shop:   what its shop is called in the town news
##   lack:   what people go without when the town has nobody in the trade
##   rank:   food before warmth. The last owner of a trade leaves it only for an empty shop
##           of a lower rank number.
##   uses:   trades this shop cannot work without. The last owner of a trade never moves to a
##           shop that uses their goods, or whose goods their own shop uses.
##   fields: idle fields that go with the shop (a farm)
##   basic:  false for a trade a town can live without (a smith). Its empty shop is not
##           filled at once when the town has none; it waits until the trade would pay.
const TRADES: Dictionary = {
	"Farmer": {"list": "all_farmers", "shop": "farm", "lack": "bread", "rank": 0, "uses": [], "fields": 2},
	"Baker": {"list": "all_bakers", "shop": "bakery", "lack": "bread", "rank": 0, "uses": ["Farmer", "Woodworker"], "fields": 0},
	"Woodworker": {"list": "all_woodworkers", "shop": "lumber yard", "lack": "firewood", "rank": 1, "uses": [], "fields": 0},
	"Smith": {"list": "all_smiths", "shop": "smithy", "lack": "tools", "rank": 2, "uses": ["Woodworker"], "fields": 0, "basic": false},
}
## Trades whose shops wear tools out and buy new ones from the smith (docs/SMITH.md).
const USES_TOOLS: Array = ["Farmer", "Baker", "Woodworker"]
const KEEP_DAYS: float = 3.0         # days of bread and firewood a new owner keeps before paying the fee

var village = null
## Shops standing empty, by trade.
var empty: Dictionary = {}
## Of those, shops that were working when they lost their owner (the owner died or left).
var orphaned: Dictionary = {}
## People who worked in a shop whose owner is gone, by trade: first in line for it.
var heirs: Dictionary = {}
## The levels of the shops standing empty, by trade: an extension stays with the shop.
var levels: Dictionary = {}
var stats := {"takeovers": 0, "hunger_switches": 0, "fees_paid": 0.0}


func _log(line: String) -> void:
	if village != null and village.event_bus != null:
		village.event_bus.emit_log(line)


func _live(list: Array) -> Array:
	var out: Array = []
	for a in list:
		if a != null and is_instance_valid(a) and not a.is_queued_for_deletion():
			out.append(a)
	return out


func owners_of(role: String) -> Array:
	return _live(village.get(str(TRADES[role].list)))


func empty_shops(role: String) -> int:
	return int(empty.get(role, 0))


func orphaned_shops(role: String) -> int:
	return int(orphaned.get(role, 0))


## An owner is going: their shop stands empty. `working` is true when they died or left town
## (the shop was a going concern, and the people who worked there are remembered), false
## when they closed it or changed trade. Call before their hands are released.
func owner_gone(gone, working: bool = true) -> void:
	if village == null or gone == null or not is_instance_valid(gone):
		return
	var role: String = str(gone.current_role)
	if not TRADES.has(role) or gone.has_meta("shop_left"):
		return
	gone.set_meta("shop_left", true)
	empty[role] = empty_shops(role) + 1
	var lv: Array = levels.get(role, [])
	lv.append(LaborMarket.shop_level(gone))
	levels[role] = lv
	if gone.has_meta("shop_level"):
		gone.remove_meta("shop_level")
	# A shop that had ruined its owner was not a going concern, whatever took them in the end.
	# (Bakers who went broke and left town cold were counted as working shops and handed on
	# for nothing, again and again: 577 takeovers in eight towns.)
	if working and village.labor_market != null and village.labor_market._is_broke(gone):
		working = false
	if not working:
		return
	orphaned[role] = orphaned_shops(role) + 1
	var line: Array = heirs.get(role, [])
	for h in village.households:
		if h == null or not is_instance_valid(h) or h == gone or bool(h.get_meta("servant", false)):
			continue
		if h.has_meta("employer") and h.get_meta("employer") == gone and not line.has(h):
			line.append(h)
	heirs[role] = line


## Someone has a shop of their own from today, by any road: one empty shop of that trade,
## if there is one, is empty no longer.
func shop_opened(who) -> void:
	if who == null or not is_instance_valid(who):
		return
	if who.has_meta("shop_left"):
		who.remove_meta("shop_left")
	var role: String = str(who.current_role)
	if not TRADES.has(role) or empty_shops(role) <= 0:
		return
	empty[role] = empty_shops(role) - 1
	var lv: Array = levels.get(role, [])
	if not lv.is_empty():
		lv.sort()
		var best: int = int(lv.pop_back())   # the biggest empty shop is taken first
		levels[role] = lv
		if best > 1:
			who.set_meta("shop_level", best)
	orphaned[role] = maxi(0, orphaned_shops(role) - 1)   # the shop that was working goes first
	if orphaned_shops(role) == 0:
		heirs[role] = []


## Does the town have use for an empty shop of this trade today?
func _wanted(role: String, owners: int) -> bool:
	if owners == 0 and bool(TRADES[role].get("basic", true)):
		return true
	if orphaned_shops(role) <= 0:
		return false   # closed for want of trade: reopened the normal way, with savings
	var lm = village.labor_market
	return lm != null and int(lm._short_days.get(role, 0)) >= LaborMarket.OPEN_SHORT_DAYS


## Once a day, after the labour market's own update.
func on_day(day: int) -> void:
	if village == null or village.market == null:
		return
	for role in TRADES:
		for o in owners_of(role):
			if o.has_meta("shop_owed"):
				_pay_owed(o)
	for role in TRADES:
		heirs[role] = _live(heirs.get(role, []))
		if empty_shops(role) <= 0:
			continue
		var owners: int = owners_of(role).size()
		if not _wanted(role, owners):
			continue
		var shop: String = str(TRADES[role].shop)
		if Tuning.on("farm_takeover", true):
			var who = _takeover_candidate(role)
			if who != null:
				var why: String = "the town was short"
				if (heirs[role] as Array).has(who):
					why = "they worked there"
				elif owners == 0:
					why = "the town had no %s" % role.to_lower()
				var who_name: String = str(who.name)
				if _give_shop(who, role):
					_pay_owed(who)
					stats.takeovers += 1
					_log("[RECOVERY] day=%d %s takes over the empty %s (%s) and %s" % [day, who_name, shop, why, _fee_words(who)])
					continue
		if owners == 0 and Tuning.on("hunger_switch", true) and bool(TRADES[role].get("basic", true)):
			var needy = _going_without_candidate(role)
			if needy != null:
				var lack: String = str(TRADES[role].lack)
				var old_role: String = str(needy.current_role).to_lower()
				var needy_name: String = str(needy.name)
				if _give_shop(needy, role):
					_pay_owed(needy)
					stats.hunger_switches += 1
					_log("[RECOVERY] day=%d %s, a %s with coins and no %s to buy, takes the empty %s and %s" % [
						day, needy_name, old_role, lack, shop, _fee_words(needy)])


## Hand `who` an empty shop: they change trade (nothing is built, so no opening fee up front)
## and owe the town the fee.
func _give_shop(who, role: String) -> bool:
	if who == null or not is_instance_valid(who) or who.has_meta("merchant"):
		return false
	var t: Dictionary = TRADES[role]
	village._perform_role_conversion(who, role.to_lower(), true)
	if not (village.get(str(t.list)) as Array).has(who):
		return false
	var want: int = int(t.fields)
	if want > 0:
		var job = who.current_job
		var have: int = job.get_field_count() if job != null and job.has_method("get_field_count") else 1
		for fn in village._free_fields():
			if have >= want:
				break
			village._assign_field_to_farmer(fn, who)
			have += 1
	who.set_meta("shop_owed", Tuning.f("shop_opening_fee", LaborMarket.STARTUP_COST))
	who.set_meta("shop_paid", 0.0)
	return true


## Pay the town what is owed for the shop, as far as the purse allows today.
func _pay_owed(who) -> void:
	var owed: float = float(who.get_meta("shop_owed", 0.0))
	var m = village.market
	if owed <= 0.0 or who.wallet == null or m == null:
		who.remove_meta("shop_owed")
		return
	var keep: float = KEEP_DAYS * (m.bread_price + m.firewood_price)
	var job = who.get("current_job")
	if job != null and job.has_method("shop_stock_cost"):
		keep += float(job.shop_stock_cost())   # the coins the shop needs to work are not the town's to take
	var pay: float = clampf(who.wallet.money - keep, 0.0, owed)
	if pay > 0.0 and who.wallet.debit(pay):
		m.money += pay
		who.cashflow_today_expense += pay
		stats.fees_paid += pay
		who.set_meta("shop_paid", float(who.get_meta("shop_paid", 0.0)) + pay)
		owed -= pay
	if owed <= 0.005:
		who.remove_meta("shop_owed")
		if who.has_method("log_event"):
			who.log_event("Paid off the fee for the shop.")
	else:
		who.set_meta("shop_owed", owed)


func _fee_words(who) -> String:
	var paid: float = float(who.get_meta("shop_paid", 0.0))
	var owed: float = float(who.get_meta("shop_owed", 0.0))
	if owed <= 0.005:
		return "pays the town $%.0f for it" % paid
	return "pays the town $%.0f for it now, with $%.0f still owed" % [paid, owed]


static func _richest_first(a, b) -> bool:
	return a.get_cash() > b.get_cash()


## Who takes over an empty shop: people who worked there, then people without work, then
## anyone else with no shop of their own. Within each group, whoever has the most coins.
func _takeover_candidate(role: String):
	var line: Array = heirs.get(role, [])
	var groups: Array = [[], [], []]
	for h in _live(village.households):
		if h.has_meta("merchant"):
			continue
		if line.has(h):
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


## True when `a` has coins for `good` and there is none to be had: none at home, none on
## the market.
func _going_without(a, good: String) -> bool:
	var m = village.market
	if m == null or a.inv == null or m.good_stock(good) > 0 or a.inv.get_qty(good) > 0:
		return false
	return a.get_cash() >= m.good_price(good)


## Someone going without what the empty shop's trade gives the town. People with no shop
## first, then owners in a trade the town has another of, then the last owner of a trade that
## ranks below the empty shop's and has no tie to it (see TRADES).
func _going_without_candidate(role: String):
	var t: Dictionary = TRADES[role]
	var lack: String = str(t.lack)
	var groups: Array = [[], [], []]
	for h in _live(village.households):
		if not h.has_meta("merchant") and _going_without(h, lack):
			groups[0].append(h)
	for other in TRADES:
		if other == role:
			continue
		var o: Dictionary = TRADES[other]
		var own: Array = owners_of(other)
		var last: bool = own.size() <= 1
		if last and (int(o.rank) <= int(t.rank) or (t.uses as Array).has(other) or (o.uses as Array).has(role)):
			continue
		for a in own:
			if _going_without(a, lack):
				groups[2 if last else 1].append(a)
	for g in groups:
		if not g.is_empty():
			g.sort_custom(_richest_first)
			return g[0]
	return null
