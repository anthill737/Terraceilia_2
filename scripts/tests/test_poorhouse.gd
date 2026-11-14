extends Node
## Poorhouse test (docs/POORHOUSE.md). Runs the real game (Main.tscn, 10x) once and checks,
## with the town's own people and market:
##
##   - someone with no work and nothing left moves into the poorhouse instead of leaving, and
##     gives up the house they rented;
##   - the town buys them a loaf and a log at the market price, paid to the baker and the
##     woodworker, and the town's purse pays exactly that;
##   - they pay no rent, do not take an empty house while they have no work, and so do not hold
##     one back from a newcomer;
##   - a resident with coins buys their own: the town pays nothing;
##   - a resident who is taken on stops being kept, and moves into the next empty house;
##   - with an empty town purse nobody is taken in, and a resident the town can't keep leaves;
##   - when every place is taken the next person leaves, and so does a resident the town can't
##     get a loaf for (an empty shelf);
##   - someone four days behind on rent with no work goes there too; a shop owner does not;
##   - with the switch off, someone with nothing left leaves town, as before;
##   - in play, someone who runs out of money is taken in by the day's own rules and is still
##     in town days later.
##
##   godot --headless --fixed-fps 30 --path . res://scenes/TestPoorhouse.tscn
## Exit code 0 when every check passes.


