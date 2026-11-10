class_name DevStart
extends RefCounted
## Dev mode: build the town a game starts with (docs/DEV_MODE.md).
##
## Runs once, right after the villages are made. The whole town stands still until it is
## ready: the clock waits and nobody walks or shops, so the numbers asked for are the numbers
## the first day starts with.
## People are added and given their trade through the same code the game uses when a
## newcomer arrives and when someone opens a shop, so the town that comes out is one the
## game could have reached by itself. Houses are handed out by Housing on the first morning,
## one for everybody who is there.

## With only a town size given, this is how the trades are split. One baker and one
## woodworker for every 12 people (each makes 12 a day and a person uses 1), one farmer for
## every 14 (farmers take on hands), and the land has room for 9 farmers at most.
const PEOPLE_PER_BAKER: int = 12
const PEOPLE_PER_WOODWORKER: int = 12
const PEOPLE_PER_FARMER: int = 14
const MAX_FARMERS: int = 9

## What each village was started with, for tests and the dev menu: village id -> summary.
static var report: Dictionary = {}


static func apply(world: Node) -> void:
	report = {}
	var tree: SceneTree = world.get_tree()
	var main: Node = world.get_parent()
	tree.paused = true
	# The first woodworker and the merchant arrive a frame after the village is made.
	for n in 4:
		await tree.process_frame
	var built: Array = []
	for v in world.villages:
		if v == null or not is_instance_valid(v):
			continue
		var s: Dictionary = Tuning.start_for(int(v.village_id))
		var notes: Array = await _build_people(v, s, tree)
		built.append([v, s, notes])
	# Coins, shelves, prices and prosperity last, for every village in one go.
	for b in built:
		_set_levels(b[0], b[1], b[2])
	world.set_meta("dev_start_done", true)
	var clock = main.get("clock") if main != null else null
	if clock != null:
		clock.running = true
	tree.paused = false


static func _others(v) -> Array:
	var out: Array = []
	for h in v.households:
		if h != null and is_instance_valid(h) and not h.has_meta("merchant") and str(h.current_role) != "Merchant":
			out.append(h)
	return out


static func _live(list: Array) -> Array:
	var out: Array = []
	for a in list:
		if a != null and is_instance_valid(a):
			out.append(a)
	return out


## The counts to build: the four that were asked for, or a split of "people".
static func targets(s: Dictionary, has_merchant: bool) -> Dictionary:
	var t: Dictionary = {
		"farmers": int(s.get("farmers", 1)), "bakers": int(s.get("bakers", 1)),
		"woodworkers": int(s.get("woodworkers", 1)), "others": int(s.get("others", 1))}
	var people: int = int(s.get("people", 0))
	if people > 0:
		var left: int = people - (1 if has_merchant else 0)
		if not s.has("farmers"):
			t.farmers = clampi(ceili(float(people) / float(PEOPLE_PER_FARMER)), 1, MAX_FARMERS)
		if not s.has("bakers"):
			t.bakers = maxi(1, ceili(float(people) / float(PEOPLE_PER_BAKER)))
		if not s.has("woodworkers"):
			t.woodworkers = maxi(1, ceili(float(people) / float(PEOPLE_PER_WOODWORKER)))
		if not s.has("others"):
			t.others = maxi(0, left - int(t.farmers) - int(t.bakers) - int(t.woodworkers))
	t.farmers = clampi(int(t.farmers), 0, MAX_FARMERS)
	return t


static func _set_coins(a, amount: float) -> void:
	if a == null or a.wallet == null:
		return
	var diff: float = amount - float(a.wallet.money)
	if diff > 0.0:
		a.wallet.credit(diff)
	elif diff < 0.0:
		a.wallet.debit(-diff)
	a.set_meta("purse_given", true)


