extends Node
## Empty-shop test (docs/RECOVERY.md). Runs the real game (Main.tscn, 10x) five times, takes
## shop owners away on purpose, and checks the one mechanic that fills an empty shop:
##
##   1. The farm (only farm_takeover on): the next morning someone has it. A person who worked
##      for the old farmer comes first. They pay the town's shop fee, what they can at once and
##      the rest out of the farm's earnings, and no purse is handed out; both fields go with
##      it; wheat is being sold again within days.
##   2. Going without (only hunger_switch on): in a town of owners only, with no bread
##      anywhere, a woodworker with coins takes the empty farm. The town's only baker stays.
##   3. The bakery and the lumber yard: the same mechanic, no code of their own. Each has a new
##      owner the next morning and is selling again within days.
##   4. A second shop: with a farmer still in town and wheat on the shelf an empty farm stays
##      empty; after three days short of wheat someone takes it. A farm that closed for want
##      of trade is not handed on.
##   5. Merchants hold back the coins they trade with, and carry bread or wheat in.
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
	var made_then := 0
	var takeovers_then := 0
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
				Tuning.set_value("farm_takeover", true)
				for pair in [["farmers", 1], ["bakers", 1], ["woodworkers", 1], ["others", 6], ["market_bread", 40], ["market_wheat", 30], ["market_firewood", 40]]:
					Tuning.set_value(str(pair[0]), pair[1])
			4:
				Tuning.set_value("farm_takeover", true)
				for pair in [["farmers", 2], ["bakers", 1], ["woodworkers", 1], ["others", 6], ["market_bread", 40]]:
					Tuning.set_value(str(pair[0]), pair[1])
			5:
				Tuning.set_value("outside_help", true)
				Tuning.set_value("merchants", true)   # off in the game for now
				for pair in [["farmers", 1], ["bakers", 1], ["woodworkers", 1], ["others", 5], ["market_bread", 60]]:
					Tuning.set_value(str(pair[0]), pair[1])
		Tuning.source = "TestRecovery"
		Tuning.keep_on_restart = true

	func _next_phase(main: Node) -> void:
		phase += 1
		stage = 0
		day0 = -1
		if phase > 5:
			_finish()
			return
		setup_phase(phase)
		main.get_node("DevMenu").restart()

	func _remove_farmers(v) -> void:
		for f in v.all_farmers.duplicate():
			if f != null and is_instance_valid(f):
				v.labor_market.migrate_requested.emit(f, "staged for the test")

	func _remove(v, list: Array) -> void:
		for a in list.duplicate():
			if a != null and is_instance_valid(a):
				v.labor_market.migrate_requested.emit(a, "staged for the test")

	## Staged: make sure `boss` has someone working for them, then note who works there and
	## what everyone has in the purse.
	func _note_before(v, boss, stage_a_hand: bool) -> void:
		var free = null
		var has_hand := false
		for h in v.households:
			if h == null or not is_instance_valid(h) or h.has_meta("merchant"):
				continue
			if h.has_meta("employer") and h.get_meta("employer") == boss:
				has_hand = true
			elif not (h.has_meta("employer") and is_instance_valid(h.get_meta("employer"))) and (free == null or h.get_cash() < free.get_cash()):
				free = h
		if stage_a_hand and not has_hand and free != null:
			free.set_meta("employer", boss)
		hands = []
		cash_then = {}
		for h in v.households:
			if h == null or not is_instance_valid(h):
				continue
			cash_then[h.get_instance_id()] = h.get_cash()
			if h.has_meta("employer") and h.get_meta("employer") == boss and not bool(h.get_meta("servant", false)):
				hands.append(h)
		brought_then = v.coins_brought
		takeovers_then = int(v.recovery.stats.takeovers)

	func _on_bus(msg: String) -> void:
		if msg.contains("[DEATH]") or msg.contains("[RECOVERY]"):
			print("[RECOVERY TEST] town news: " + msg)
		if msg.contains("[MERCHANT]") and msg.contains(" sold ") and msg.contains("in Village 1") and (msg.contains(" bread ") or msg.contains(" wheat ")):
			merchant_lines.append(msg)

	func _process(_d: float) -> void:
		if done or busy:
			return
		if Time.get_ticks_msec() - started_ms > 600000:
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
			3: _shops(main, v, day)
			4: _second(main, v, day)
			5: _merchants(main, v, day)
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
						var fee: float = LaborMarket.STARTUP_COST
						var paid: float = float(nf.get_meta("shop_paid", 0.0))
						var owed: float = float(nf.get_meta("shop_owed", 0.0))
						_check("they pay the town for the farm: something now, the rest owed", paid > 0.0 and absf(paid + owed - fee) < 0.01
							and absf((before - nf.get_cash()) - paid) < 12.0 and absf(float(v.recovery.stats.fees_paid) - paid) < 0.01,
							"had %.1f coins, paid %.1f at once, %.1f still owed of a fee of %.0f" % [before, paid, owed, fee])
						_check("no purse is handed out", absf(v.coins_brought - brought_then) < 0.01)
						_check("both fields go with the farm", v._free_fields().is_empty() and nf.current_job.get_field_count() == 2,
							"%d fields, %d left idle" % [nf.current_job.get_field_count(), v._free_fields().size()])
					stage = 2
			2:
				if day >= day0 + 18:
					var grown: int = int(v.market.totals.wheat_from_farmers) - wheat_then
					_check("wheat is being sold again", grown > 0 and v.all_farmers.size() >= 1, "%d wheat sold to the market since" % grown)
					_check("nobody starved", v.starved_deaths == 0, "%d" % v.starved_deaths)
					var f2 = v.all_farmers[0] if not v.all_farmers.is_empty() else null
					_check("the fee is paid off out of the farm's earnings", f2 != null and not f2.has_meta("shop_owed") and absf(float(v.recovery.stats.fees_paid) - LaborMarket.STARTUP_COST) < 0.01,
						"%.1f paid to the town in all" % float(v.recovery.stats.fees_paid))
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
					_check("a woodworker with coins and nothing to eat takes the empty farm", v.all_farmers.size() == 1 and v.all_woodworkers.size() == 1
						and int(v.recovery.stats.hunger_switches) == 1 and day <= day0 + 2,
						"day %d: %d farmers, %d woodworkers" % [day, v.all_farmers.size(), v.all_woodworkers.size()])
					_check("the town's only baker stays a baker", v.all_bakers.size() == 1)
					if not v.all_farmers.is_empty():
						_check("the new farmer has fields to work", v.all_farmers[0].current_job.get_field_count() >= 1)
					_next_phase(main)

	# ── 3. The bakery and the lumber yard: the same mechanic ────────────────
	func _shops(main: Node, v, day: int) -> void:
		var fee: float = LaborMarket.STARTUP_COST
		match stage:
			0:
				var baker = v.all_bakers[0] if not v.all_bakers.is_empty() else null
				if baker == null:
					return
				if day >= 4:
					_note_before(v, baker, true)
					made_then = int(v.market.totals.bread_from_bakers)
					_remove(v, v.all_bakers)
					day0 = day
					stage = 1
			1:
				if v.all_bakers.size() >= 1 or day > day0 + 3:
					var nb = v.all_bakers[0] if not v.all_bakers.is_empty() else null
					_check("the bakery has a new owner the next morning", nb != null and day <= day0 + 1 and int(v.recovery.stats.takeovers) == takeovers_then + 1,
						"day %d, baker gone on day %d" % [day, day0])
					if nb != null:
						_check("a person who worked at the bakery comes first", not hands.is_empty() and hands.has(nb),
							"%d had worked there; %s got it" % [hands.size(), nb.name])
						var paid: float = float(nb.get_meta("shop_paid", 0.0))
						var owed: float = float(nb.get_meta("shop_owed", 0.0))
						_check("they owe the town the shop fee for the bakery", absf(paid + owed - fee) < 0.01,
							"%.1f paid at once, %.1f still owed of a fee of %.0f" % [paid, owed, fee])
						_check("no purse is handed out for the bakery", absf(v.coins_brought - brought_then) < 0.01)
					stage = 2
			2:
				if day >= day0 + 12:
					var baked: int = int(v.market.totals.bread_from_bakers) - made_then
					_check("bread is being sold again", baked > 0 and v.all_bakers.size() >= 1, "%d loaves sold to the market since" % baked)
					var wood = v.all_woodworkers[0] if not v.all_woodworkers.is_empty() else null
					if wood == null:
						_check("the town still has its woodworker", false)
						_next_phase(main)
						return
					_note_before(v, wood, false)
					made_then = int(v.market.totals.firewood_in)
					_remove(v, v.all_woodworkers)
					day0 = day
					stage = 3
			3:
				if v.all_woodworkers.size() >= 1 or day > day0 + 3:
					var nw = v.all_woodworkers[0] if not v.all_woodworkers.is_empty() else null
					_check("the lumber yard has a new owner the next morning", nw != null and day <= day0 + 1 and int(v.recovery.stats.takeovers) == takeovers_then + 1,
						"day %d, woodworker gone on day %d" % [day, day0])
					if nw != null:
						var paid_w: float = float(nw.get_meta("shop_paid", 0.0))
						var owed_w: float = float(nw.get_meta("shop_owed", 0.0))
						_check("they owe the town the shop fee for the yard", absf(paid_w + owed_w - fee) < 0.01,
							"%.1f paid at once, %.1f still owed of a fee of %.0f" % [paid_w, owed_w, fee])
					stage = 4
			4:
				if day >= day0 + 8:
					var cut: int = int(v.market.totals.firewood_in) - made_then
					_check("firewood is being sold again", cut > 0 and v.all_woodworkers.size() >= 1, "%d firewood sold to the market since" % cut)
					_check("no shop is left standing empty", v.recovery.empty_shops("Farmer") + v.recovery.empty_shops("Baker") + v.recovery.empty_shops("Woodworker") == 0,
						"farm %d, bakery %d, yard %d" % [v.recovery.empty_shops("Farmer"), v.recovery.empty_shops("Baker"), v.recovery.empty_shops("Woodworker")])
					_check("nobody starved while the shops changed hands", v.starved_deaths == 0, "%d" % v.starved_deaths)
					_next_phase(main)

	# ── 4. A second shop is only taken when the town is short ───────────────
	func _second(main: Node, v, day: int) -> void:
		match stage:
			0:
				if v.all_farmers.size() < 2:
					return
				if day >= 4:
					takeovers_then = int(v.recovery.stats.takeovers)
					v.labor_market.migrate_requested.emit(v.all_farmers[1], "staged for the test")
					day0 = day
					stage = 1
			1:
				# Staged: plenty of wheat on the shelf, so the town is not short.
				v.market.wheat = maxi(v.market.wheat, v.market.wheat_target + 5)
				if day >= day0 + 4:
					_check("with a farmer in town and wheat on the shelf, the empty farm stays empty",
						v.all_farmers.size() == 1 and v.recovery.empty_shops("Farmer") == 1 and int(v.recovery.stats.takeovers) == takeovers_then,
						"%d farmers, %d farms empty" % [v.all_farmers.size(), v.recovery.empty_shops("Farmer")])
					day0 = day
					stage = 2
			2:
				v.market.wheat = 0   # staged: a bare shelf, so the town is short of wheat
				if v.all_farmers.size() >= 2 or day > day0 + 6:
					_check("after three days short of wheat someone takes the empty farm",
						v.all_farmers.size() == 2 and int(v.recovery.stats.takeovers) == takeovers_then + 1 and day >= day0 + 3 and day <= day0 + 4,
						"taken on day %d, short since day %d" % [day, day0])
					_check("and no farm is left empty", v.recovery.empty_shops("Farmer") == 0)
					# Staged: the new farm closes for want of trade (the way a broke owner closes).
					if v.all_farmers.size() >= 2:
						v.labor_market.business_failed.emit(v.all_farmers[1])
					takeovers_then = int(v.recovery.stats.takeovers)
					day0 = day
					stage = 3
			3:
				v.market.wheat = 0   # still short of wheat
				if day >= day0 + 4:
					_check("a farm that closed for want of trade is not handed on for nothing",
						int(v.recovery.stats.takeovers) == takeovers_then and v.recovery.orphaned_shops("Farmer") == 0,
						"%d farmers, %d farms empty, %d takeovers since" % [v.all_farmers.size(), v.recovery.empty_shops("Farmer"), int(v.recovery.stats.takeovers) - takeovers_then])
					_next_phase(main)

	# ── 5. Merchants keep their trading coins and carry goods in ────────────
	func _merchants(main: Node, v, day: int) -> void:
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
					day0 = day
					stage = 1
			1:
				if not merchant_lines.is_empty() or day > day0 + 10:
					_check("a merchant carries bread or wheat in from the other town", not merchant_lines.is_empty(),
						str(merchant_lines[0]).substr(0, 110) if not merchant_lines.is_empty() else "none by day %d" % day)
					_check("nobody is sent from outside to farm", v.all_farmers.is_empty() or int(v.recovery.stats.takeovers) > 0,
						"%d farmers on day %d" % [v.all_farmers.size(), day])
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