class Probe extends Node:
	var stage := 0
	var results := []
	var done := false
	var started_ms := 0
	var day0 := -1
	var left: Array = []          # [agent name, reason] for everyone who leaves
	var news: Array = []
	var hooked := false
	var play = null
	var play_name := ""
	var paid_then := 0.0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		started_ms = Time.get_ticks_msec()

	func _check(label: String, ok: bool, detail: String = "") -> void:
		results.append(ok)
		print("[POORHOUSE TEST] %s %s%s" % ["PASS" if ok else "FAIL", label, "" if detail == "" else " (" + detail + ")"])

	func _near(a: float, b: float) -> bool:
		return absf(a - b) < 0.011

	func _on_leave(a, reason: String) -> void:
		left.append([str(a.name) if is_instance_valid(a) else "?", reason])

	func _on_bus(msg: String) -> void:
		if msg.contains("[POORHOUSE]"):
			news.append(msg)
			print("[POORHOUSE TEST] town news: " + msg)

	func _left_as(a_name: String) -> String:
		for e in left:
			if e[0] == a_name:
				return str(e[1])
		return ""

	## Staged: an empty shelf of `good`, then `n` of the maker's own on it.
	func _stock(m, good: String, maker, n: int) -> void:
		m.set(good, 0)
		(m.shelf[good] as Dictionary).clear()
		maker.inv.items[good] = maker.inv.get_qty(good) + n
		if good == "bread":
			m.buy_bread_from_agent(maker, n, 0.0, true)
		else:
			m.buy_firewood_from_agent(maker, n, 0.0)

	## Staged: nothing left, no bread, a cold hearth.
	func _broke(a) -> void:
		a.wallet.debit(a.wallet.money)
		a.inv.items["bread"] = 0
		a.inv.items["firewood"] = 0

	func _idle(v) -> Array:
		var out: Array = []
		for a in v.households:
			if a != null and is_instance_valid(a) and v.labor_market.is_idle(a) and not Poorhouse.lives_there(a) and not a.has_meta("merchant"):
				out.append(a)
		return out

	func _process(_d: float) -> void:
		if done:
			return
		if Time.get_ticks_msec() - started_ms > 300000:
			_check("finished in time", false, "stage %d" % stage)
			_finish()
			return
		var main := get_tree().current_scene
		if main == null or main == self:
			return
		var world := main.get_node_or_null("World")
		if world == null or world.villages.size() < 2 or not world.get_meta("dev_start_done", false):
			return
		var clock = main.get("clock")
		if clock != null and clock.speed_multiplier < 10.0:
			clock.set_speed(10.0)
		var v = world.villages[0]
		if v.calendar == null or v.market == null or v.labor_market == null or v.poorhouse == null or v.housing == null:
			return
		if not hooked:
			hooked = true
			v.labor_market.migrate_requested.connect(_on_leave)
			v.event_bus.event_logged.connect(_on_bus)
		var day: int = v.calendar.day_index
		var m = v.market
		match stage:
			0:
				if day >= LaborMarket.STARTUP_GRACE_DAYS + 1 and v.housing.initialized and _idle(v).size() >= 9 \
						and not v.all_bakers.is_empty() and not v.all_woodworkers.is_empty():
					_run_checks(v, m, day)
					day0 = day
					stage = 1
			1:
				if day >= day0 + 1:
					var taken: bool = false
					for n in news:
						if n.contains(play_name + " moves into the poorhouse") or n.contains(play_name + " is kept by the town"):
							taken = true
					var hired: bool = is_instance_valid(play) and not v.labor_market.is_idle(play)
					_check("in play: someone who ran out of money is kept by the town (or taken on) instead of leaving", (taken or hired) and is_instance_valid(play) and v.households.has(play),
						"kept %s, taken on %s" % [str(taken), str(hired)])
					stage = 2
			2:
				if day >= day0 + 7:
					_check("six days later they are still in town, and nobody starved", is_instance_valid(play) and v.households.has(play) and v.starved_deaths == 0,
						"left as '%s', %d starved" % [_left_as(play_name), v.starved_deaths])
					_check("the town paid for keeping people in play", v.poorhouse.stats.paid > paid_then + 0.01,
						"%.2f then, %.2f now" % [paid_then, v.poorhouse.stats.paid])
					_finish()

	func _run_checks(v, m, day: int) -> void:
		var ph = v.poorhouse
		var hs = v.housing
		var lm = v.labor_market
		var baker = v.all_bakers[0]
		var wood = v.all_woodworkers[0]
		var idle: Array = _idle(v)
		var a = idle[0]
		var b = idle[1]
		var c = idle[2]
		var d = idle[3]
		var e = idle[4]
		var f = idle[5]
		var g = idle[6]
		var h = idle[7]
		var i = idle[8]
		m.money = maxf(m.money, 1000.0)   # staged: a town purse with coins in it
		# ── Taken in instead of leaving ──
		var home_a: Dictionary = hs._home_of(a)
		if not home_a.is_empty():
			home_a.owner = null   # staged: they rent it from the town
		_stock(m, "bread", baker, 10)
		_stock(m, "firewood", wood, 10)
		_broke(a)
		var purse: float = m.money
		var bc: float = baker.get_cash()
		var wc: float = wood.get_cash()
		var bp: float = m.bread_price
		var fp: float = m.firewood_price
		var gone: int = left.size()
		lm._update_cottagers(day)
		_check("someone with no work and nothing left moves into the poorhouse instead of leaving", Poorhouse.lives_there(a) and v.households.has(a) and _left_as(str(a.name)) == "",
			"left: %s" % str(left.slice(gone)))
		_check("and gives up the house they lived in", not home_a.is_empty() and home_a.occupant == null and hs._home_of(a).is_empty(),
			"house %s" % str(home_a.get("id", "none")))
		_check("the town buys them a loaf and a log at the market price", a.inv.get_qty("bread") == 1 and a.inv.get_qty("firewood") == 1 and _near(purse - m.money, bp + fp),
			"bread %d, firewood %d, purse paid %.2f for %.2f + %.2f" % [a.inv.get_qty("bread"), a.inv.get_qty("firewood"), purse - m.money, bp, fp])
		_check("paid to the baker and the woodworker, coin for coin", _near(baker.get_cash() - bc, bp) and _near(wood.get_cash() - wc, fp) and _near(a.get_cash(), 0.0),
			"baker +%.2f, woodworker +%.2f, resident holds %.2f" % [baker.get_cash() - bc, wood.get_cash() - wc, a.get_cash()])
		_check("and the house shows as lived in the poorhouse", hs.describe(a).contains("poorhouse"))
		# ── No rent, no house taken, no newcomer held back ──
		var slots_before: int = hs.free_slots()
		var vacant_before: int = hs._vacant().size()
		var a_cash: float = a.get_cash()
		hs.on_day(day)
		_check("a resident with no work pays no rent and does not take the empty house", Poorhouse.lives_there(a) and hs._home_of(a).is_empty() and _near(a.get_cash(), a_cash),
			"%d houses empty" % hs._vacant().size())
		_check("so the empty house is still free for a newcomer", vacant_before >= 1 and slots_before >= 1 and hs.free_slots() >= 1,
			"free slots %d before, %d after" % [slots_before, hs.free_slots()])
		# ── A resident with coins buys their own ──
		a.inv.items["bread"] = 0
		a.inv.items["firewood"] = 0
		a.wallet.credit(50.0)
		purse = m.money
		ph.keep(a, day)
		_check("a resident with coins buys their own: the town pays nothing", _near(m.money, purse) and a.inv.get_qty("bread") == 0)
		a.wallet.debit(a.wallet.money)
		# ── Taken on: no longer kept, takes the next empty house ──
		a.set_meta("employer", baker)
		purse = m.money
		ph.keep(a, day)
		_check("a resident who is taken on is not kept by the town any more", _near(m.money, purse) and a.inv.get_qty("bread") == 0)
		a.wallet.credit(20.0)
		hs.on_day(day)
		_check("and moves out into the next empty house", not Poorhouse.lives_there(a) and not hs._home_of(a).is_empty(),
			"house %s" % str(hs._home_of(a).get("id", "none")))
		a.remove_meta("employer")
		# ── An empty purse ──
		var kept_purse: float = m.money
		m.money = 0.0
		_broke(b)
		gone = left.size()
		lm._update_cottagers(day)
		_check("with an empty town purse nobody is taken in: they leave, as before", not Poorhouse.lives_there(b) and _left_as(str(b.name)) == "no_money")
		m.money = kept_purse
		_stock(m, "bread", baker, 10)
		_stock(m, "firewood", wood, 10)
		_broke(c)
		lm._update_cottagers(day)
		var c_in: bool = Poorhouse.lives_there(c) and v.households.has(c)
		_broke(c)
		kept_purse = m.money
		m.money = 0.0
		lm._update_cottagers(day)
		_check("a resident the town can no longer keep leaves", c_in and _left_as(str(c.name)) == "no_money")
		m.money = kept_purse
		# ── Behind on rent ──
		var home_d: Dictionary = hs._home_of(d)
		var dcash: float = 0.0
		if not home_d.is_empty():
			if home_d.owner == d:
				home_d.owner = null   # staged: they rent it from the town
			home_d.unpaid = Housing.RENT_DAYS_TO_LEAVE - 1
			d.wallet.debit(d.wallet.money)
			d.inv.items["bread"] = 3   # staged: bread in the house, so only the rent is behind
			dcash = d.get_cash()
		hs.on_day(day)
		_check("someone with no work four days behind on rent goes to the poorhouse", not home_d.is_empty() and Poorhouse.lives_there(d) and _left_as(str(d.name)) == "" and home_d.occupant != d,
			"house %s, cash %.2f" % [str(home_d.get("id", "none")), dcash])
		# ── Someone who owns the house they live in ──
		var home_g: Dictionary = hs._home_of(g)
		if not home_g.is_empty():
			home_g.owner = g
		_stock(m, "bread", baker, 10)
		_stock(m, "firewood", wood, 10)
		_broke(g)
		lm._update_cottagers(day)
		_check("someone who owns their house stays in it and is kept there", Poorhouse.lives_there(g) and not home_g.is_empty() and hs._home_of(g) == home_g
			and g.inv.get_qty("bread") == 1 and v.households.has(g), "house %s" % str(home_g.get("id", "none")))
		g.set_meta("employer", baker)
		ph.keep(g, day)
		_check("and once they have work the town stops keeping them", not Poorhouse.lives_there(g))
		g.remove_meta("employer")
		_check("a shop owner is not taken in", not ph.take_in(baker, day, "staged") and not Poorhouse.lives_there(baker))
		# ── A full poorhouse ──
		Tuning.set_value("poorhouse_places", ph.residents().size())
		_broke(h)
		lm._update_cottagers(day)
		_check("when every place in the poorhouse is taken, the next person with nothing left leaves", not Poorhouse.lives_there(h) and _left_as(str(h.name)) == "no_money",
			"%d places" % Poorhouse.places())
		Tuning.values.erase("poorhouse_places")
		# ── No bread on the shelf for the town to buy ──
		_stock(m, "bread", baker, 5)
		_broke(i)
		lm._update_cottagers(day)
		var i_in: bool = Poorhouse.lives_there(i)
		_broke(i)
		m.set("bread", 0)
		(m.shelf["bread"] as Dictionary).clear()
		lm._update_cottagers(day)
		_check("a resident the town can't get a loaf for (an empty shelf) leaves, as anyone with no bread and no coins would", i_in and _left_as(str(i.name)) == "no_money")
		# ── Switch off ──
		Tuning.set_value("poorhouse", false)
		_broke(e)
		lm._update_cottagers(day)
		_check("with the switch off, someone with nothing left leaves town, as before", not Poorhouse.lives_there(e) and _left_as(str(e.name)) == "no_money")
		Tuning.set_value("poorhouse", true)
		# ── Leave the town fed, then watch one in play ──
		_stock(m, "bread", baker, 40)
		_stock(m, "firewood", wood, 40)
		_broke(f)
		play = f
		play_name = str(f.name)
		paid_then = ph.stats.paid

	func _finish() -> void:
		done = true
		Tuning.clear()
		Tuning.keep_on_restart = false
		var fails: int = results.count(false)
		print("[POORHOUSE TEST] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	Tuning.clear()
	Tuning.set_value("troubles", false)
	Tuning.set_value("arrival_prosperity_bar", 2.0)   # staged: nobody new comes during the test
	for pair in [["farmers", 1], ["bakers", 1], ["woodworkers", 1], ["others", 15], ["houses_spare_at_start", 2], ["market_firewood", 60], ["market_wheat", 60], ["market_bread", 40]]:
		Tuning.set_value(str(pair[0]), pair[1])
	Tuning.source = "TestPoorhouse"
	Tuning.keep_on_restart = true
	var probe := Probe.new()
	probe.name = "PoorhouseProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
