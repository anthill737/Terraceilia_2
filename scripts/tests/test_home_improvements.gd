extends Node
## Home improvements test (docs/HOUSING.md, "Home improvements"). Runs the real game
## (Main.tscn, 10x) once and checks, with the town's own people and houses:
##
##   - an owner living in their own cottage, with money to spare, starts improving it;
##   - a manor is as fine as a home gets: its owner, however rich, starts nothing more;
##   - a great hall's last step is finished by the day's own work and makes it a manor, and in
##     the days after that its rich owner never starts another step;
##   - the dev mode row home_top_level lets a manor take one more room when set higher;
##   - no home in town goes past a manor, and the inspector says the manor can't get finer.
##
##   godot --headless --fixed-fps 30 --path . res://scenes/TestHomeImprovements.tscn
## Exit code 0 when every check passes.


class Probe extends Node:
	var stage := 0
	var results := []
	var done := false
	var started_ms := 0
	var day0 := -1
	var day1 := -1
	var hall = null          # the owner of the great hall, staged in its last step
	var hall_home: Dictionary = {}
	var hall_restarted := false

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		started_ms = Time.get_ticks_msec()

	func _check(label: String, ok: bool, detail: String = "") -> void:
		results.append(ok)
		print("[HOME TEST] %s %s%s" % ["PASS" if ok else "FAIL", label, "" if detail == "" else " (" + detail + ")"])

	## Idle households living in a house they own.
	func _owners(v) -> Array:
		var out: Array = []
		for a in v.households:
			if a == null or not is_instance_valid(a) or a.has_meta("merchant") or not v.labor_market.is_idle(a):
				continue
			var h: Dictionary = v.housing._home_of(a)
			if not h.is_empty() and h.owner == a:
				out.append(a)
		return out

	## Staged: nothing being improved anywhere in town.
	func _clear_works(hs) -> void:
		for h in hs.houses:
			if h.get("up") != null:
				hs._release_worker(h.up)
				h.up = null

	func _top(hs) -> int:
		var top: int = 0
		for h in hs.houses:
			top = maxi(top, int(h.get("level", 1)))
		return top

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
		if v.calendar == null or v.market == null or v.labor_market == null or v.housing == null:
			return
		var hs = v.housing
		var day: int = v.calendar.day_index
		match stage:
			0:
				if day >= 3 and hs.initialized and _owners(v).size() >= 2:
					_run_checks(v, hs, day)
					day0 = day
					stage = 1
			1:
				if hall_home.get("up") == null and int(hall_home.get("level", 1)) >= Housing.MAX_LEVEL:
					_check("the great hall's last step is finished by the day's own work and makes it a manor",
						int(hall_home.level) == Housing.MAX_LEVEL and Housing.level_name(int(hall_home.level)) == "manor",
						"day %d, %s" % [day, Housing.level_name(int(hall_home.level))])
					day1 = day
					stage = 2
				elif day >= day0 + 5:
					var up = hall_home.get("up")
					_check("the great hall's last step is finished by the day's own work and makes it a manor", false,
						"still %s, %s" % [Housing.level_name(int(hall_home.get("level", 1))),
						"work dropped" if up == null else "wood %d/%d, work %d/%d" % [int(up.wood), int(up.wood_need), int(up.work), int(up.days_need)]])
					_finish()
			2:
				if hall_home.get("up") != null:
					hall_restarted = true
				if day >= day1 + 5:
					_check("in the five days after, its owner never starts another step, with %s coins in hand" % str(roundi(hall.get_cash())),
						not hall_restarted and int(hall_home.level) == Housing.MAX_LEVEL and hall.get_cash() > 10000.0)
					_check("no home in town has gone past a manor", _top(hs) <= Housing.MAX_LEVEL, "highest %s" % Housing.level_name(_top(hs)))
					var says: String = hs.describe(hall)
					_check("the inspector says the manor is as fine as a home gets", says.contains("manor, as fine as a home gets"), says)
					_finish()

	func _run_checks(v, hs, day: int) -> void:
		var people: Array = _owners(v)
		var a = people[0]
		var b = people[1]
		var home_a: Dictionary = hs._home_of(a)
		var home_b: Dictionary = hs._home_of(b)
		_check("the top step is a manor", Housing.top_level() == 6 and Housing.level_name(Housing.top_level()) == "manor")
		# ── A cottage owner with money to spare ──
		_clear_works(hs)
		home_a.level = 1
		a.wallet.credit(100000.0)
		var before: int = int(hs.stats.improve_started)
		hs.start_new_builds(day)
		_check("an owner living in their own cottage, with money to spare, starts improving it",
			home_a.get("up") != null and int(home_a.up.wood_need) == int(Housing.UP_WOOD[1]) and int(hs.stats.improve_started) > before,
			"%s, %d coins" % [a.name, roundi(a.get_cash())])
		# ── A manor owner, richer than anyone ──
		_clear_works(hs)
		home_a.level = Housing.MAX_LEVEL
		hs.start_new_builds(day)
		_check("a manor is as fine as a home gets: its owner, with 100,000 coins, starts nothing more",
			home_a.get("up") == null and not hs.can_improve(home_a))
		# ── The dev mode row ──
		Tuning.set_value("home_top_level", Housing.MAX_LEVEL + 1)
		_clear_works(hs)
		hs.start_new_builds(day)
		_check("with home_top_level set to 7, the manor's owner starts adding a room",
			home_a.get("up") != null and Housing.level_name(Housing.MAX_LEVEL + 1) == "manor with 1 more room")
		Tuning.values.erase("home_top_level")
		_clear_works(hs)
		# ── A great hall in its last step ──
		home_b.level = Housing.MAX_LEVEL - 1
		b.wallet.credit(100000.0)
		home_b.up = {"id": home_b.id, "node": home_b.get("node"), "wood": int(Housing.UP_WOOD[5]), "work": int(Housing.UP_DAYS[5]) - 1,
			"worker": null, "idle_days": 0, "stall": 0, "wood_need": int(Housing.UP_WOOD[5]), "days_need": int(Housing.UP_DAYS[5])}
		hall = b
		hall_home = home_b

	func _finish() -> void:
		done = true
		Tuning.clear()
		Tuning.keep_on_restart = false
		var fails: int = results.count(false)
		print("[HOME TEST] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	Tuning.clear()
	Tuning.set_value("troubles", false)
	Tuning.set_value("arrival_prosperity_bar", 2.0)   # staged: nobody new comes during the test
	for pair in [["farmers", 1], ["bakers", 1], ["woodworkers", 1], ["others", 10], ["houses_spare_at_start", 3], ["market_firewood", 80], ["market_wheat", 60], ["market_bread", 40]]:
		Tuning.set_value(str(pair[0]), pair[1])
	Tuning.source = "TestHomeImprovements"
	Tuning.keep_on_restart = true
	var probe := Probe.new()
	probe.name = "HomeProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
