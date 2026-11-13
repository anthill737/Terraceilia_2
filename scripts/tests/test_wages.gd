extends Node
## Wage test (docs/WAGES.md). Runs the real game (Main.tscn, 10x) once and checks that each
## owner sets a wage and hands weigh it:
##
##   - nobody works for less than a living: a loaf, a log, a day's rent and clothes;
##   - a job is worth its wage less the share of the day spent walking to it, plus how the
##     hand gets on with the boss, which grows with every day paid on time;
##   - a hand moves to another employer only for an offer worth 15% more to them;
##   - a hand who is not paid stays one day, thinks less of the boss, and quits on the second;
##   - an owner who can find nobody raises the wage a little each day, never above what the
##     hand would bring in, and lets it settle back when people are easy to find.
##
## Staged: bread is kept dear and the shelf nearly bare, so the baker wants hands.
##
##   godot --headless --fixed-fps 30 --path . res://scenes/TestWages.tscn
## Exit code 0 when every check passes.


class Probe extends Node:
	var stage := 0
	var results := []
	var done := false
	var started_ms := 0
	var day0 := -1
	var baker = null
	var hand = null
	var bond_then := 0
	var wage_then := 0.0
	var wages_seen: Array = []
	var best_value := 0.0
	var last_seen_day := -1
	var busy: Array = []
	var news: Array = []
	var hooked := false

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		started_ms = Time.get_ticks_msec()

	func _check(label: String, ok: bool, detail: String = "") -> void:
		results.append(ok)
		print("[WAGES TEST] %s %s%s" % ["PASS" if ok else "FAIL", label, "" if detail == "" else " (" + detail + ")"])

	func _near(a: float, b: float) -> bool:
		return absf(a - b) < 0.011

	func _hands(p) -> Array:
		var out: Array = []
		for h in p.get_meta("hands", []):
			if is_instance_valid(h):
				out.append(h)
		return out

	func _on_bus(msg: String) -> void:
		if msg.contains("[HANDS]") and not msg.contains("employed=") and msg.contains("Village 1"):
			news.append(msg)

	func _process(_d: float) -> void:
		if done:
			return
		if Time.get_ticks_msec() - started_ms > 360000:
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
		if not hooked:
			hooked = true
			v.event_bus.event_logged.connect(_on_bus)
		var day: int = v.calendar.day_index
		var m = v.market
		var lm = v.labor_market
		if day >= 2:
			m.bread_price = 7.0   # staged: bread dear and the shelf nearly bare
			m.bread = mini(m.bread, 6)
		if baker == null or not is_instance_valid(baker):
			baker = v.all_bakers[0] if not v.all_bakers.is_empty() else null
		if baker == null:
			return
		var wood = v.all_woodworkers[0] if not v.all_woodworkers.is_empty() else null
		match stage:
			0:
				if _hands(baker).size() >= 1 and day >= 4 or day > 16:
					var hs: Array = _hands(baker)
					_check("the baker takes on a hand", hs.size() >= 1, "%d on day %d" % [hs.size(), day])
					if hs.is_empty() or wood == null:
						_finish()
						return
					hand = hs[0]
					var need: float = lm.wage_floor()
					_check("nobody works for less than a living: a loaf, a log, a day's rent and clothes wearing out", _near(need, m.bread_price + m.firewood_price + v.housing.rent_per_day() + (m.good_price("clothes") / Clothing.life_days() if Clothing.on() else 0.0))
						and LaborMarket.wage_of(baker) >= need - 0.011, "the floor is %.2f, the baker pays %.2f" % [need, LaborMarket.wage_of(baker)])
					wood.set_meta("wage_offer", LaborMarket.wage_of(baker) + 3.0)   # staged: another owner pays differently
					_check("each owner pays a wage of their own", _near(LaborMarket.wage_of(wood), LaborMarket.wage_of(baker) + 3.0))
					var share_b: float = lm.commute_share(hand, baker)
					var share_w: float = lm.commute_share(hand, wood)
					var home = hand.current_job.home_location
					var want_share: float = 2.0 * home.global_position.distance_to(lm._work_spot(baker).global_position) / 100.0 / 26.67
					_check("the walk to work costs a share of the day", share_b > 0.0 and absf(share_b - want_share) < 0.01 and share_w > 0.0,
						"%.0f%% of the day to the bakery, %.0f%% to the lumber yard" % [share_b * 100.0, share_w * 100.0])
					var far = baker if share_b > share_w else wood
					var near = wood if far == baker else baker
					hand.set_meta("boss_bond", 0)
					_check("at the same wage the nearer job is worth more", lm.job_worth(hand, near, 10.0) > lm.job_worth(hand, far, 10.0) or _near(share_b, share_w))
					hand.set_meta("boss_bond", LaborMarket.BOND_DAYS)
					_check("a hand who gets on with the boss values the job more", _near(lm.job_worth(hand, baker, 10.0), 10.0 * (1.0 - share_b) + 2.0),
						"worth %.2f a day at a wage of 10" % lm.job_worth(hand, baker, 10.0))
					# A better offer: only one worth 15% more moves them.
					var here: float = lm.job_worth(hand, baker, LaborMarket.wage_of(baker))
					# Staged: for this check the town's only hired hand is this one.
					var kept_lists: Dictionary = {}
					for e in v.all_farmers + v.all_bakers + v.all_woodworkers:
						kept_lists[e] = (e.get_meta("hands", []) as Array).duplicate()
						e.set_meta("hands", [hand] if e == baker else [])
					wood.set_meta("wage_offer", here * 1.10 / (1.0 - share_w))
					lm._better_offers(day, [wood])
					_check("an offer worth 10% more does not move them", hand.get_meta("employer") == baker)
					wood.set_meta("wage_offer", here * 1.30 / (1.0 - share_w))
					lm._better_offers(day, [wood])
					_check("an offer worth 30% more does", hand.get_meta("employer") == wood and _hands(wood).has(hand) and not _hands(baker).has(hand) and int(lm.wage_stats.moves) == 1,
						str(news[news.size() - 1]).substr(0, 120) if not news.is_empty() else "no news line")
					# Everyone back where they were for the rest of the test (staged).
					for e in kept_lists:
						if is_instance_valid(e):
							e.set_meta("hands", kept_lists[e])
					hand.set_meta("employer", baker)
					wood.set_meta("wage_offer", LaborMarket.daily_wage(m))
					hand.set_meta("boss_bond", 4)
					bond_then = 4
					day0 = day
					stage = 1
			1:
				if day >= day0 + 3:
					_check("every day paid on time, they get on better with the boss", is_instance_valid(hand) and int(hand.get_meta("boss_bond", 0)) == bond_then + (day - day0),
						"%d after %d paid days, was %d" % [int(hand.get_meta("boss_bond", 0)) if is_instance_valid(hand) else -1, day - day0, bond_then])
					bond_then = int(hand.get_meta("boss_bond", 0)) if is_instance_valid(hand) else 0
					day0 = day
					stage = 2
			2:
				# Staged: the baker has no coins to pay with.
				if baker.wallet.money > 0.0:
					baker.wallet.debit(baker.wallet.money)
				if is_instance_valid(hand) and day == day0 + 1 and int(hand.get_meta("wage_unpaid", 0)) == 1 and last_seen_day != day:
					last_seen_day = day
					_check("not paid for a day, a hand stays but thinks less of the boss", hand.get_meta("employer", null) == baker and int(hand.get_meta("boss_bond", 0)) == bond_then / 2,
						"goodwill %d, was %d" % [int(hand.get_meta("boss_bond", 0)), bond_then])
				if day >= day0 + 2:
					var gone: bool = is_instance_valid(hand) and not (hand.has_meta("employer") and is_instance_valid(hand.get_meta("employer")))
					var said: bool = false
					for line in news:
						if str(line).contains("quits") and str(line).contains("not paid for 2 days"):
							said = true
					_check("not paid for two days, they quit", gone and int(lm.wage_stats.quits_unpaid) >= 1 and said and last_seen_day == day0 + 1)
					baker.wallet.credit(900.0)   # staged: the baker has coins again
					# Staged: everybody free is busy with something else, so nobody can be had.
					busy = []
					for h in v.households:
						if h != null and is_instance_valid(h) and lm.is_idle(h):
							h.set_meta("builds_house", -99)
							busy.append(h)
					wages_seen = []
					best_value = 0.0
					last_seen_day = day
					day0 = day
					stage = 3
			3:
				for h in v.households:
					if h != null and is_instance_valid(h) and lm.is_idle(h):
						h.set_meta("builds_house", -99)
						busy.append(h)
				if day != last_seen_day:
					last_seen_day = day
					wages_seen.append(LaborMarket.wage_of(baker))
					best_value = maxf(best_value, lm._hand_value(baker, _hands(baker).size()))   # what a hand is worth changes from day to day
				if wages_seen.size() >= 4:
					var rising: bool = true
					var small: bool = true
					for i in range(1, wages_seen.size()):
						rising = rising and float(wages_seen[i]) > float(wages_seen[i - 1]) + 0.001
						small = small and float(wages_seen[i]) <= float(wages_seen[i - 1]) * 1.0501
					var top: float = best_value / 1.1
					_check("with nobody to be had, the owner offers a little more each day", rising and small,
						"%.2f, %.2f, %.2f, %.2f" % [wages_seen[0], wages_seen[1], wages_seen[2], wages_seen[3]])
					_check("never more than the hand would bring in", float(wages_seen[wages_seen.size() - 1]) <= top + 0.02, "a hand is worth %.2f a day to the baker" % (top * 1.1))
					for h in busy:
						if is_instance_valid(h) and h.has_meta("builds_house") and int(h.get_meta("builds_house")) == -99:
							h.remove_meta("builds_house")
					busy = []
					wage_then = LaborMarket.wage_of(baker)
					day0 = day
					stage = 4
			4:
				if day >= day0 + 8:
					var now: float = LaborMarket.wage_of(baker)
					_check("with people easy to find again, hands are taken on and the wage settles back", _hands(baker).size() >= 1 and now < wage_then - 0.01 and now >= lm.wage_floor() - 0.011,
						"%d hands; the wage went from %.2f to %.2f, and the floor is %.2f" % [_hands(baker).size(), wage_then, now, lm.wage_floor()])
					_check("nobody starved", v.starved_deaths == 0, "%d" % v.starved_deaths)
					Tuning.set_value("owner_wages", false)
					_check("with the switch off, everyone pays the town's rate", _near(LaborMarket.wage_of(baker), LaborMarket.daily_wage(m)) and _near(LaborMarket.wage_of(wood), LaborMarket.daily_wage(m)))
					_finish()

	func _finish() -> void:
		done = true
		Tuning.clear()
		Tuning.keep_on_restart = false
		var fails: int = results.count(false)
		print("[WAGES TEST] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	Tuning.clear()
	Tuning.set_value("troubles", false)
	Tuning.set_value("arrival_prosperity_bar", 2.0)   # staged: nobody new comes during the test
	Tuning.set_value("home_improvements", false)
	Tuning.set_value("shop_extensions", false)
	for pair in [["farmers", 1], ["bakers", 1], ["woodworkers", 1], ["others", 8], ["coins_owners", 900.0], ["market_firewood", 70], ["market_wheat", 80]]:
		Tuning.set_value(str(pair[0]), pair[1])
	Tuning.source = "TestWages"
	Tuning.keep_on_restart = true
	var probe := Probe.new()
	probe.name = "WagesProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