static func _build_people(v, s: Dictionary, tree: SceneTree) -> Array:
	var notes: Array = []
	var wants_people: bool = false
	for k in ["people", "farmers", "bakers", "woodworkers", "others"]:
		if s.has(k):
			wants_people = true
	if wants_people:
		var has_merchant: bool = false
		for h in v.households:
			if h != null and is_instance_valid(h) and h.has_meta("merchant"):
				has_merchant = true
		var t: Dictionary = targets(s, has_merchant)
		var owners_now: int = _live(v.all_farmers).size() + _live(v.all_bakers).size() + _live(v.all_woodworkers).size()
		var need_total: int = int(t.farmers) + int(t.bakers) + int(t.woodworkers) + int(t.others)
		var cap: int = int(v.MAX_TOTAL_POP) - (1 if has_merchant else 0)
		if need_total > cap:
			notes.append("asked for %d people but the town holds %d: fewer people without a shop" % [need_total + (1 if has_merchant else 0), int(v.MAX_TOTAL_POP)])
			t.others = maxi(0, int(t.others) - (need_total - cap))
			need_total = int(t.farmers) + int(t.bakers) + int(t.woodworkers) + int(t.others)
		# 1. Bring in people until there are enough bodies.
		var guard: int = 0
		while owners_now + _others(v).size() < need_total and guard < 600:
			guard += 1
			var h = await v.spawn_household_at(v.get_spawn_point_for_role("household"))
			if h == null or not is_instance_valid(h):
				notes.append("could not bring in more people (stopped at %d)" % (owners_now + _others(v).size()))
				break
		# 2. Give trades to people with no shop, newest first.
		for role in ["farmer", "baker", "woodworker"]:
			var list: Array = v.all_farmers if role == "farmer" else (v.all_bakers if role == "baker" else v.all_woodworkers)
			var want: int = int(t[role + "s"])
			var tries: int = 0
			while _live(list).size() < want and tries < 200:
				tries += 1
				var pool: Array = _others(v)
				if pool.is_empty():
					notes.append("nobody left to become a %s" % role)
					break
				var who = pool[pool.size() - 1]
				var before: int = _live(list).size()
				v._perform_role_conversion(who, role, true)
				if _live(list).size() == before:
					notes.append("could not set up another %s (%d of %d)" % [role, before, want])
					break
				if who.wallet != null:
					var purse: float = Tuning.f("owner_start_coins", 150.0)
					if who.wallet.money < purse:
						who.wallet.credit(purse - who.wallet.money)
				if who.inv != null:
					who.inv.items["bread"] = maxi(2, who.inv.get_qty("bread"))
					who.inv.items["firewood"] = maxi(6, who.inv.get_qty("firewood"))
			# 3. Fewer than the town was made with: the extra ones leave.
			while _live(list).size() > want:
				var extra = _live(list)[_live(list).size() - 1]
				v.labor_market.migrate_requested.emit(extra, "dev start")
				await tree.process_frame
		while _others(v).size() > int(t.others):
			var pool2: Array = _others(v)
			v.labor_market.migrate_requested.emit(pool2[pool2.size() - 1], "dev start")
			await tree.process_frame
	return notes


static func _set_levels(v, s: Dictionary, notes: Array) -> void:
	# 4. Coins.
	if s.has("coins_owners"):
		for list2 in [v.all_farmers, v.all_bakers, v.all_woodworkers]:
			for a in _live(list2):
				_set_coins(a, float(s.coins_owners))
	if s.has("coins_others"):
		for a in _others(v):
			_set_coins(a, float(s.coins_others))
	# 5. The market.
	var m = v.market
	if m != null:
		if s.has("market_coins"):
			m.money = float(s.market_coins)
		if s.has("market_wheat"):
			m.wheat = int(s.market_wheat)
		if s.has("market_bread"):
			m.bread = int(s.market_bread)
		if s.has("market_firewood"):
			m.firewood = int(s.market_firewood)
		if s.has("bread_price"):
			m.bread_price = float(s.bread_price)
		if s.has("wheat_price"):
			m.wheat_price = float(s.wheat_price)
		if s.has("firewood_price"):
			m.firewood_price = float(s.firewood_price)
	# 6. Prosperity.
	if s.has("prosperity") and v.prosperity_meter != null:
		v.prosperity_meter.prosperity_score = float(s.prosperity)
		v.prosperity_meter.prosperity_raw = float(s.prosperity)
	var summary: Dictionary = {
		"farmers": _live(v.all_farmers).size(), "bakers": _live(v.all_bakers).size(),
		"woodworkers": _live(v.all_woodworkers).size(), "others": _others(v).size(),
		"people": int(v.pop_mgr.count()), "notes": notes}
	report[int(v.village_id)] = summary
	var line: String = "[DEV START] %s: %d people (%d farmers, %d bakers, %d woodworkers, %d with no shop)%s" % [
		str(v.village_name), int(summary.people), int(summary.farmers), int(summary.bakers), int(summary.woodworkers), int(summary.others),
		"" if notes.is_empty() else " | " + "; ".join(notes)]
	print(line)
	if v.event_bus != null:
		v.event_bus.emit_log(line)
