extends Node
## Buyers-pay-makers test (docs/BUY_FROM_MAKERS.md). Runs the real game (Main.tscn, 10x) once
## and checks, with the town's own people and market:
##
##   - a maker who puts goods on the shelf is not paid for them then, and the town's purse
##     pays nothing;
##   - when someone buys, the whole payment goes to one maker, coin for coin, and none of it
##     to the town;
##   - with two makers' goods on the shelf, a buyer picks one stall, and over many sales both
##     makers sell;
##   - the same for wheat (baker pays farmer) and firewood (anyone pays the woodworker);
##   - goods of a maker who is gone pay the town's purse;
##   - no upkeep is paid to the town, and a farmer's seed comes from their own wheat;
##   - with the switch off, the market pays on delivery out of its own purse, as before.
##
##   godot --headless --fixed-fps 30 --path . res://scenes/TestMakers.tscn
## Exit code 0 when every check passes.


class Probe extends Node:
	var stage := 0
	var results := []
	var done := false
	var started_ms := 0
	var day0 := -1
	var purse_then := 0.0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		started_ms = Time.get_ticks_msec()

	func _check(label: String, ok: bool, detail: String = "") -> void:
		results.append(ok)
		print("[MAKERS TEST] %s %s%s" % ["PASS" if ok else "FAIL", label, "" if detail == "" else " (" + detail + ")"])

	func _near(a: float, b: float) -> bool:
		return absf(a - b) < 0.011

	## Staged: an empty shelf of `good`, so the only stalls are the ones the test sets up. (The
	## test's own deliveries pass is_survival, which lets them through whatever the shelf's state.)
	func _clear(m, good: String) -> void:
		m.set(good, 0)
		(m.shelf[good] as Dictionary).clear()

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
		if v.calendar == null or v.market == null or v.labor_market == null:
			return
		var day: int = v.calendar.day_index
		var m = v.market
		match stage:
			0:
				if day >= 3 and v.all_bakers.size() >= 2 and not v.all_farmers.is_empty() and not v.all_woodworkers.is_empty() and v.households.size() >= 2:
					_run_checks(v, m)
					purse_then = m.money
					day0 = day
					stage = 1
			1:
				if day >= day0 + 6:
					_check("six days of play: no upkeep or anything else reached the town's purse", m.money <= purse_then + 0.011,
						"%.2f then, %.2f now" % [purse_then, m.money])
					_check("makers were paid by buyers in play", float(m.paid_to_makers.bread) > 0.0 and float(m.paid_to_makers.wheat) > 0.0 and float(m.paid_to_makers.firewood) > 0.0,
						"bread %.0f, wheat %.0f, firewood %.0f coins" % [float(m.paid_to_makers.bread), float(m.paid_to_makers.wheat), float(m.paid_to_makers.firewood)])
					_check("nobody starved", v.starved_deaths == 0, "%d" % v.starved_deaths)
					_finish()

	func _run_checks(v, m) -> void:
		var b1 = v.all_bakers[0]
		var b2 = v.all_bakers[1]
		var farmer = v.all_farmers[0]
		var wood = v.all_woodworkers[0]
		var buyer = v.households[0]
		var buyer2 = v.households[1]
		buyer.wallet.credit(500.0)   # staged: buyers with coins
		buyer2.wallet.credit(500.0)
		# ── Bread: one maker ──
		_clear(m, "bread")
		b1.inv.items["bread"] = 10
		var cash1: float = b1.get_cash()
		var purse: float = m.money
		var put: int = m.buy_bread_from_agent(b1, 10, 0.0, true)
		_check("a baker who puts loaves on the shelf is not paid for them then", put == 10 and _near(b1.get_cash(), cash1) and _near(m.on_shelf("bread", b1), 10.0),
			"%d loaves put out, %.2f coins then and now" % [put, cash1])
		_check("and the town's purse pays nothing", _near(m.money, purse))
		var bcash: float = buyer.get_cash()
		var price: float = m.bread_price
		var got: int = m.sell_bread_to_household(buyer, 3)
		_check("when someone buys, the maker gets the whole payment, coin for coin", got == 3 and _near(bcash - buyer.get_cash(), 3.0 * price) and _near(b1.get_cash() - cash1, 3.0 * price)
			and _near(m.money, purse) and _near(m.on_shelf("bread", b1), 7.0),
			"buyer paid %.2f, the baker got %.2f, the town %.2f" % [bcash - buyer.get_cash(), b1.get_cash() - cash1, m.money - purse])
		# ── Bread: two stalls ──
		_clear(m, "bread")
		b1.inv.items["bread"] = 20
		b2.inv.items["bread"] = 20
		m.buy_bread_from_agent(b1, 20, 0.0, true)
		m.buy_bread_from_agent(b2, 20, 0.0, true)
		var c1: float = b1.get_cash()
		var c2: float = b2.get_cash()
		var one_stall: bool = true
		var spent: float = 0.0
		for i in 30:
			var before1: float = b1.get_cash()
			var before2: float = b2.get_cash()
			var bb: float = buyer.get_cash()
			if m.sell_bread_to_household(buyer, 1) != 1:
				break
			spent += bb - buyer.get_cash()
			var d1: float = b1.get_cash() - before1
			var d2: float = b2.get_cash() - before2
			# each loaf is paid to exactly one of the two
			one_stall = one_stall and ((_near(d1, m.bread_price) and _near(d2, 0.0)) or (_near(d2, m.bread_price) and _near(d1, 0.0)))
		_check("with two stalls, a buyer picks one and that baker gets all of it", one_stall)
		_check("over many sales both bakers sell, and every coin spent reached a baker", b1.get_cash() > c1 + 0.01 and b2.get_cash() > c2 + 0.01
			and _near((b1.get_cash() - c1) + (b2.get_cash() - c2), spent) and _near(m.money, purse),
			"one got %.2f, the other %.2f, of %.2f spent" % [b1.get_cash() - c1, b2.get_cash() - c2, spent])
		# ── Wheat and firewood: the same mechanic ──
		_clear(m, "wheat")
		farmer.inv.items["wheat"] = 12
		var fc: float = farmer.get_cash()
		var wput: int = m.buy_wheat_from_farmer(farmer, 0.0, false)
		var bc: float = b1.get_cash()
		var wgot: int = m.sell_wheat_to_baker(b1, 4)
		_check("a baker who buys wheat pays the farmer", wput > 0 and wgot == 4 and _near(farmer.get_cash() - fc, bc - b1.get_cash()) and bc - b1.get_cash() > 0.0 and _near(m.money, purse),
			"baker paid %.2f, farmer got %.2f" % [bc - b1.get_cash(), farmer.get_cash() - fc])
		_clear(m, "firewood")
		wood.inv.items["firewood"] = 12
		var wc: float = wood.get_cash()
		var fput: int = m.buy_firewood_from_agent(wood, 8, 0.0)
		var paid_now: bool = not _near(wood.get_cash(), wc)
		var b2c: float = buyer2.get_cash()
		var fgot: int = m.sell_firewood_to_agent(buyer2, 5)
		_check("someone who buys firewood pays the woodworker", fput == 8 and not paid_now and fgot == 5 and _near(wood.get_cash() - wc, b2c - buyer2.get_cash()) and b2c - buyer2.get_cash() > 0.0 and _near(m.money, purse),
			"buyer paid %.2f, woodworker got %.2f" % [b2c - buyer2.get_cash(), wood.get_cash() - wc])
		# ── Goods of someone who is gone ──
		_clear(m, "bread")
		m._shelve_for_test("bread", null, 4)
		var pc: float = m.money
		var bb2: float = buyer.get_cash()
		m.sell_bread_to_household(buyer, 2)
		_check("goods with no maker left to pay go to the town's purse", _near(m.money - pc, bb2 - buyer.get_cash()) and bb2 - buyer.get_cash() > 0.0,
			"%.2f coins" % (m.money - pc))
		# ── Seed from the farmer's own wheat ──
		_clear(m, "bread")   # staged: nothing of nobody's left on the shelf for the farmer to buy
		farmer.inv.items["seeds"] = 5
		farmer.inv.items["wheat"] = 30
		var fcash: float = farmer.get_cash()
		var pm: float = m.money
		farmer.current_job.handle_market_arrival()
		_check("a farmer short of seed keeps some back from their own wheat and pays nobody for it", farmer.inv.get_qty("seeds") >= 20 and _near(m.money, pm),
			"%d seeds now; town purse %.2f then, %.2f now" % [farmer.inv.get_qty("seeds"), pm, m.money])
		# ── Switch off: the old way ──
		Tuning.set_value("buy_from_makers", false)
		_clear(m, "bread")
		b1.inv.items["bread"] = 5
		var oc: float = b1.get_cash()
		var op: float = m.money
		var oput: int = m.buy_bread_from_agent(b1, 5, 0.0, true)
		_check("with the switch off, the market pays the baker on delivery from its own purse", oput == 5 and b1.get_cash() > oc + 0.01 and _near(b1.get_cash() - oc, op - m.money))
		Tuning.set_value("buy_from_makers", true)
		_clear(m, "bread")
		b1.inv.items["bread"] = 30
		m.buy_bread_from_agent(b1, 30, 0.0, true)   # leave the town bread to eat
		b2.inv.items["bread"] = 2

	func _finish() -> void:
		done = true
		Tuning.clear()
		Tuning.keep_on_restart = false
		var fails: int = results.count(false)
		print("[MAKERS TEST] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	Tuning.clear()
	Tuning.set_value("troubles", false)
	Tuning.set_value("arrival_prosperity_bar", 2.0)   # staged: nobody new comes during the test
	for pair in [["farmers", 1], ["bakers", 2], ["woodworkers", 1], ["others", 6], ["market_firewood", 60], ["market_wheat", 60], ["market_bread", 40]]:
		Tuning.set_value(str(pair[0]), pair[1])
	Tuning.source = "TestMakers"
	Tuning.keep_on_restart = true
	var probe := Probe.new()
	probe.name = "MakersProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
