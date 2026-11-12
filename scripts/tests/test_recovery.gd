extends Node
## Recovery test (docs/RECOVERY.md). Runs the real game (Main.tscn, 10x) three times, each time
## with only one of the three ways a town gets a farmer back switched on, takes the farmer away
## on purpose, and checks that way works on its own:
##
##   1. farm_takeover: the next morning someone has the farm. A person who worked for the old
##      farmer comes first. Nothing is paid and no purse is handed out; both fields go with it;
##      wheat is being sold again within days.
##   2. hunger_switch: in a town of owners only, with no bread anywhere, a woodworker with coins
##      turns to farming. The town's only baker stays a baker.
##   3. outside_help: merchants hold back the coins they trade with; with wheat dear a farmer
##      comes from outside with an owner's purse; a merchant carries bread or wheat in.
##
##   godot --headless --fixed-fps 30 --path . res://scenes/TestRecovery.tscn
## Exit code 0 when every check passes.


class Probe extends Node:
	var phase := 1
	var stage := 0
	var results := []
	var done := false
	var busy := false
	var started_ms := 0
	var day0 := -1
	var hands: Array = []
	var cash_then := {}
	var brought_then := 0.0
	var wheat_then := 0
	var merchant_lines: Array = []
	var hooked_world = null

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		started_ms = Time.get_ticks_msec()

	func _check(label: String, ok: bool, detail: String = "") -> void:
		results.append(ok)
		print("[RECOVERY TEST] %s %s%s" % ["PASS" if ok else "FAIL", label, "" if detail == "" else " (" + detail + ")"])

	static func setup_phase(n: int) -> void:
		Tuning.clear()
		Tuning.set_value("troubles", false)
		for k in ["farm_takeover", "hunger_switch", "outside_help"]:
			Tuning.set_value(k, false)
		match n:
			1:
				Tuning.set_value("farm_takeover", true)
				for pair in [["farmers", 1], ["bakers", 1], ["woodworkers", 1], ["others", 6], ["market_bread", 30], ["market_wheat", 30]]:
					Tuning.set_value(str(pair[0]), pair[1])
			2:
				Tuning.set_value("hunger_switch", true)
				Tuning.set_value("merchants", false)
				for pair in [["farmers", 1], ["bakers", 1], ["woodworkers", 2], ["others", 0]]:
					Tuning.set_value(str(pair[0]), pair[1])
			3:
				Tuning.set_value("outside_help", true)
				for pair in [["farmers", 1], ["bakers", 1], ["woodworkers", 1], ["others", 5], ["market_bread", 60]]:
					Tuning.set_value(str(pair[0]), pair[1])
		Tuning.source = "TestRecovery"
		Tuning.keep_on_restart = true

	func _next_phase(main: Node) -> void:
		phase += 1
		stage = 0
		day0 = -1
		if phase > 3:
			_finish()
			return
		setup_phase(phase)
		main.get_node("DevMenu").restart()

	func _remove_farmers(v) -> void:
		for f in v.all_farmers.duplicate():
			if f != null and is_instance_valid(f):
				v.labor_market.migrate_requested.emit(f, "staged for the test")

	func _on_bus(msg: String) -> void:
		if msg.contains("[DEATH]") or msg.contains("[RECOVERY]"):
			print("[RECOVERY TEST] town news: " + msg)
		if msg.contains("[MERCHANT]") and msg.contains(" sold ") and msg.contains("in Village 1") and (msg.contains(" bread ") or msg.contains(" wheat ")):
			merchant_lines.append(msg)

	func _process(_d: float) -> void:
		if done or busy:
			return
		if Time.get_ticks_msec() - started_ms > 420000:
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
		if v.calendar == null or v.market == null or v.recovery == null:
			return
		var day: int = v.calendar.day_index
		if hooked_world != world:
			hooked_world = world
			merchant_lines = []
			for vv in world.villages:
				vv.event_bus.event_logged.connect(_on_bus)
		busy = true
		match phase:
			1: _takeover(main, v, day)
			2: _hunger(main, v, day)
			3: _outside(main, world, v, day)
		busy = false

	# ── 1. An empty farm is taken over ──────────────────────────────────────
	func _takeover(main: Node, v, day: int) -> void:
		match stage:
			0:
				var farmer = v.all_farmers[0] if not v.all_farmers.is_empty() else null
				if farmer == null:
					return
				if day >= 4:
					# Staged: make sure the farmer has a hand, and not the richest person in town.
					if LaborMarket.hands_of(farmer) == 0:
						var poorest = null
						for h in v.households:
							if h != null and is_instance_valid(h) and not h.has_meta("merchant") and (poorest == null or h.get_cash() < poorest.get_cash()):
								poorest = h
						if poorest != null:
							poorest.set_meta("employer", farmer)
					hands = []
					cash_then = {}
					for h in v.households:
						if h == null or not is_instance_valid(h):
							continue
						cash_then[h.get_instance_id()] = h.get_cash()
						if h.has_meta("employer") and h.get_meta("employer") == farmer and not bool(h.get_meta("servant", false)):
							hands.append(h)
					brought_then = v.coins_brought
					wheat_then = int(v.market.totals.wheat_from_farmers)
					_remove_farmers(v)
					day0 = day
					stage = 1
			1:
				if v.all_farmers.size() >= 1 or day > day0 + 3:
					var nf = v.all_farmers[0] if not v.all_farmers.is_empty() else null
					_check("someone has the farm the next morning", nf != null and day <= day0 + 1 and int(v.recovery.stats.takeovers) == 1,
						"day %d, farmer gone on day %d" % [day, day0])
					if nf != null:
						_check("a person who worked for the old farmer comes first", not hands.is_empty() and hands.has(nf),
							"%d had worked there; %s got it" % [hands.size(), nf.name])
						var before: float = float(cash_then.get(nf.get_instance_id(), -999.0))
						_check("nothing is paid and no purse is handed out", absf(nf.get_cash() - before) < 20.0 and absf(v.coins_brought - brought_then) < 0.01,
							"%.1f coins before, %.1f after" % [before, nf.get_cash()])
						_check("both fields go with the farm", v._free_fields().is_empty() and nf.current_job.get_field_count() == 2,
							"%d fields, %d left idle" % [nf.current_job.get_field_count(), v._free_fields().size()])
					stage = 2
			2:
				if day >= day0 + 18:
					var grown: int = int(v.market.totals.wheat_from_farmers) - wheat_then
					_check("wheat is being sold again", grown > 0 and v.all_farmers.size() >= 1, "%d wheat sold to the market since" % grown)
					_check("nobody starved", v.starved_deaths == 0, "%d" % v.starved_deaths)
					_next_phase(main)

	# ── 2. Hunger moves people ──────────────────────────────────────────────
	func _hunger(main: Node, v, day: int) -> void:
		match stage:
			0:
				Tuning.set_value("town_size_limit", 3)   # nobody new arrives during this phase
				if day >= 2:
					_check("the town is owners only", v.all_farmers.size() == 1 and v.all_bakers.size() == 1 and v.all_woodworkers.size() == 2 and v.households.is_empty(),
						"%d farmers, %d bakers, %d woodworkers, %d others" % [v.all_farmers.size(), v.all_bakers.size(), v.all_woodworkers.size(), v.households.size()])
					_remove_farmers(v)
					v.market.bread = 0
					v.market.wheat = 0
					for list in [v.all_bakers, v.all_woodworkers]:
						for a in list:
							for k in ["bread", "wheat", "flour"]:
								a.inv.items[k] = 0
					day0 = day
					stage = 1
			1:
				if v.all_farmers.size() >= 1 or day > day0 + 3:
					_check("a woodworker with coins and nothing to eat turns to farming", v.all_farmers.size() == 1 and v.all_woodworkers.size() == 1
						and int(v.recovery.stats.hunger_switches) == 1 and day <= day0 + 2,
						"day %d: %d farmers, %d woodworkers" % [day, v.all_farmers.size(), v.all_woodworkers.size()])
					_check("the town's only baker stays a baker", v.all_bakers.size() == 1)
					if not v.all_farmers.is_empty():
						_check("the new farmer has fields to work", v.all_farmers[0].current_job.get_field_count() >= 1)
					_next_phase(main)

	# ── 3. Help from outside ────────────────────────────────────────────────
	func _outside(main: Node, world: Node, v, day: int) -> void:
		match stage:
			0:
				if day >= 3:
					var merchant = null
					var other = null
					for h in v.households:
						if h.has_meta("merchant"):
							merchant = h
						else:
							other = h
					var cushion: float = v.housing.cushion()
					_check("a merchant holds back the coins they trade with", merchant != null and absf(v.housing._keep_back(merchant) - (cushion + MerchantJob.OWNER_CASH)) < 0.01
						and other != null and absf(v.housing._keep_back(other) - cushion) < 0.01,
						"merchant keeps %.0f, others %.0f" % [v.housing._keep_back(merchant) if merchant else -1.0, cushion])
					_remove_farmers(v)
					v.market.wheat = 0
					v.market.wheat_price = 1.5
					v.market.bread = 0
					v.market.bread_price = 6.0
					brought_then = v.coins_brought
					day0 = day
					stage = 1
			1:
				if int(v.recovery.stats.farmers_called) >= 1 or day > day0 + 8:
					var nf = v.all_farmers[0] if not v.all_farmers.is_empty() else null
					_check("with wheat dear, a farmer comes from outside", nf != null and int(v.recovery.stats.farmers_called) == 1 and day <= day0 + 5,
						"day %d, farmer gone on day %d" % [day, day0])
					if nf != null:
						_check("they bring an owner's purse", nf.get_cash() >= FarmerJob.STARTING_CASH - 15.0 and v.coins_brought - brought_then >= FarmerJob.STARTING_CASH - 0.01,
							"%.1f coins in hand, %.1f brought into town" % [nf.get_cash(), v.coins_brought - brought_then])
					stage = 2
			2:
				if not merchant_lines.is_empty() or day > day0 + 10:
					_check("a merchant carries bread or wheat in from the other town", not merchant_lines.is_empty(),
						str(merchant_lines[0]).substr(0, 110) if not merchant_lines.is_empty() else "none by day %d" % day)
					_next_phase(main)

	func _finish() -> void:
		done = true
		Tuning.clear()
		Tuning.keep_on_restart = false
		var fails: int = results.count(false)
		print("[RECOVERY TEST] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	Probe.setup_phase(1)
	var probe := Probe.new()
	probe.name = "RecoveryProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
