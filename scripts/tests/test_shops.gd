extends Node
## Shop-level test (docs/SHOP_LEVELS.md). Runs the real game (Main.tscn, 10x) twice.
##
##   1. Each extra hired hand adds less than the one before. A shop as built holds two hands.
##      When it is full and another hand would pay, the owner has it extended: logs are bought
##      from the market, a builder is paid by the day, and the shop comes out a level higher
##      with room for one more hand, who is then taken on and raises what the shop makes.
##      The level stays with the shop when someone else takes it over.
##   2. With the switch off, a full shop is not extended.
##
## Staged: bread is kept dear and the shelf nearly bare, so a baker wants every hand they can get.
##
##   godot --headless --fixed-fps 30 --path . res://scenes/TestShops.tscn
## Exit code 0 when every check passes.


class Probe extends Node:
	var phase := 1
	var stage := 0
	var results := []
	var done := false
	var started_ms := 0
	var day0 := -1
	var baker = null
	var wood_out_then := 0
	var hired_days_then := 0
	var invested_then := 0.0
	var hooked_world = null

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		started_ms = Time.get_ticks_msec()

	func _check(label: String, ok: bool, detail: String = "") -> void:
		results.append(ok)
		print("[SHOPS TEST] %s %s%s" % ["PASS" if ok else "FAIL", label, "" if detail == "" else " (" + detail + ")"])

	static func setup_phase(n: int) -> void:
		Tuning.clear()
		Tuning.set_value("troubles", false)
		Tuning.set_value("gardens", true)   # staged: the old free plot, so the few people with no work live through the staged dear bread; this test is about something else
		Tuning.set_value("arrival_prosperity_bar", 2.0)   # staged: nobody new comes during the test
		Tuning.set_value("home_improvements", false)      # so the builders are free for the shop
		if n == 2:
			Tuning.set_value("shop_extensions", false)
		for pair in [["farmers", 1], ["bakers", 1], ["woodworkers", 1], ["others", 8], ["coins_owners", 900.0], ["market_firewood", 70], ["market_wheat", 80]]:
			Tuning.set_value(str(pair[0]), pair[1])
		Tuning.source = "TestShops"
		Tuning.keep_on_restart = true

	func _next_phase(main: Node) -> void:
		phase += 1
		stage = 0
		day0 = -1
		baker = null
		if phase > 2:
			_finish()
			return
		setup_phase(phase)
		main.get_node("DevMenu").restart()

	func _on_bus(msg: String) -> void:
		if msg.contains("[SHOP]") or msg.contains("[DEATH]") or msg.contains("[RECOVERY]"):
			print("[SHOPS TEST] town news: " + msg)

	func _near(a: float, b: float) -> bool:
		return absf(a - b) < 0.001

	func _process(_d: float) -> void:
		if done:
			return
		if Time.get_ticks_msec() - started_ms > 480000:
			_check("finished in time", false, "phase %d stage %d" % [phase, stage])
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
		if v.calendar == null or v.market == null or v.labor_market == null or v.housing == null:
			return
		var day: int = v.calendar.day_index
		if hooked_world != world:
			hooked_world = world
			for vv in world.villages:
				vv.event_bus.event_logged.connect(_on_bus)
		if day >= 2:
			# Staged: bread dear and the shelf nearly bare.
			v.market.bread_price = 7.0
			v.market.bread = mini(v.market.bread, 6)
		if baker == null or not is_instance_valid(baker):
			baker = v.all_bakers[0] if not v.all_bakers.is_empty() else null
		if baker == null:
			return
		match phase:
			1: _grows(main, v, day)
			2: _switch_off(main, v, day)

	# ── 1. A full shop that wants another hand is extended ──────────────────
	func _grows(main: Node, v, day: int) -> void:
		var m = v.market
		match stage:
			0:
				if day >= 2:
					var g1: float = LaborMarket.hand_gain(baker, 1)
					var g2: float = LaborMarket.hand_gain(baker, 2)
					var g3: float = LaborMarket.hand_gain(baker, 3)
					_check("each extra hand adds less than the one before", _near(g1, 0.5) and _near(g2, 0.4) and _near(g3, 0.32)
						and _near(LaborMarket.hand_mult_n(baker, 3), 2.22), "%.2f, %.2f, %.2f of what the owner makes alone" % [g1, g2, g3])
					var farmer = v.all_farmers[0] if not v.all_farmers.is_empty() else null
					_check("a farm hand works a field of their own: a whole share, then less", farmer != null and _near(LaborMarket.hand_gain(farmer, 1), 1.0)
						and _near(LaborMarket.hand_gain(farmer, 2), 0.8))
					baker.set_meta("shop_level", 9)
					var top_room: int = LaborMarket.staff_room(baker)
					baker.remove_meta("shop_level")
					_check("a shop as built holds two hands, and the top level (6) holds seven", LaborMarket.staff_room(baker) == 2 and LaborMarket.shop_level(baker) == 1 and top_room == 7,
						"%d as built, %d at the top" % [LaborMarket.staff_room(baker), top_room])
					day0 = day
					stage = 1
			1:
				if LaborMarket.hands_of(baker) >= 2 or day > day0 + 10:
					_check("the baker fills both places", LaborMarket.hands_of(baker) == 2, "%d hands on day %d" % [LaborMarket.hands_of(baker), day])
					wood_out_then = int(m.totals.firewood_out)
					hired_days_then = int(v.housing.stats.hired_days)
					invested_then = float(baker.get_meta("invested_total", 0.0))
					day0 = day
					stage = 2
			2:
				if v.housing.extending_shop(baker) or day > day0 + 6:
					_check("full and wanting another hand, the owner starts an extension", v.housing.extending_shop(baker) and LaborMarket.shop_level(baker) == 1,
						"day %d, %d days after the shop was full" % [day, day - day0])
					day0 = day
					stage = 3
			3:
				if LaborMarket.shop_level(baker) >= 2 or day > day0 + 25:
					var spent: float = float(baker.get_meta("invested_total", 0.0)) - invested_then
					_check("the extension is built: the shop is level 2 with room for three", LaborMarket.shop_level(baker) == 2 and LaborMarket.staff_room(baker) == 3 and not v.housing.extending_shop(baker),
						"level %d after %d days" % [LaborMarket.shop_level(baker), day - day0])
					_check("logs were bought from the market and a builder was paid by the day", int(m.totals.firewood_out) - wood_out_then >= 10
						and int(v.housing.stats.hired_days) - hired_days_then >= 4 and spent > 0.0,
						"%d logs left the woodpile, %d builder days, %.0f coins put in" % [int(m.totals.firewood_out) - wood_out_then, int(v.housing.stats.hired_days) - hired_days_then, spent])
					day0 = day
					stage = 4
			4:
				if LaborMarket.hands_of(baker) >= 3 or day > day0 + 8:
					_check("a third hand is taken on", LaborMarket.hands_of(baker) == 3, "%d hands on day %d" % [LaborMarket.hands_of(baker), day])
					var want: int = maxi(1, roundi(12.0 * m.oven_mult * m.shock_oven_mult * LaborMarket.hand_mult(baker)))
					_check("and the bakery makes more for it", baker.current_job._oven_capacity() == want and want > roundi(12.0 * LaborMarket.hand_mult_n(baker, 2)),
						"%d loaves a day with three hands, %d with two" % [baker.current_job._oven_capacity(), roundi(12.0 * m.oven_mult * m.shock_oven_mult * LaborMarket.hand_mult_n(baker, 2))])
					# Staged: the baker is gone; the bakery is taken over the next morning.
					v.labor_market.migrate_requested.emit(baker, "staged for the test")
					baker = null
					day0 = day
					stage = 5
			5:
				if day >= day0 + 2:
					var nb = v.all_bakers[0] if not v.all_bakers.is_empty() else null
					_check("the level stays with the shop when someone takes it over", nb != null and LaborMarket.shop_level(nb) == 2 and LaborMarket.staff_room(nb) == 3,
						"%s has a level %d bakery" % [str(nb.name) if nb != null else "nobody", LaborMarket.shop_level(nb) if nb != null else 0])
					_check("nobody starved", v.starved_deaths == 0, "%d" % v.starved_deaths)
					_next_phase(main)

	# ── 2. Switch off: a full shop stays as it is ───────────────────────────
	func _switch_off(main: Node, v, day: int) -> void:
		match stage:
			0:
				if LaborMarket.hands_of(baker) >= 2 or day > 14:
					day0 = day
					stage = 1
			1:
				if day >= day0 + 8:
					_check("with the switch off, a full shop is not extended", LaborMarket.hands_of(baker) == 2 and not v.housing.extending_shop(baker) and LaborMarket.shop_level(baker) == 1,
						"%d hands, level %d" % [LaborMarket.hands_of(baker), LaborMarket.shop_level(baker)])
					_next_phase(main)

	func _finish() -> void:
		done = true
		Tuning.clear()
		Tuning.keep_on_restart = false
		var fails: int = results.count(false)
		print("[SHOPS TEST] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	Probe.setup_phase(1)
	var probe := Probe.new()
	probe.name = "ShopsProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
