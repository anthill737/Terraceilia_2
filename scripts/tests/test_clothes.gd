extends Node
## Clothes test (docs/CLOTHES.md). Runs the real game (Main.tscn, 10x) twice.
##
##   1. A normal game: no tailor and nothing on the shelf; everyone starts in clothes, partly
##      worn, and they wear out a little every day; a village this small could not keep a
##      tailor; with nobody making clothes, the price does not climb however many want them.
##   2. A town with a tailor: the tailor makes clothes and puts them out, people buy them and
##      the tailor is paid, not the town; a new set is worth it to someone with coins to spare
##      sooner than to someone with few, never before half worn, and never with the food money;
##      someone in rags gets through a frost on two logs, someone dressed on one; no two sets
##      last the same; someone with no work and no coins sews their own in five days, while a
##      hired hand has no time to; with the switch off, clothes do not wear.
##
##   godot --headless --fixed-fps 30 --path . res://scenes/TestClothes.tscn
## Exit code 0 when every check passes.


class Probe extends Node:
	var phase := 1
	var stage := 0
	var results := []
	var done := false
	var started_ms := 0
	var day0 := -1
	var watched = null
	var wear0 := 0.0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		started_ms = Time.get_ticks_msec()

	func _check(label: String, ok: bool, detail: String = "") -> void:
		results.append(ok)
		print("[CLOTHES TEST] %s %s%s" % ["PASS" if ok else "FAIL", label, "" if detail == "" else " (" + detail + ")"])

	func _near(a: float, b: float, tol: float = 0.011) -> bool:
		return absf(a - b) < tol

	func _set_cash(a, amount: float) -> void:
		var d: float = amount - a.get_cash()
		if d > 0.0:
			a.wallet.credit(d)
		elif d < 0.0:
			a.wallet.debit(-d)

	func _process(_d: float) -> void:
		if done:
			return
		if Time.get_ticks_msec() - started_ms > 360000:
			_check("finished in time", false, "phase %d stage %d" % [phase, stage])
			_finish()
			return
		var main := get_tree().current_scene
		if main == null or main == self:
			return
		var world := main.get_node_or_null("World")
		if world == null or world.villages.size() < 2 or (Tuning.has_start() and not world.get_meta("dev_start_done", false)):
			return
		var clock = main.get("clock")
		if clock != null and clock.speed_multiplier < 10.0:
			clock.set_speed(10.0)
		var v = world.villages[0]
		if v.calendar == null or v.market == null or v.labor_market == null or v.clothing == null:
			return
		var day: int = v.calendar.day_index
		match phase:
			1: _normal(main, v, day)
			2: _with_tailor(v, day)

	# ── 1. A normal game ─────────────────────────────────────────────────────────
	func _normal(main: Node, v, day: int) -> void:
		var m = v.market
		var cl = v.clothing
		match stage:
			0:
				if day >= 3:
					_check("a normal game starts with no tailor and no clothes on the shelf", v.all_tailors.is_empty() and m.has_good("clothes") and m.good_stock("clothes") == 0 and v.tailor_shop != null)
					var people: Array = cl.people()
					var ok := true
					var lo := 1.0
					var hi := 0.0
					for a in people:
						var w: float = Clothing.wear_of(a)
						ok = ok and a.has_meta("clothes_wear") and w < 1.0
						lo = minf(lo, w)
						hi = maxf(hi, w)
					_check("everyone starts in clothes, partly worn and not all alike", ok and people.size() >= 4 and hi - lo > 0.05, "%d people, wear %.2f to %.2f" % [people.size(), lo, hi])
					watched = people[0]
					wear0 = Clothing.wear_of(watched)
					var ce = v.households[0].get_node_or_null("CareerEvaluator") if not v.households.is_empty() else null
					var spend: Dictionary = cl.spending_per_day(m.good_price("clothes"))
					_check("a village this small could not keep a tailor", ce != null and v.labor_market._tailor_utility(ce) < 0.0,
						"it would buy %.2f sets a day, %.2f coins" % [float(spend.sets), float(spend.coins)])
					var g: Dictionary = m.goods["clothes"]
					var p: float = float(g.price)
					g.wanted_today = 5
					g.short_today = 5
					m._adjust_good_prices()
					_check("with nobody making clothes, wanting them does not push the price up", _near(m.good_price("clothes"), p), "%.2f then and now" % p)
					day0 = day
					stage = 1
			1:
				if day >= day0 + 2:
					var w2: float = Clothing.wear_of(watched) if is_instance_valid(watched) else -1.0
					_check("clothes wear out a little every day", _near(w2 - wear0, 2.0 / Clothing.LIFE_DAYS, 0.002), "%.3f then, %.3f two days later" % [wear0, w2])
					phase = 2
					stage = 0
					Tuning.clear()
					Tuning.set_value("troubles", false)
					Tuning.set_value("arrival_prosperity_bar", 2.0)   # staged: nobody new comes
					Tuning.set_value("home_improvements", false)
					for pair in [["farmers", 1], ["bakers", 1], ["woodworkers", 1], ["tailors", 1], ["others", 10], ["coins_others", 120.0], ["market_firewood", 70], ["market_wheat", 60], ["market_bread", 50]]:
						Tuning.set_value(str(pair[0]), pair[1])
					Tuning.source = "TestClothes"
					Tuning.keep_on_restart = true
					main.get_node("DevMenu").restart()

	# ── 2. A town with a tailor ──────────────────────────────────────────────────
	func _with_tailor(v, day: int) -> void:
		if v.all_tailors.is_empty():
			return
		var m = v.market
		var cl = v.clothing
		var lm = v.labor_market
		if day < 14:
			return
		var tailor = v.all_tailors[0]
		var g: Dictionary = m.goods["clothes"]
		_check("the tailor makes clothes and puts them out at the market", tailor.current_job is TailorJob and int(g["in"]) > 0, "%d sets put out" % int(g["in"]))
		_check("people buy them, and the buyers pay the tailor, not the town", int(cl.stats.bought) > 0 and float(m.paid_to_makers.clothes) > 0.0 and _near(float(m.paid_to_town.clothes), 0.0),
			"%d sets bought; %.1f coins to the tailor, %.1f to the town" % [int(cl.stats.bought), float(m.paid_to_makers.clothes), float(m.paid_to_town.clothes)])
		# Whether a new set is worth it, to whom, and when.
		var a = null
		var b = null
		for h in v.households:
			if h != null and is_instance_valid(h) and not h.has_meta("employer"):
				if a == null:
					a = h
				elif b == null:
					b = h
		if a == null or b == null:
			_check("two people with no work to stage", false)
			_finish()
			return
		var price: float = m.good_price("clothes")
		var keep: float = cl.keep_day()
		var cash_a: float = a.get_cash()
		var wear_a: float = Clothing.wear_of(a)
		_set_cash(a, 400.0)
		a.set_meta("clothes_wear", 1.0)
		var rich_rags: bool = cl.wants_clothes(a, price)
		a.set_meta("clothes_wear", 0.55)
		var rich_half: bool = cl.wants_clothes(a, price)
		a.set_meta("clothes_wear", 0.3)
		var rich_new: bool = cl.wants_clothes(a, price)
		var w_rich: float = cl.buy_at_wear(a, price)
		_set_cash(a, 2.0 * price)
		var w_thin: float = cl.buy_at_wear(a, price)
		_set_cash(a, Clothing.KEEP_DAYS * keep + price - 0.5)
		a.set_meta("clothes_wear", 1.0)
		var food_money: bool = cl.wants_clothes(a, price)
		_check("someone with coins to spare buys a new set once theirs is half worn, not before", rich_rags and rich_half and not rich_new)
		_check("a thin purse would sooner wear rags than pay; a full one replaces at half worn", w_thin > 1.0 and _near(w_rich, Clothing.MIN_WEAR), "%.2f worn against %.2f" % [w_thin, w_rich])
		_check("no clothes are bought with the food money", not food_money)
		_set_cash(a, cash_a)
		a.set_meta("clothes_wear", wear_a)
		# A frost.
		a.inv.items["firewood"] = 5
		b.inv.items["firewood"] = 5
		a.set_meta("clothes_wear", 0.2)
		b.set_meta("clothes_wear", 1.0)
		var extra: int = m.shock_extra_burn
		m.shock_extra_burn = 1
		lm._update_firewood(day)
		m.shock_extra_burn = extra
		_check("in a frost someone dressed burns one log and someone in rags two", a.inv.get_qty("firewood") == 4 and b.inv.get_qty("firewood") == 3,
			"%d and %d left of 5" % [a.inv.get_qty("firewood"), b.inv.get_qty("firewood")])
		# No two sets alike.
		cl._put_on_new(a)
		var life1: float = float(a.get_meta("clothes_life"))
		cl._put_on_new(a)
		var life2: float = float(a.get_meta("clothes_life"))
		var lo: float = Clothing.LIFE_DAYS * (1.0 - Clothing.LIFE_SPREAD) - 0.01
		var hi: float = Clothing.LIFE_DAYS * (1.0 + Clothing.LIFE_SPREAD) + 0.01
		_check("no two sets last quite the same", life1 >= lo and life1 <= hi and life2 >= lo and life2 <= hi and not _near(life1, life2, 0.0001), "%.1f and %.1f days" % [life1, life2])
		_check("nobody starved", v.starved_deaths == 0, "%d" % v.starved_deaths)
		# Making your own (staged: five mornings in a row).
		_set_cash(a, 0.0)
		a.set_meta("clothes_wear", 1.0)
		a.set_meta("sewing_days", 0)
		_set_cash(b, 0.0)
		b.set_meta("clothes_wear", 1.0)
		b.set_meta("sewing_days", 0)
		b.set_meta("employer", tailor)   # staged: b works for the tailor
		var sewn0: int = int(cl.stats.sewn)
		for i in Clothing.SEW_DAYS:
			cl.on_day(day)
		_check("someone with no work and no coins sews their own set in five days", Clothing.wear_of(a) < 0.1 and int(cl.stats.sewn) == sewn0 + 1,
			"worn %.2f, %d sewn" % [Clothing.wear_of(a), int(cl.stats.sewn) - sewn0])
		_check("a hired hand has no time to sew", Clothing.wear_of(b) >= 1.0)
		b.remove_meta("employer")
		# Switch off.
		Tuning.set_value("clothes", false)
		var wb: float = Clothing.wear_of(b)
		cl.on_day(day)
		_check("with the switch off clothes do not wear, and nobody counts as in rags", _near(Clothing.wear_of(b), wb) and Clothing.dressed(b))
		_finish()

	func _finish() -> void:
		done = true
		Tuning.clear()
		Tuning.keep_on_restart = false
		var fails: int = results.count(false)
		print("[CLOTHES TEST] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	Tuning.clear()
	Tuning.set_value("troubles", false)
	Tuning.set_value("arrival_prosperity_bar", 2.0)   # staged: nobody new comes during the test
	Tuning.source = "TestClothes"
	Tuning.keep_on_restart = true
	var probe := Probe.new()
	probe.name = "ClothesProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
