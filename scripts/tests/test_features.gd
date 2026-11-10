extends Node
## Feature test: runs the real game (Main.tscn, 10x speed, 240 physics steps a second) and sets up
## each feature on purpose in village 1, then checks it actually happens on its own:
##
##   1. own house: a renter with enough money builds a house, works on it themselves on site,
##      and moves in when it is done.
##   2. buying: someone with no home and enough money buys an empty town house.
##   3. hired builder: a business owner starts a house; a person out of work is hired, walks to
##      the site, is paid each work day, and the house is finished.
##   4. eating at 0: someone whose hunger runs out while holding a loaf eats it and lives.
##   5. starving: a farmer whose hunger runs out with no bread dies and is removed; their coins
##      go to the town purse.
##
##   godot --headless --path . res://scenes/TestFeatures.tscn
## Exit code 0 when every check passes.

const MAX_DAYS := 30


class Probe extends Node:
	var v = null
	var stage := 0
	var started_ms := 0
	var results := []
	var done := false
	# 1. own house
	var own = null
	var own_start_day := -1
	var own_seen_on_site := false
	var _last_own_log := -1
	# 2. buying
	var buyer = null
	var buyer_cash := 0.0
	# 3. hired builder
	var boss = null
	var job: Dictionary = {}
	var job_worker = null
	var job_worker_cash := 0.0
	var job_worker_near := 999999.0
	var job_start_day := -1
	var job_owner_cash := 0.0
	var job_done_day := -1

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		started_ms = Time.get_ticks_msec()

	func _process(_d: float) -> void:
		if done:
			return
		var main := get_tree().current_scene
		if main == null or main == self:
			return
		var clock = main.get("clock")
		if clock and clock.speed_multiplier < 10.0:
			clock.set_speed(10.0)
		var world := main.get_node_or_null("World")
		if world == null or world.villages.is_empty():
			return
		v = world.villages[0]
		if v == null or v.calendar == null or v.housing == null or not v.housing.initialized:
			return
		var day: int = v.calendar.day_index
		if stage == 0 and day >= 2:
			_stage_houses(day)
			stage = 1
		if stage == 1:
			_watch(day)
			if (_own_done() and _job_finished()) or day >= MAX_DAYS:
				_stage_hunger(day)
				stage = 2
				return
		if stage == 2:
			_finish()
		if Time.get_ticks_msec() - started_ms > (MAX_DAYS * 8 + 120) * 1000:
			_check("finished in time", false, "timed out")
			_finish()

	func _check(name: String, ok: bool, detail: String) -> void:
		results.append({"check": name, "ok": ok, "detail": detail})
		print("[FEATURES] %s %s (%s)" % ["PASS" if ok else "FAIL", name, detail])

	func _free_household(skip: Array):
		for a in v.households:
			if a == null or not is_instance_valid(a) or skip.has(a):
				continue
			if a.has_meta("employer") and is_instance_valid(a.get_meta("employer")):
				continue
			if a.has_meta("builds_house"):
				continue
			return a
		return null

	func _stage_houses(day: int) -> void:
		var hs = v.housing
		var extra: float = hs.house_value() + hs.cushion() + 40.0
		# 1. A renter (not hired by anyone) gets enough money for a house of their own.
		for a in v.households:
			if not is_instance_valid(a):
				continue
			var home: Dictionary = hs._home_of(a)
			if not home.is_empty() and home.owner != a and not (a.has_meta("employer") and is_instance_valid(a.get_meta("employer"))):
				own = a
				break
		if own == null:
			# Nobody free rents yet: hand a free household's house to the town, so they rent it.
			own = _free_household([])
			if own != null:
				var h1: Dictionary = hs._home_of(own)
				if not h1.is_empty():
					h1.owner = null
		if own != null:
			own.wallet.credit(extra)
			own_start_day = day
			# Spare logs in the market, so the wood comes in at once and they start work before
			# some employer takes them on as a hand (then they would hire a builder instead).
			v.market.firewood = mini(v.market.firewood_capacity, v.market.firewood_target + 45)
			print("[FEATURES] day %d: %s gets $%.0f to build a home of their own" % [day, own.name, extra])
		# 2. Someone else loses their home and gets money to buy one; the town has one empty.
		buyer = _free_household([own])
		if buyer != null:
			var home2: Dictionary = hs._home_of(buyer)
			if not home2.is_empty():
				home2.occupant = null
			hs._new_house(null, null, true)
			buyer.wallet.credit(extra)
			buyer_cash = buyer.get_cash()
			print("[FEATURES] day %d: %s has no home and $%.0f; the town has an empty house" % [day, buyer.name, buyer_cash])
		# 3. The baker starts a house to let out, wood already in, and needs a worker.
		boss = v.all_bakers[0] if not v.all_bakers.is_empty() else null
		if boss != null:
			boss.wallet.credit(300.0)
			job = hs._new_house(boss, null, false)
			job.wood = hs.HOUSE_WOOD
			job_start_day = day
			job_owner_cash = boss.get_cash()
			print("[FEATURES] day %d: %s starts house %d and must hire someone" % [day, boss.name, job.id])

	func _watch(day: int) -> void:
		var hs = v.housing
		# 1. own house: building it themselves, on site at some point
		if own != null and is_instance_valid(own) and own.has_meta("builds_house"):
			var j = own.current_job
			if j is HouseholdJob and j.work_site != null and own.global_position.distance_to(j.work_site.global_position) < 20.0:
				own_seen_on_site = true
		if own != null and is_instance_valid(own) and day != _last_own_log:
			_last_own_log = day
			for hh in hs.houses:
				if not hh.done and hh.owner == own:
					var wk = hh.get("worker")
					print("[FEATURES] day %d: %s's house %d wood %d work %d, worker %s, %s has employer: %s" % [
						day, own.name, hh.id, hh.wood, hh.work, wk.name if wk != null and is_instance_valid(wk) else "none",
						own.name, own.has_meta("employer") and is_instance_valid(own.get_meta("employer"))])
		# 3. hired worker
		if not job.is_empty():
			var w = job.get("worker")
			if w != null and is_instance_valid(w) and w != boss:
				if job_worker == null:
					job_worker = w
					job_worker_cash = w.get_cash()
				if w == job_worker and job.get("node") != null:
					job_worker_near = minf(job_worker_near, w.global_position.distance_to(job.node.global_position))
			if job.done and job_done_day < 0:
				job_done_day = day

	func _own_done() -> bool:
		if own == null or not is_instance_valid(own):
			return true
		var home: Dictionary = v.housing._home_of(own)
		return not home.is_empty() and home.owner == own

	func _job_finished() -> bool:
		return job.is_empty() or job.done

	func _stage_hunger(day: int) -> void:
		var hs = v.housing
		# 1. own house
		var own_ok := own != null and is_instance_valid(own) and _own_done()
		_check("a renter with the money builds a home of their own and moves in", own_ok,
			"%s: %s, seen working on site: %s, own-house moves so far %d" % [
				own.name if own != null and is_instance_valid(own) else "nobody",
				"owns their home" if own_ok else "still not in a house of their own",
				own_seen_on_site, hs.stats.moved_into_own])
		_check("they did the building work themselves on site", own_seen_on_site, "self-build days %d" % hs.stats.self_days)
		# 2. buying
		var bought := false
		if buyer != null and is_instance_valid(buyer):
			var bh: Dictionary = hs._home_of(buyer)
			bought = not bh.is_empty() and bh.owner == buyer
		_check("someone with no home and the money buys a house", bought,
			"%s, houses sold %d" % [buyer.name if buyer != null and is_instance_valid(buyer) else "nobody", hs.stats.sold])
		# 3. hired builder
		var hired_ok := job_worker != null
		_check("a business owner's house gets a hired worker", hired_ok,
			"%s" % (job_worker.name if job_worker != null and is_instance_valid(job_worker) else "nobody hired"))
		_check("the hired worker walked to the building site", job_worker_near < 20.0,
			"closest %.0f px from the site" % job_worker_near)
		_check("the house was finished", job_done_day >= 0,
			"started day %d, finished day %d" % [job_start_day, job_done_day])
		var released: bool = job_worker != null and is_instance_valid(job_worker) and not job_worker.has_meta("builds_house") \
			and not (job_worker.current_job is HouseholdJob and job_worker.current_job.work_site != null)
		_check("the worker goes back to normal life afterwards", released or job_worker == null, "")
		_check("builders paid wages", hs.stats.wages_paid > 0.0, "$%.2f paid over %d hired days" % [hs.stats.wages_paid, hs.stats.hired_days])

		# 4. eating at 0: a household holding one loaf, hunger about to run out, already ate today.
		var eater = null
		for a in v.households + v.all_woodworkers:
			if a != null and is_instance_valid(a) and not [own, buyer, job_worker].has(a):
				eater = a
				break
		if eater != null:
			var h = eater.hunger
			eater.inv.items["bread"] = 1
			h.hunger_days = 1
			h.last_auto_eat_day = v.calendar.day_index   # the normal daily meal is used up
			h._on_day_changed(day)
			_check("someone holding a loaf when hunger hits 0 eats it and lives",
				not h.is_starving and h.hunger_days >= 1 and eater.inv.get_qty("bread") == 0,
				"%s hunger %d, bread %d" % [eater.name, h.hunger_days, eater.inv.get_qty("bread")])
		else:
			_check("someone holding a loaf when hunger hits 0 eats it and lives", false, "no household to test")

		# 5. starving: a farmer with no bread whose hunger runs out.
		var farmer = v.all_farmers[0] if not v.all_farmers.is_empty() else null
		if farmer != null:
			var deaths_before: int = v.starved_deaths
			var purse_before: float = v.market.money
			var cash: float = farmer.get_cash()
			farmer.inv.items["bread"] = 0
			farmer.hunger.hunger_days = 1
			farmer.hunger._on_day_changed(day)
			var gone: bool = not v.all_farmers.has(farmer)
			_check("a farmer with no bread whose hunger hits 0 dies and is removed",
				gone and v.starved_deaths == deaths_before + 1,
				"removed: %s, deaths %d -> %d" % [gone, deaths_before, v.starved_deaths])
			_check("their coins go to the town purse", absf((v.market.money - purse_before) - cash) < 0.01,
				"farmer had $%.2f, purse rose $%.2f" % [cash, v.market.money - purse_before])
		else:
			_check("a farmer with no bread whose hunger hits 0 dies and is removed", false, "no farmer")

	func _finish() -> void:
		done = true
		var fails := 0
		for r in results:
			if not r.ok:
				fails += 1
		print("[FEATURES] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	var probe := Probe.new()
	probe.name = "FeatureProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
