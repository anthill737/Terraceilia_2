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
##   6. merchant: with bread dear and gone in village 2, village 1's merchant buys bread at
##      home, walks it to village 2 and sells it there at a profit.
##   7. hands: a hired hand walks to the employer's field, bakery or yard.
##   8. improving: an owner with money to spare improves their home with logs and a builder.
##   9. cottagers: someone with no work eats from a garden plot, and pays rent like anyone else.
##  10. servants: an owner with a proper house and money to spare keeps a paid servant, who
##      spends the day at the master's house.
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
	# 6. merchant
	var v2 = null
	var merchant = null
	var merchant_seen_abroad := false
	var merchant_cash := 0.0
	# 7. hands
	var hand_near := 999999.0
	var hand_name := ""
	# 8. improving
	var improver = null
	# 10. servants
	var servant_near := 999999.0
	var servant_name := ""

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
		world.set_meta("no_shocks", true)   # troubles have their own test
		v = world.villages[0]
		v2 = world.villages[1] if world.villages.size() > 1 else null
		if v == null or v.calendar == null or v.housing == null or not v.housing.initialized:
			return
		var day: int = v.calendar.day_index
		if stage == 0 and day >= 2:
			_stage_houses(day)
			stage = 1
		if stage == 1:
			_watch(day)
			if (_own_done() and _job_finished() and _extras_done()) or day >= MAX_DAYS:
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
			if a.has_meta("builds_house") or a.has_meta("merchant"):
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
			if not home.is_empty() and home.owner != a and not a.has_meta("merchant") and not (a.has_meta("employer") and is_instance_valid(a.get_meta("employer"))):
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
		if buyer == null:   # everyone has work: any household that is not the merchant will do
			for a in v.households:
				if is_instance_valid(a) and a != own and not a.has_meta("merchant") and not a.has_meta("builds_house"):
					buyer = a
					break
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
		# 6. Bread is gone and dear in village 2; village 1 has plenty.
		for a in v.households:
			if is_instance_valid(a) and a.has_meta("merchant"):
				merchant = a
		if merchant != null and v2 != null:
			v.market.bread = maxi(v.market.bread, v.market.bread_target + 20)
			v2.market.bread = 0
			v2.market.bread_price = v.market.bread_price * 1.8
			merchant_cash = merchant.get_cash()
			print("[FEATURES] day %d: bread $%.2f with %d on the shelf in village 1, $%.2f and none in village 2; %s has $%.0f" % [
				day, v.market.bread_price, v.market.bread, v2.market.bread_price, merchant.name, merchant_cash])
		# 8. The woodworker (owns the house they live in) gets money to spare.
		improver = v.all_woodworkers[0] if not v.all_woodworkers.is_empty() else null
		if improver != null:
			improver.wallet.credit(500.0)
			var ihome: Dictionary = hs._home_of(improver)
			if not ihome.is_empty() and ihome.owner == improver:
				ihome.level = 2   # already a proper house, so a servant can be taken on (check 10)
			print("[FEATURES] day %d: %s has $%.0f to spare" % [day, improver.name, improver.get_cash()])

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
		# 6. merchant abroad
		if merchant != null and is_instance_valid(merchant) and v2 != null and merchant.current_village_ref == v2:
			merchant_seen_abroad = true
		# 10. a servant at the master's house
		for hh in hs.houses:
			for s in hh.get("servants", []):
				if is_instance_valid(s) and hh.get("node") != null:
					var sd: float = s.global_position.distance_to(hh.node.global_position)
					if sd < servant_near:
						servant_near = sd
						servant_name = "%s for %s" % [s.name, hh.owner.name]
		# 7. a hired hand at the workplace
		for a in v.households:
			if not is_instance_valid(a) or not (a.has_meta("employer") and is_instance_valid(a.get_meta("employer"))):
				continue
			var hj = a.current_job
			if hj is HouseholdJob and hj.work_site != null and is_instance_valid(hj.work_site):
				var dd: float = a.global_position.distance_to(hj.work_site.global_position)
				if dd < hand_near:
					hand_near = dd
					hand_name = "%s for %s (%s)" % [a.name, a.get_meta("employer").name, hj.work_kind]
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

	func _extras_done() -> bool:
		var traded: bool = merchant == null or not is_instance_valid(merchant) or int(merchant.get_meta("trade_trips", 0)) > 0
		return traded and v.housing.stats.improved > 0 and hand_near < 20.0 and servant_near < 20.0 and v.calendar.day_index >= 12

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
		# Free of this job: not recorded on the finished house, and not marked as building it.
		# (They may well have other work by now: a hand, a servant, another building.)
		var still_on_it: bool = job_worker != null and is_instance_valid(job_worker) and job_worker.has_meta("builds_house") and int(job_worker.get_meta("builds_house")) == int(job.id)
		var released: bool = job_worker != null and is_instance_valid(job_worker) and job.get("worker") == null and not still_on_it
		_check("the worker is released from the job when the house is done", released or job_worker == null, "")
		_check("builders paid wages", hs.stats.wages_paid > 0.0, "$%.2f paid over %d hired days" % [hs.stats.wages_paid, hs.stats.hired_days])

		# 6. merchant
		var trips: int = int(merchant.get_meta("trade_trips", 0)) if merchant != null and is_instance_valid(merchant) else 0
		var mprofit: float = float(merchant.get_meta("trade_profit_total", 0.0)) if merchant != null and is_instance_valid(merchant) else 0.0
		_check("the merchant carried goods to the other village and sold them", trips > 0 and merchant_seen_abroad,
			"%d sale(s), seen in village 2: %s, last: %s" % [trips, merchant_seen_abroad,
				str(merchant.get_meta("trade_last", "")) if merchant != null and is_instance_valid(merchant) else "no merchant"])
		_check("the merchant made money on it", mprofit > 0.0, "profit $%.2f, village 1 trade so far: %d units" % [mprofit, v.trade_stats.units])
		# 7. hands
		_check("a hired hand walked to the employer's workplace", hand_near < 20.0,
			"%s, closest %.0f px" % [hand_name if hand_name != "" else "nobody hired", hand_near])
		# 8. improving
		var better := ""
		for hh in hs.houses:
			if hh.done and int(hh.get("level", 1)) >= 2 and hh.owner != null and is_instance_valid(hh.owner):
				better += "%s's home is now a %s; " % [hh.owner.name, Housing.level_name(int(hh.level))]
		_check("an owner with money to spare improved their home", hs.stats.improved > 0 and better != "",
			"%simprovements finished %d, started %d" % [better, hs.stats.improved, hs.stats.improve_started])
		# 10. servants
		_check("an owner with a proper house keeps a paid servant who works there", servant_near < 20.0 and hs.stats.servant_wages > 0.0,
			"%s, closest %.0f px, $%.2f paid over %d days" % [servant_name if servant_name != "" else "no servant", servant_near, hs.stats.servant_wages, hs.stats.servant_days])
		# 9. cottagers
		var cott := 0
		var cott_ok := 0
		for a in v.households:
			if is_instance_valid(a) and a.has_meta("cottager"):
				cott += 1
				var ch: Dictionary = hs._home_of(a)
				if a.inv.get_qty("bread") > 0 and a.hunger.hunger_days >= 3 and (ch.is_empty() or int(ch.get("unpaid", 0)) == 0):
					cott_ok += 1
		_check("people with no work eat from a garden plot and keep their home", cott == cott_ok,
			"%d without work, %d fed and housed, nobody left town: %s" % [cott, cott_ok, v.labor_market.idle_count >= 0])
		# 4. eating at 0: a household holding one loaf, hunger about to run out, already ate today.
		var eater = null
		for a in v.households + v.all_woodworkers:
			if a != null and is_instance_valid(a) and not [own, buyer, job_worker].has(a) and not a.has_meta("merchant"):
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
			# First with bread on the shelf: someone holding coins buys a loaf on the spot and lives.
			v.market.bread = maxi(v.market.bread, 5)
			var cash0: float = farmer.get_cash()
			farmer.inv.items["bread"] = 0
			farmer.hunger.hunger_days = 1
			farmer.hunger._on_day_changed(day)
			_check("someone with coins and bread on the shelf buys a loaf at the last moment and lives",
				v.all_farmers.has(farmer) and not farmer.hunger.is_starving and farmer.get_cash() < cash0,
				"alive: %s, paid $%.2f, hunger %d" % [v.all_farmers.has(farmer), cash0 - farmer.get_cash(), farmer.hunger.hunger_days])
			# Then with no bread to be had anywhere: death.
			v.market.bread = 0
			var deaths_before: int = v.starved_deaths
			var purse_before: float = v.market.money
			var cash: float = farmer.get_cash()
			farmer.inv.items["bread"] = 0
			farmer.hunger.hunger_days = 1
			farmer.hunger._on_day_changed(day)
			var gone: bool = not v.all_farmers.has(farmer)
			_check("a farmer whose hunger hits 0 with no bread to be had dies and is removed",
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
	Tuning.clear()
	Tuning.set_value("merchants", true)   # off in the game for now; this test checks them
	Tuning.keep_on_restart = true
	var probe := Probe.new()
	probe.name = "FeatureProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
