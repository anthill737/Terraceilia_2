extends Node
## Skill test (docs/SKILL.md). Runs the real game (Main.tscn, 10x) once and checks that a shop's
## output follows the skill of the people working in it:
##
##   - a hired hand gets better at the employer's trade day by day, and not at the others;
##   - what a hand adds is the place they fill times how good they are, so a skilled hand makes
##     the shop produce more, and the most skilled hand counts in the first place;
##   - an employer takes the most skilled person free, and among equals the poorest;
##   - the owner's own skill counts at the lumber yard as it does on the farm and in the bakery;
##   - with the switch off, every hand counts the same.
##
## Staged: bread is kept dear and the shelf nearly bare, so the baker takes on hands.
##
##   godot --headless --fixed-fps 30 --path . res://scenes/TestSkill.tscn
## Exit code 0 when every check passes.


class Probe extends Node:
	var stage := 0
	var results := []
	var done := false
	var started_ms := 0
	var day0 := -1
	var baker = null
	var hand = null
	var skill_then := 0.0
	var other_then := 0.0
	var owner_then := 0.0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		started_ms = Time.get_ticks_msec()

	func _check(label: String, ok: bool, detail: String = "") -> void:
		results.append(ok)
		print("[SKILL TEST] %s %s%s" % ["PASS" if ok else "FAIL", label, "" if detail == "" else " (" + detail + ")"])

	func _near(a: float, b: float) -> bool:
		return absf(a - b) < 0.001

	func _hands(p) -> Array:
		var out: Array = []
		for h in p.get_meta("hands", []):
			if is_instance_valid(h):
				out.append(h)
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
		if v.calendar == null or v.market == null or v.labor_market == null:
			return
		var day: int = v.calendar.day_index
		var m = v.market
		if day >= 2:
			m.bread_price = 7.0   # staged: bread dear and the shelf nearly bare
			m.bread = mini(m.bread, 6)
		if baker == null or not is_instance_valid(baker):
			baker = v.all_bakers[0] if not v.all_bakers.is_empty() else null
		if baker == null:
			return
		match stage:
			0:
				if _hands(baker).size() >= 2 or day > 14:
					var hs: Array = _hands(baker)
					_check("the baker takes on two hands", hs.size() == 2, "%d on day %d" % [hs.size(), day])
					if hs.is_empty():
						_finish()
						return
					hand = hs[0]
					skill_then = hand.skill_in("Baker")
					other_then = hand.skill_in("Farmer")
					owner_then = baker.skill_in("Baker")
					day0 = day
					stage = 1
			1:
				if not is_instance_valid(hand):
					_check("the hand stayed for the test", false)
					_finish()
					return
				if day >= day0 + 6:
					_check("a hired hand gets better at the employer's trade", hand.skill_in("Baker") > skill_then + 0.05 and str(hand.trade_worked()) == "Baker",
						"baking skill %.2f, was %.2f six days ago" % [hand.skill_in("Baker"), skill_then])
					_check("and not at a trade they do not work in", hand.skill_in("Farmer") <= other_then, "farming skill %.2f, was %.2f" % [hand.skill_in("Farmer"), other_then])
					_check("the owner gets better too", baker.skill_in("Baker") > owner_then, "%.2f, was %.2f" % [baker.skill_in("Baker"), owner_then])
					var hs: Array = _hands(baker)
					var other = hs[1] if hs.size() > 1 and hs[0] == hand else (hs[0] if hs.size() > 1 else null)
					var before_cap: int = baker.current_job._oven_capacity()
					var before_mult: float = LaborMarket.hand_mult(baker)
					var was: float = hand.skill_in("Baker")
					hand.skills.set_skill("Baker", 1.0)   # staged: a master baker's hand
					var f_other: float = LaborMarket.hand_skill_factor(baker, other) if other != null else 0.0
					var master: float = SkillSet.factor(1.0) / SkillSet.factor(SkillSet.START)   # about 1.32 of a new hand
					var want: float = 1.0 + 0.5 * master + (0.4 * f_other if other != null else 0.0)
					_check("what a hand adds is their place times how good they are", _near(LaborMarket.hand_skill_factor(baker, hand), master) and master > 1.3 and _near(LaborMarket.hand_mult(baker), want),
						"the shop makes %.2f times what the owner makes alone; it was %.2f" % [LaborMarket.hand_mult(baker), before_mult])
					_check("a skilled hand makes the shop produce more", baker.current_job._oven_capacity() > before_cap,
						"%d loaves a day, was %d" % [baker.current_job._oven_capacity(), before_cap])
					if other != null:
						# The same two people the other way round: the master is still counted first.
						var o_was: float = other.skill_in("Baker")
						hand.skills.set_skill("Baker", o_was)
						other.skills.set_skill("Baker", 1.0)
						var f_hand: float = LaborMarket.hand_skill_factor(baker, hand)
						_check("the most skilled hand counts in the first place, whoever it is", _near(LaborMarket.hand_mult(baker), 1.0 + 0.5 * master + 0.4 * f_hand))
						other.skills.set_skill("Baker", o_was)
					hand.skills.set_skill("Baker", was)
					# Who an employer takes.
					var wood = v.all_woodworkers[0] if not v.all_woodworkers.is_empty() else null
					var free: Array = []
					for h in v.households:
						if h != null and is_instance_valid(h) and v.labor_market.is_idle(h):
							free.append(h)
					if wood != null and free.size() >= 2:
						var poorest = v.labor_market._free_hand()
						var pick = free[0] if free[0] != poorest else free[1]
						_check("among equals an employer takes the poorest", v.labor_market._free_hand_for(wood) == poorest)
						pick.skills.set_skill("Woodworker", 0.9)   # staged: someone who has cut wood before
						_check("an employer takes the most skilled person free", v.labor_market._free_hand_for(wood) == pick and pick != poorest,
							"%s (skill 0.90) over %s, the poorest" % [pick.name, poorest.name])
						pick.skills.set_skill("Woodworker", SkillSet.START)
					else:
						_check("an employer takes the most skilled person free", false, "not two people free to choose between")
					if wood != null:
						wood.skills.set_skill("Woodworker", 1.0)
						var mastered: int = wood.current_job._capacity()
						_check("the owner's own skill counts at the lumber yard", mastered == roundi(12.0 * 1.25 * LaborMarket.hand_mult(wood)), "%d logs a day as a master" % mastered)
					Tuning.set_value("worker_skill", false)
					_check("with the switch off, every hand counts the same", _near(LaborMarket.hand_mult(baker), LaborMarket.hand_mult_n(baker, _hands(baker).size()))
						and (wood == null or wood.current_job._capacity() == roundi(12.0 * LaborMarket.hand_mult(wood))))
					_finish()

	func _finish() -> void:
		done = true
		Tuning.clear()
		Tuning.keep_on_restart = false
		var fails: int = results.count(false)
		print("[SKILL TEST] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	Tuning.clear()
	Tuning.set_value("troubles", false)
	Tuning.set_value("arrival_prosperity_bar", 2.0)   # staged: nobody new comes during the test
	Tuning.set_value("home_improvements", false)
	Tuning.set_value("shop_extensions", false)        # the shop stays at two hands
	for pair in [["farmers", 1], ["bakers", 1], ["woodworkers", 1], ["others", 8], ["coins_owners", 900.0], ["market_firewood", 70], ["market_wheat", 80]]:
		Tuning.set_value(str(pair[0]), pair[1])
	Tuning.source = "TestSkill"
	Tuning.keep_on_restart = true
	var probe := Probe.new()
	probe.name = "SkillProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
