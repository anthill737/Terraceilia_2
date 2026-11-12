extends Node
## Bread market test (docs/BREAD_MARKET.md). First the price rule on its own, then the real game
## (Main.tscn, 10x) with only the bread chain running (garden plots, servants, home
## improvements, merchants and troubles off):
##
##   1. The price engine as before, with two changes: an empty shelf where buyers went without
##      raises the price (by up to the 5% daily limit) instead of holding it, and bread and wheat
##      have no ceiling. The 1.00 floor and the bakers' 25% margin are unchanged.
##   2. A shortage (bread and wheat cleared out) raises the bread price the next morning; an
##      overfull shelf lowers it.
##   3. Over the run, bread is baked and sold, and the books balance: people's coins plus the
##      markets' purses change only by what newcomers brought and leavers took.
##
##   godot --headless --fixed-fps 30 --path . res://scenes/TestMarket.tscn
## Exit code 0 when every check passes.

const RUN_DAYS := 40


class Probe extends Node:
	var results := []
	var done := false
	var busy := false
	var stage := 0
	var books_start := -1.0
	var brought0 := 0.0
	var taken0 := 0.0
	var short_day := -1
	var short_price := 0.0
	var full_day := -1
	var full_price := 0.0
	var started_ms := 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		started_ms = Time.get_ticks_msec()

	func _check(label: String, ok: bool, detail: String = "") -> void:
		results.append(ok)
		print("[MARKET] %s %s%s" % ["PASS" if ok else "FAIL", label, "" if detail == "" else " (" + detail + ")"])

	func _near(a: float, b: float, tol: float = 0.001) -> bool:
		return absf(a - b) <= tol

	func _books(world: Node) -> Array:
		var total := 0.0
		var brought := 0.0
		var taken := 0.0
		for v in world.villages:
			total += v.market.money
			brought += v.coins_brought
			taken += v.coins_taken
			for group in [v.all_farmers, v.all_bakers, v.all_woodworkers, v.households]:
				for a in group:
					if a != null and is_instance_valid(a):
						total += a.get_cash()
		return [total, brought, taken]

	func _process(_d: float) -> void:
		if done or busy:
			return
		if Time.get_ticks_msec() - started_ms > 300000:
			_check("finished in time", false, "stage %d" % stage)
			_finish()
			return
		var main := get_tree().current_scene
		if main == null or main == self:
			return
		var world := main.get_node_or_null("World")
		if world == null or world.villages.size() < 2:
			return
		var clock = main.get("clock")
		if clock != null and clock.speed_multiplier < 10.0:
			clock.set_speed(10.0)
		var v = world.villages[0]
		if v.calendar == null or v.market == null or clock.tick < 6:
			return
		var m: Market = v.market
		var day: int = v.calendar.day_index
		match stage:
			0:
				_rule_checks(m)
				var b: Array = _books(world)
				books_start = b[0]
				brought0 = b[1]
				taken0 = b[2]
				stage = 1
			1:
				if day >= 12:
					# A shortage: no bread or wheat anywhere in the town tonight.
					m.bread = 0
					m.wheat = 0
					for list in [v.all_bakers, v.all_farmers, v.all_woodworkers, v.households]:
						for a in list:
							if a != null and is_instance_valid(a) and a.inv:
								a.inv.items["bread"] = mini(1, a.inv.get_qty("bread"))
								a.inv.items["wheat"] = 0
								a.inv.items["flour"] = 0
					short_day = day
					short_price = m.bread_price
					stage = 2
			2:
				if day > short_day:
					_check("a shortage raises the bread price the next morning", m.bread_price > short_price + 0.001,
						"%.2f -> %.2f" % [short_price, m.bread_price])
					stage = 3
			3:
				if day >= 24:
					m.bread = m.bread_capacity
					full_day = day
					full_price = m.bread_price
					stage = 4
			4:
				if day > full_day:
					_check("an overfull shelf lowers the bread price the next morning", m.bread_price < full_price - 0.001,
						"%.2f -> %.2f, shelf %d, target %d" % [full_price, m.bread_price, m.bread, m.bread_target])
					stage = 5
			5:
				if day >= RUN_DAYS:
					var t: Dictionary = m.totals
					_check("bread was baked and sold", int(t.bread_from_bakers) > 0 and int(t.bread_to_people) > 0,
						"%d baked into the market, %d sold to people" % [t.bread_from_bakers, t.bread_to_people])
					_check("wheat was grown and sold", int(t.wheat_from_farmers) > 0 and int(t.wheat_to_bakers) > 0,
						"%d from farmers, %d to bakers" % [t.wheat_from_farmers, t.wheat_to_bakers])
					var b2: Array = _books(world)
					var gap: float = (b2[0] - books_start) - ((b2[1] - brought0) - (b2[2] - taken0))
					_check("the books balance (coins only come with newcomers and go with leavers)", absf(gap) < 0.5,
						"gap %.3f coins; %.1f brought, %.1f taken" % [gap, b2[1] - brought0, b2[2] - taken0])
					_check("nobody starved", v.starved_deaths == 0 and world.villages[1].starved_deaths == 0,
						"%d and %d" % [v.starved_deaths, world.villages[1].starved_deaths])
					_finish()

	## The price rule on a market of its own (no town): bread target 18, so the low band is 15.
	func _price(good: String, price: float, stock: int, short: int) -> float:
		var m := Market.new()
		if good == "bread":
			m.bread_price = price
			m.bread = stock
			m.bread_short_today = short
			m._adjust_bread_price(1)
			var p: float = m.bread_price
			m.free()
			return p
		m.wheat_price = price
		m.wheat = stock
		m.wheat_short_today = short
		m._adjust_wheat_price(1)
		var w: float = m.wheat_price
		m.free()
		return w

	func _rule_checks(_m: Market) -> void:
		var lim: float = Market.MAX_DAILY_PRICE_CHANGE
		_check("an empty bread shelf with buyers going without raises the price", _near(_price("bread", 3.0, 0, 2), 3.0 * (1.0 + lim)), "%.3f" % _price("bread", 3.0, 0, 2))
		_check("so does an empty wheat shelf", _near(_price("wheat", 1.5, 0, 4), 1.5 * (1.0 + lim)), "%.3f" % _price("wheat", 1.5, 0, 4))
		_check("an empty shelf nobody asked at holds its price, as before", _near(_price("bread", 3.0, 0, 0), 3.0))
		_check("a shelf well over its band lowers the price, as before", _near(_price("bread", 3.0, 60, 0), 3.0 * (1.0 - lim)), "%.3f" % _price("bread", 3.0, 60, 0))
		_check("there is no ceiling on bread", _near(_price("bread", 50.0, 0, 1), 50.0 * (1.0 + lim)), "%.2f" % _price("bread", 50.0, 0, 1))
		_check("there is no ceiling on wheat", _near(_price("wheat", 20.0, 0, 1), 20.0 * (1.0 + lim)), "%.2f" % _price("wheat", 20.0, 0, 1))
		_check("the floor of 1.00 holds", _near(_price("bread", 1.02, 60, 0), 1.0) and _near(_price("wheat", 1.02, 90, 0), 1.0))
		var pp := ProductionProfitability.new()
		_check("bakers keep the 25% margin (batch 3)", _near(pp.minimum_profit_margin, 0.25))
		pp.free()

	func _finish() -> void:
		done = true
		Tuning.clear()
		Tuning.keep_on_restart = false
		var fails: int = results.count(false)
		print("[MARKET] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	# Only the bread chain: no garden plots, servants, home improvements, merchants or troubles.
	Tuning.clear()
	for k in ["gardens", "servants", "home_improvements", "merchants", "troubles"]:
		Tuning.set_value(k, false)
	Tuning.source = "TestMarket"
	Tuning.keep_on_restart = true
	var probe := Probe.new()
	probe.name = "MarketProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
