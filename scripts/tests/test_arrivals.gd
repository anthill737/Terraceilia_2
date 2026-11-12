extends Node
## Who-arrives test (docs/WHO_ARRIVES.md). Runs the real game (Main.tscn, 10x) three times and
## checks that the town's own state decides who the next newcomer is:
##
##   1. A job is waiting (owners want hands and nobody is free): the newcomer comes looking for
##      work, with a newcomer's purse, and is taken on within days.
##   2. No job is waiting (people in town already lack work): the newcomer comes with the means
##      to open a shop (the savings plus the fee), and puts those coins to work: a shop, or a
##      house of their own.
##   3. The old rule, with the switch off: nobody comes while more than one person lacks work.
##
##   godot --headless --fixed-fps 30 --path . res://scenes/TestArrivals.tscn
## Exit code 0 when every check passes.


class Probe extends Node:
	var phase := 1
	var stage := 0
	var results := []
	var done := false
	var started_ms := 0
	var day0 := -1
	var people_then := 0
	var brought_then := 0.0
	var known := {}
	var newcomer = null
	var newcomer_name := ""
	var news: Array = []
	var hooked_world = null

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		started_ms = Time.get_ticks_msec()

	func _check(label: String, ok: bool, detail: String = "") -> void:
		results.append(ok)
		print("[ARRIVALS TEST] %s %s%s" % ["PASS" if ok else "FAIL", label, "" if detail == "" else " (" + detail + ")"])

	static func setup_phase(n: int) -> void:
		Tuning.clear()
		Tuning.set_value("troubles", false)
		Tuning.set_value("arrival_prosperity_bar", 2.0)   # staged: nobody comes until the test opens the gate
		Tuning.set_value("arrival_wait_days", 1)
		match n:
			1:
				pass   # the town as the game starts it: three shops and one person with no shop
			2:
				Tuning.set_value("houses_spare_at_start", 4)
				for pair in [["farmers", 1], ["bakers", 1], ["woodworkers", 1], ["others", 9], ["market_bread", 40], ["market_firewood", 40]]:
					Tuning.set_value(str(pair[0]), pair[1])
			3:
				Tuning.set_value("arrivals_follow_jobs", false)
				Tuning.set_value("houses_spare_at_start", 4)
				for pair in [["farmers", 1], ["bakers", 1], ["woodworkers", 1], ["others", 9], ["market_bread", 40], ["market_firewood", 40]]:
					Tuning.set_value(str(pair[0]), pair[1])
		Tuning.source = "TestArrivals"
		Tuning.keep_on_restart = true

	func _next_phase(main: Node) -> void:
		phase += 1
		stage = 0
		day0 = -1
		newcomer = null
		if phase > 3:
			_finish()
			return
		setup_phase(phase)
		main.get_node("DevMenu").restart()

	func _on_bus(msg: String) -> void:
		if msg.contains("[ARRIVAL]") or msg.contains("[DEATH]"):
			news.append(msg)
			print("[ARRIVALS TEST] town news: " + msg)

	func _everyone(v) -> Array:
		var out: Array = []
		for grp in [v.households, v.all_farmers, v.all_bakers, v.all_woodworkers]:
			for a in grp:
				if a != null and is_instance_valid(a):
					out.append(a)
		return out

	func _note_town(v) -> void:
		known = {}
		for a in _everyone(v):
			known[a.get_instance_id()] = true
		people_then = known.size()
		brought_then = v.coins_brought

	func _find_newcomer(v):
		for a in _everyone(v):
			if not known.has(a.get_instance_id()):
				return a
		return null

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
		if world == null or world.villages.size() < 2 or (Tuning.has_start() and not world.get_meta("dev_start_done", false)):
			return
		var clock = main.get("clock")
		if clock != null and clock.speed_multiplier < 10.0:
			clock.set_speed(10.0)
		var v = world.villages[0]
		if v.calendar == null or v.market == null or v.labor_market == null:
			return
		var day: int = v.calendar.day_index
		if hooked_world != world:
			hooked_world = world
			for vv in world.villages:
				vv.event_bus.event_logged.connect(_on_bus)
		match phase:
			1: _job_waiting(main, v, day)
			2: _no_job(main, v, day)
			3: _old_rule(main, v, day)

	# ── 1. A job is waiting: someone comes looking for work ─────────────────
	func _job_waiting(main: Node, v, day: int) -> void:
		var lm = v.labor_market
		match stage:
			0:
				if lm.job_waiting(day) and day >= 3:
					_check("owners want hands and nobody is free", lm.job_waiting(day) and lm.idle_count == 0, "%d jobs waiting, %d without work" % [lm.open_jobs, lm.idle_count])
					_note_town(v)
					Tuning.set_value("arrival_prosperity_bar", 0.0)   # the gate opens
					day0 = day
					stage = 1
				elif day > 60:
					_check("owners want hands and nobody is free", false, "no job was waiting by day %d" % day)
					_next_phase(main)
			1:
				if newcomer == null:
					newcomer = _find_newcomer(v)
					if newcomer != null:
						newcomer_name = str(newcomer.name)
						Tuning.set_value("arrival_prosperity_bar", 2.0)   # one newcomer is enough for the check
						_check("with a job waiting, the newcomer comes looking for work", int(v.arrivals.for_work) == 1 and int(v.arrivals.with_means) == 0
							and not newcomer.has_meta("came_with_means"), "%d for work, %d with means" % [int(v.arrivals.for_work), int(v.arrivals.with_means)])
						_check("they bring a newcomer's purse, not a shop owner's", newcomer.get_cash() <= HouseholdJob.STARTING_CASH + 12.0
							and v.coins_brought - brought_then <= HouseholdJob.STARTING_CASH + 0.01,
							"%.1f coins in hand, %.1f brought into town" % [newcomer.get_cash(), v.coins_brought - brought_then])
						day0 = day
					elif day > day0 + 5:
						_check("with a job waiting, the newcomer comes looking for work", false, "nobody came in 5 days")
						_next_phase(main)
				elif not is_instance_valid(newcomer):
					_check("the newcomer is taken on", false, "they are gone")
					_next_phase(main)
				elif (newcomer.has_meta("employer") and is_instance_valid(newcomer.get_meta("employer"))) or day > day0 + 5:
					var boss = newcomer.get_meta("employer") if newcomer.has_meta("employer") else null
					_check("the newcomer is taken on within days", boss != null and is_instance_valid(boss), "%s works for %s" % [newcomer_name, str(boss.name) if boss != null and is_instance_valid(boss) else "nobody"])
					_next_phase(main)

	# ── 2. No job is waiting: someone comes with the means to open a shop ───
	func _no_job(main: Node, v, day: int) -> void:
		var lm = v.labor_market
		match stage:
			0:
				if day >= 6:
					_check("people in town lack work and no job is waiting", not lm.job_waiting(day) and lm.idle_count >= 2, "%d jobs waiting, %d without work" % [lm.open_jobs, lm.idle_count])
					_note_town(v)
					Tuning.set_value("arrival_prosperity_bar", 0.0)
					day0 = day
					stage = 1
			1:
				if newcomer == null:
					newcomer = _find_newcomer(v)
					if newcomer != null:
						newcomer_name = str(newcomer.name)
						Tuning.set_value("arrival_prosperity_bar", 2.0)
						var purse: float = v.means_purse()
						_check("with no job waiting, the newcomer comes with means", int(v.arrivals.with_means) == 1 and int(v.arrivals.for_work) == 0
							and newcomer.has_meta("came_with_means"), "%d with means, %d for work" % [int(v.arrivals.with_means), int(v.arrivals.for_work)])
						_check("their purse is what a shop takes: the savings plus the fee", absf(purse - (LaborMarket.SAVINGS_BUFFER_REQUIRED + LaborMarket.STARTUP_COST)) < 0.01
							and newcomer.get_cash() >= purse - 12.0 and absf((v.coins_brought - brought_then) - purse) < 0.01,
							"%.1f coins in hand, %.1f brought into town" % [newcomer.get_cash(), v.coins_brought - brought_then])
						_check("the town news says why they came", not news.is_empty() and str(news[news.size() - 1]).contains("to set up in town"),
							str(news[news.size() - 1]).substr(0, 110) if not news.is_empty() else "no line")
						day0 = day
					elif day > day0 + 5:
						_check("with no job waiting, the newcomer comes with means", false, "nobody came in 5 days")
						_next_phase(main)
				else:
					var gone: bool = not is_instance_valid(newcomer)
					var shop: bool = not gone and str(newcomer.current_role) != "Household"
					var built: bool = not gone and (float(newcomer.get_meta("invested_total", 0.0)) > 0.0 or v.housing._building_by(newcomer)
						or v.housing._home_of(newcomer).get("owner", null) == newcomer)
					if gone or shop or built or day > day0 + 45:
						_check("they put the coins to work: a shop, or a house of their own", shop or built,
							"%s: %s" % [newcomer_name, "gone" if gone else ("opened a shop (%s)" % str(newcomer.current_role) if shop else ("has a house or is building one" if built else "still sitting on %.0f coins on day %d" % [newcomer.get_cash(), day]))])
						_check("nobody starved meanwhile", v.starved_deaths == 0, "%d" % v.starved_deaths)
						_next_phase(main)

	# ── 3. The old rule, switch off ─────────────────────────────────────────
	func _old_rule(main: Node, v, day: int) -> void:
		var lm = v.labor_market
		match stage:
			0:
				if day >= 6:
					_note_town(v)
					Tuning.set_value("arrival_prosperity_bar", 0.0)
					day0 = day
					stage = 1
			1:
				if day >= day0 + 6:
					_check("with the switch off, nobody comes while people lack work", lm.idle_count >= 2 and _find_newcomer(v) == null
						and int(v.arrivals.with_means) == 0, "%d without work, %d newcomers" % [lm.idle_count, int(v.arrivals.for_work) + int(v.arrivals.with_means)])
					_next_phase(main)

	func _finish() -> void:
		done = true
		Tuning.clear()
		Tuning.keep_on_restart = false
		var fails: int = results.count(false)
		print("[ARRIVALS TEST] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	Probe.setup_phase(1)
	var probe := Probe.new()
	probe.name = "ArrivalsProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
