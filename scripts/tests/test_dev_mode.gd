extends Node
## Dev mode test (docs/DEV_MODE.md). Runs the real game (Main.tscn) three times in one go:
##
##   1. Nothing set. Every built-in value in the Tuning table matches the code, and each input,
##      once set, reaches the code that uses it (one check per input).
##   2. A starting town set from Tuning and started through the dev menu's own restart: the
##      town comes out with exactly the people, coins, market stock, prices and prosperity
##      asked for, everyone has a house on the first morning, the switches hold, and the menu
##      shows and returns what is set.
##   3. A town started with the merchant switched off has no merchant.
##
##   godot --headless --fixed-fps 30 --path . res://scenes/TestDevMode.tscn
## Exit code 0 when every check passes.

const RUN_DAYS := 12


class Probe extends Node:
	var phase := 0
	var results := []
	var done := false
	var started_ms := 0
	var bus_lines: Array = []
	var busy := false
	var p1_checked_start := false
	var p1_checked_homes := false
	var p1_wait_frames := 0
	var p2_frames := 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		started_ms = Time.get_ticks_msec()

	func _check(label: String, ok: bool, detail: String = "") -> void:
		results.append({"check": label, "ok": ok, "detail": detail})
		print("[DEVMODE] %s %s%s" % ["PASS" if ok else "FAIL", label, "" if detail == "" else " (" + detail + ")"])

	func _near(a: float, b: float, tol: float = 0.011) -> bool:
		return absf(a - b) <= tol

	func _world() -> Node:
		var main := get_tree().current_scene
		if main == null or main == self:
			return null
		return main.get_node_or_null("World")

	func _process(_d: float) -> void:
		if done or busy:
			return
		if Time.get_ticks_msec() - started_ms > 240000:
			_check("finished in time", false, "phase %d" % phase)
			_finish()
			return
		var main := get_tree().current_scene
		var world := _world()
		if main == null or world == null or world.villages.size() < 2:
			return
		var clock = main.get("clock")
		if clock != null and clock.speed_multiplier < 10.0:
			clock.set_speed(10.0)
		var v = world.villages[0]
		if v == null or v.calendar == null or v.market == null:
			return
		match phase:
			0:
				if clock != null and clock.tick >= 6 and v.all_woodworkers.size() >= 1:
					busy = true
					await _phase0(main, world, v)
					busy = false
			1:
				_phase1(main, world, v)
			2:
				_phase2(world)

	# ── 1. Built-in values and one check per input ──────────────────────────
	func _phase0(main: Node, world: Node, v) -> void:
		var m: Market = v.market
		var baker = v.all_bakers[0]
		var farmer = v.all_farmers[0]
		var wood = v.all_woodworkers[0]
		var keys := {}
		var dupes := 0
		for row in Tuning.INPUTS + Tuning.START:
			if keys.has(row.k):
				dupes += 1
			keys[row.k] = true
		_check("every setting has its own name", dupes == 0, "%d settings" % keys.size())
		_check("nothing is set in a normal game", Tuning.values.is_empty() and not Tuning.has_start())

		var fresh_market := Market.new()
		var fresh_meter := ProsperityMeter.new()
		# The three upkeep dials apply when the market buys with its own purse; with buyers
		# paying makers a shop's upkeep is the tools it wears out (docs/SMITH.md).
		Tuning.set_value("buy_from_makers", false)
		var old_upkeep := [float(farmer.current_job.maintenance_cost_per_day), float(baker.current_job.maintenance_cost_per_day), float(wood.current_job.maintenance_cost_per_day)]
		Tuning.values.erase("buy_from_makers")
		var code := {
			"day_seconds": SimulationClock.TICK_SECONDS * 10.0,
			"baker_loaves_per_day": float(baker.current_job.oven_capacity_per_day),
			"woodworker_logs_per_day": float(WoodworkerJob.FIREWOOD_PER_DAY),
			"hand_output_1": float(LaborMarket.HAND_STEPS[1]), "hand_output_2": float(LaborMarket.HAND_STEPS[2]),
			"max_hands_per_shop": float(LaborMarket.MAX_HANDS),
			"household_start_coins": HouseholdJob.STARTING_CASH, "owner_start_coins": FarmerJob.STARTING_CASH,
			"merchant_start_coins": MerchantJob.OWNER_CASH, "market_start_coins": Market.START_MONEY,
			"wage_markup": LaborMarket.WAGE_MARKUP, "shop_savings_needed": LaborMarket.SAVINGS_BUFFER_REQUIRED,
			"shop_opening_fee": LaborMarket.STARTUP_COST,
			"upkeep_farmer": float(old_upkeep[0]), "upkeep_baker": float(old_upkeep[1]),
			"upkeep_woodworker": float(old_upkeep[2]),
			"smith_tools_per_day": float(SmithJob.TOOLS_PER_DAY), "tool_days": LaborMarket.TOOL_DAYS,
			"price_daily_limit": Market.MAX_DAILY_PRICE_CHANGE,
			"arrival_prosperity_bar": float(v.prosperity_meter.PROSPERITY_THRESHOLD_TO_GROW), "arrival_wait_days": float(v.prosperity_meter.GROWTH_COOLDOWN_DAYS),
			"arrival_max_idle": float(v.MAX_IDLE_FOR_ARRIVAL), "town_size_limit": float(PopulationManager.MAX_TOTAL_POP),
			"house_logs": float(Housing.HOUSE_WOOD), "house_build_days": float(Housing.BUILD_DAYS), "houses_spare_at_start": float(Housing.START_SPARE),
			"coins_others": HouseholdJob.STARTING_CASH, "coins_owners": BakerJob.STARTING_CASH, "market_coins": Market.START_MONEY,
			"market_wheat": float(v.economy_config.get("market_seed", {}).get("initial_market_wheat", 40)),
			"market_bread": float(v.economy_config.get("market_seed", {}).get("initial_market_bread", 20)),
			"market_firewood": float(fresh_market.firewood), "bread_price": fresh_market.bread_price,
			"wheat_price": fresh_market.wheat_price, "firewood_price": fresh_market.firewood_price,
			"prosperity": fresh_meter.prosperity_score,
		}
		fresh_market.free()
		fresh_meter.free()
		var wrong: Array = []
		for k in code:
			if not _near(float(Tuning.default_of(k)), float(code[k])):
				wrong.append("%s table %s code %s" % [k, str(Tuning.default_of(k)), str(code[k])])
		_check("built-in values in the table match the code", wrong.is_empty(), "%d compared%s" % [code.size(), "" if wrong.is_empty() else ": " + "; ".join(wrong)])
		_check("woodworker and farmer start with the owner's purse too", _near(WoodworkerJob.OWNER_CASH, FarmerJob.STARTING_CASH))

		_check("an unknown name is refused", not Tuning.set_value("no_such_setting", 1) and Tuning.errors.size() == 1, str(Tuning.errors))
		Tuning.clear()

		# One check per input: set it, ask the code that uses it.
		Tuning.set_value("day_seconds", 40.0)
		_check("day length reaches the clock", _near(main.clock.tick_seconds(), 4.0), "tick %.2f s" % main.clock.tick_seconds())
		Tuning.set_value("baker_loaves_per_day", 6)
		var want_oven: int = maxi(1, roundi(6.0 * m.oven_mult * m.shock_oven_mult * LaborMarket.hand_mult(baker)))
		_check("baker output reaches the oven", baker.current_job._oven_capacity() == want_oven, "%d a day" % baker.current_job._oven_capacity())
		Tuning.set_value("woodworker_logs_per_day", 5)
		_check("woodworker output reaches the yard", wood.current_job._capacity() == roundi(5.0 * SkillSet.factor(wood.skill_in("Woodworker")) * LaborMarket.hand_mult(wood)), "%d a day" % wood.current_job._capacity())
		Tuning.set_value("hand_output_1", 2.0)
		Tuning.set_value("hand_output_2", 3.0)
		_check("hand output steps reach the labour market", LaborMarket.hand_steps() == [1.0, 2.0, 3.0], str(LaborMarket.hand_steps()))
		Tuning.set_value("wage_markup", 2.0)
		_check("wage markup reaches the wage", _near(LaborMarket.daily_wage(m), (m.bread_price + m.firewood_price) * 2.0), "%.2f" % LaborMarket.daily_wage(m))
		Tuning.set_value("upkeep_farmer", 1.5)
		Tuning.set_value("upkeep_baker", 2.5)
		Tuning.set_value("upkeep_woodworker", 3.5)
		Tuning.set_value("buy_from_makers", false)
		_check("upkeep reaches all three trades (when the market buys with its own purse)", _near(farmer.current_job.maintenance_cost_per_day, 1.5) and _near(baker.current_job.maintenance_cost_per_day, 2.5)
			and _near(wood.current_job.maintenance_cost_per_day, 3.5))
		Tuning.values.erase("buy_from_makers")
		Tuning.set_value("tool_days", 4.0)
		_check("tool life reaches the shops", _near(LaborMarket.tools_per_day(baker), (1.0 + float(LaborMarket.hands_of(baker))) / 4.0))
		Tuning.set_value("smith_tools_per_day", 9)
		var a_smith := SmithJob.new()
		_check("smith output has a dial", int(Tuning.i("smith_tools_per_day", SmithJob.TOOLS_PER_DAY)) == 9)
		a_smith.free()
		Tuning.set_value("town_size_limit", 33)
		_check("town size limit reaches the village", int(v.MAX_TOTAL_POP) == 33 and not v.pop_mgr.is_at_pop_cap())
		Tuning.set_value("arrivals_follow_jobs", false)   # the old idle limit only applies with this off
		Tuning.set_value("arrival_max_idle", 7)
		var idle_before: int = v.labor_market.idle_count
		v.labor_market.idle_count = 7
		var ok_at_7: bool = v.room_for_newcomer()
		v.labor_market.idle_count = 8
		var ok_at_8: bool = v.room_for_newcomer()
		v.labor_market.idle_count = idle_before
		_check("idle limit reaches the newcomer rule", ok_at_7 and not ok_at_8)
		Tuning.set_value("arrivals_follow_jobs", true)
		v.labor_market.idle_count = 8
		var jobs_before: int = v.labor_market.last_open_job_day
		v.labor_market.last_open_job_day = -999
		var means_when_no_job: bool = v.room_for_newcomer() and v.newcomer_has_means()
		v.labor_market.last_open_job_day = v.calendar.day_index
		var still_means_while_people_lack_work: bool = v.newcomer_has_means()
		v.labor_market.idle_count = 0
		var worker_when_job: bool = v.room_for_newcomer() and not v.newcomer_has_means() and still_means_while_people_lack_work
		v.labor_market.last_open_job_day = jobs_before
		v.labor_market.idle_count = idle_before
		_check("who arrives follows jobs: someone with means when no job waits, a worker when one does", means_when_no_job and worker_when_job and _near(v.means_purse(), 150.0))
		var pm = v.prosperity_meter
		var score_before: float = pm.prosperity_score
		var spawn_before: int = pm.last_spawn_day
		pm.prosperity_score = 0.5
		pm.last_spawn_day = 100
		Tuning.set_value("arrival_prosperity_bar", 0.4)
		Tuning.set_value("arrival_wait_days", 10)
		var soon: bool = pm.should_spawn_household(105)
		var later: bool = pm.should_spawn_household(110)
		Tuning.set_value("arrival_prosperity_bar", 0.6)
		var too_poor: bool = pm.should_spawn_household(110)
		pm.prosperity_score = score_before
		pm.last_spawn_day = spawn_before
		_check("prosperity bar and wait reach the newcomer rule", not soon and later and not too_poor)
		Tuning.set_value("house_logs", 8)
		Tuning.set_value("house_build_days", 3)
		_check("house cost reaches housing", _near(v.housing.wood_cost(), 8.0 * m.firewood_price) and _near(v.housing.labour_cost(), 3.0 * LaborMarket.daily_wage(m)))
		Tuning.set_value("price_daily_limit", 0.2)
		var pm2 := Market.new()
		pm2.firewood = 15
		pm2.firewood_target = 30
		pm2.firewood_price = 1.0
		pm2.firewood_wanted_today = 4   # somebody with coins asked for firewood today
		pm2._adjust_firewood_price()
		_check("daily price limit reaches the price rule", _near(pm2.firewood_price, 1.0 + 0.2 * 0.5, 0.001), "1.00 -> %.3f" % pm2.firewood_price)
		var pm3 := Market.new()
		pm3.firewood = 0
		pm3.firewood_target = 30
		pm3.firewood_price = 7.0
		pm3._adjust_firewood_price()
		_check("firewood has no ceiling, and with nobody buying an empty pile does not bid itself up", _near(pm3.firewood_price, 7.0, 0.001), "7.00 -> %.3f" % pm3.firewood_price)
		pm3.firewood_wanted_today = 2
		pm3.firewood_short_today = 2
		pm3._adjust_firewood_price()
		_check("with buyers going short it rises past the old 5.00 ceiling", _near(pm3.firewood_price, 7.0 * 1.12, 0.001), "7.00 -> %.3f" % pm3.firewood_price)
		pm3.free()
		pm2.bread_price = 9.0
		pm2.bread = 0
		pm2.bread_total_cleared = 0
		pm2.bread_short_today = 3
		pm2._adjust_bread_price(1)
		_check("daily price limit reaches the bread price, with no ceiling", _near(pm2.bread_price, 9.9, 0.001), "9.00 -> %.2f with an empty shelf" % pm2.bread_price)
		pm2.free()
		# Harvest: the same ripe field at 100% and at 50%.
		var gains: Array = []
		for pct in [100.0, 50.0]:
			Tuning.set_value("farmer_harvest_percent", pct)
			var plot := FieldPlot.new()
			plot.state = FieldPlot.State.PLANTED
			plot.ticks_to_mature = 0
			var job = farmer.current_job
			var had: int = farmer.inv.get_qty("wheat")
			var worked: int = job.fields_worked_today
			job.fields_worked_today = 0
			job.handle_field_arrival(plot, "test field")
			gains.append(farmer.inv.get_qty("wheat") - had)
			farmer.inv.items["wheat"] = had
			job.fields_worked_today = worked
			plot.free()
		_check("harvest percent reaches the farm", int(gains[0]) > 0 and absi(int(gains[1]) * 2 - int(gains[0])) <= 1, "%d wheat at 100%%, %d at 50%%" % [gains[0], gains[1]])
		# Opening fee and savings, on a newcomer.
		Tuning.set_value("household_start_coins", 77.0)
		var h = await v.spawn_household_at(v.get_spawn_point_for_role("household"))
		_check("newcomer purse reaches a new arrival", h != null and _near(h.wallet.money, 77.0), "%.1f coins" % (h.wallet.money if h else -1.0))
		if h != null:
			Tuning.set_value("shop_opening_fee", 7.0)
			var purse_before: float = h.wallet.money
			var market_before: float = m.money
			v._pay_startup(h, false)
			_check("opening fee reaches the market", _near(purse_before - h.wallet.money, 7.0) and _near(m.money - market_before, 7.0))
			var ce = h.get_node_or_null("CareerEvaluator")
			if ce != null:
				v.event_bus.event_logged.connect(_on_bus)
				h.switch_cooldown_days = 0
				h.days_in_role = 999
				ce.recommended_role = "Baker"
				Tuning.set_value("shop_savings_needed", 100000.0)
				bus_lines = []
				v.labor_market._reset_eval_diag()
				v.labor_market._log_career_eval(v.calendar.day_index, h, ce)
				var blocked: bool = "\n".join(bus_lines).contains("block=savings")
				Tuning.set_value("shop_savings_needed", 1.0)
				bus_lines = []
				v.labor_market._log_career_eval(v.calendar.day_index, h, ce)
				var freed: bool = not "\n".join(bus_lines).contains("block=savings")
				v.event_bus.event_logged.disconnect(_on_bus)
				_check("savings needed reaches the shop-opening rule", blocked and freed)
			else:
				_check("savings needed reaches the shop-opening rule", false, "no career evaluator on the newcomer")
		var merchant = null
		for a in v.households:
			if a != null and is_instance_valid(a) and a.has_meta("merchant"):
				merchant = a
		_check("a normal game has no merchant (switched off for now)", merchant == null)
		Tuning.set_value("troubles", false)
		v.shocks.active = {}
		for n in 400:
			v.shocks.on_day(1000 + n)
		_check("troubles switch stops troubles", v.shocks.active.is_empty())
		Tuning.clear()
		for n in 400:
			if v.shocks.active.is_empty():
				v.shocks.on_day(2000 + n)
		_check("troubles come back when the switch is cleared", not v.shocks.active.is_empty())

		# Scenario files: save, load, and every shipped one reads cleanly.
		Tuning.clear()
		Tuning.set_value("baker_loaves_per_day", 9)
		Tuning.set_value("people", 21)
		Tuning.set_value("v2.market_coins", 123.0)
		var saved: Dictionary = Tuning.to_dict()
		var path: String = Tuning.save_file("test_dev_mode_tmp")
		Tuning.clear()
		var loaded_ok: bool = Tuning.load_file("test_dev_mode_tmp")
		_check("a saved scenario loads back the same", path != "" and loaded_ok and Tuning.to_dict() == saved, str(Tuning.to_dict()))
		if path != "":
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		var shipped: Array = []
		var bad: Array = []
		var da := DirAccess.open("res://scenarios")
		if da != null:
			for fname in da.get_files():
				if fname.ends_with(".json"):
					shipped.append(fname)
					Tuning.clear()
					if not Tuning.load_file("res://scenarios/" + fname) or not Tuning.errors.is_empty():
						bad.append("%s: %s" % [fname, str(Tuning.errors)])
		_check("every shipped scenario reads cleanly", shipped.size() >= 3 and bad.is_empty(), "%d files%s" % [shipped.size(), "" if bad.is_empty() else " " + "; ".join(bad)])

		# 2. Start a town through the dev menu's own restart.
		Tuning.clear()
		for pair in [["farmers", 2], ["bakers", 3], ["woodworkers", 2], ["others", 17], ["coins_others", 80.0], ["coins_owners", 210.0],
				["market_coins", 4321.0], ["market_wheat", 85], ["market_bread", 95], ["market_firewood", 75], ["bread_price", 2.9],
				["wheat_price", 1.2], ["firewood_price", 1.1], ["prosperity", 0.9], ["v2.others", 4], ["v2.market_coins", 999.0],
				["houses_spare_at_start", 3], ["gardens", false], ["servants", false], ["home_improvements", false], ["troubles", false],
				["town_size_limit", 40], ["arrivals_follow_jobs", false], ["merchants", true], ["merchant_start_coins", 222.0]]:
			Tuning.set_value(str(pair[0]), pair[1])
		Tuning.source = "test"
		var dm = main.get_node_or_null("DevMenu")
		_check("the game has a dev menu", dm != null)
		phase = 1
		if dm != null:
			dm.restart()
		else:
			_finish()

	func _on_bus(msg: String) -> void:
		bus_lines.append(msg)

	func _cash_all(list: Array, want: float) -> bool:
		for a in list:
			if a == null or not is_instance_valid(a) or not _near(a.get_cash(), want, 0.05):
				return false
		return true

	# ── 2. The starting town ────────────────────────────────────────────────
	func _phase1(main: Node, world: Node, v) -> void:
		if not world.get_meta("dev_start_done", false):
			p1_wait_frames += 1
			if p1_wait_frames > 2000:
				_check("the starting town was built", false, "never finished")
				_finish()
			return
		var v2 = world.villages[1]
		var m: Market = v.market
		if not p1_checked_start:
			p1_checked_start = true
			var others: Array = DevStart._others(v)
			_check("village 1 has the people asked for", v.all_farmers.size() == 2 and v.all_bakers.size() == 3 and v.all_woodworkers.size() == 2 and others.size() == 17,
				"%d farmers, %d bakers, %d woodworkers, %d others, %d in all" % [v.all_farmers.size(), v.all_bakers.size(), v.all_woodworkers.size(), others.size(), v.pop_mgr.count()])
			_check("village 2 follows its own count", DevStart._others(v2).size() == 4 and v2.all_bakers.size() == 3, "%d others, %d bakers" % [DevStart._others(v2).size(), v2.all_bakers.size()])
			_check("people with no shop hold the coins asked for", _cash_all(others, 80.0))
			_check("shop owners hold the coins asked for", _cash_all(v.all_farmers, 210.0) and _cash_all(v.all_bakers, 210.0) and _cash_all(v.all_woodworkers, 210.0))
			var merchant = null
			for a in v.households:
				if a != null and is_instance_valid(a) and a.has_meta("merchant"):
					merchant = a
			_check("the merchant got the purse set by the input", merchant != null and _near(merchant.get_cash(), 222.0, 0.05), "%.1f" % (merchant.get_cash() if merchant else -1.0))
			Tuning.set_value("merchants", false)
			_check("merchant switch stops trading", merchant != null and not merchant.current_job._trading_allowed())
			Tuning.set_value("merchants", true)
			_check("market purse and shelves are as asked", _near(m.money, 4321.0) and m.wheat == 85 and m.bread == 95 and m.firewood == 75,
				"%.0f coins, wheat %d, bread %d, wood %d" % [m.money, m.wheat, m.bread, m.firewood])
			_check("prices are as asked", _near(m.bread_price, 2.9) and _near(m.wheat_price, 1.2) and _near(m.firewood_price, 1.1))
			_check("village 2 has its own market purse", _near(v2.market.money, 999.0), "%.0f" % v2.market.money)
			_check("prosperity is as asked", _near(v.prosperity_meter.prosperity_score, 0.9))
			_check("the clock waited for the town and is running", main.clock.running and v.calendar.day_index == 0, "day %d" % v.calendar.day_index)
			_check("town size limit holds in the new town", int(v.MAX_TOTAL_POP) == 40)
			# The menu shows and returns what is set.
			var dm = main.get_node_or_null("DevMenu")
			dm.toggle()
			var got: Dictionary = dm.collect()
			var same_inputs: bool = got.inputs.size() == Tuning.values.size()
			for k in Tuning.values:
				if not got.inputs.has(k) or not DevMenu._same(got.inputs[k], Tuning.values[k]):
					same_inputs = false
			var same_start: bool = got.start.size() == Tuning.start.size()
			for k in Tuning.start:
				if not got.start.has(k) or not DevMenu._same(got.start[k], Tuning.start[k]):
					same_start = false
			_check("the menu has a row for every setting", dm._fields.size() == Tuning.INPUTS.size() + Tuning.START.size(), "%d rows" % dm._fields.size())
			_check("the menu shows what is set", dm.is_open() and same_inputs and same_start, "%s | %s" % [str(got.inputs), str(got.start)])
			var line: String = DevMenu.town_line(v)
			_check("the readout names the town's levels", line.contains("25 people") and line.contains("4321 coins") and line.contains("Prosperity 0.90"), line)
			dm._on_reset()
			var blank: Dictionary = dm.collect()
			_check("Back to normal clears every row", blank.inputs.is_empty() and blank.start.is_empty())
			dm.toggle()
			return
		var day: int = v.calendar.day_index
		if day >= 2 and not p1_checked_homes:
			p1_checked_homes = true
			var homeless := 0
			var people := 0
			for group in [v.all_farmers, v.all_bakers, v.all_woodworkers, v.households]:
				for a in group:
					if a != null and is_instance_valid(a):
						people += 1
						if v.housing._home_of(a).is_empty():
							homeless += 1
			var hs: Dictionary = v.housing.summary()
			_check("everyone has a house on the first morning", homeless == 0 and int(hs.houses) == people + 3 and int(hs.empty) == 3,
				"%d people, %d houses, %d empty, %d without a home" % [people, hs.houses, hs.empty, homeless])
		if day >= RUN_DAYS:
			var gardeners := 0
			for a in v.households:
				if a != null and is_instance_valid(a) and a.has_meta("garden"):
					gardeners += 1
			var improving := 0
			for h in v.housing.houses:
				if h.get("up") != null or int(h.get("level", 1)) > 1:
					improving += 1
			_check("garden plots stay off", gardeners == 0)
			_check("servants stay off", v.housing.servant_count() == 0)
			_check("home improvements stay off", improving == 0 and int(v.housing.stats.improve_started) == 0)
			_check("troubles stay off", v.shocks.active.is_empty())
			_check("the town ran %d days with nobody starving" % RUN_DAYS, v.starved_deaths == 0 and v.pop_mgr.count() >= 20, "%d people, %d starved" % [v.pop_mgr.count(), v.starved_deaths])
			# 3. No merchant when the switch is off at the start.
			Tuning.clear()
			Tuning.set_value("merchants", false)
			Tuning.set_value("others", 3)
			Tuning.source = "test"
			phase = 2
			main.get_node("DevMenu").restart()

	func _phase2(world: Node) -> void:
		if not world.get_meta("dev_start_done", false):
			p2_frames += 1
			if p2_frames > 2000:
				_check("the second town was built", false)
				_finish()
			return
		var merchants := 0
		for v in world.villages:
			for a in v.households:
				if a != null and is_instance_valid(a) and (a.has_meta("merchant") or str(a.current_role) == "Merchant"):
					merchants += 1
		_check("no merchant when the switch is off", merchants == 0 and DevStart._others(world.villages[0]).size() == 3, "%d merchants" % merchants)
		_finish()

	func _finish() -> void:
		done = true
		Tuning.clear()
		Tuning.keep_on_restart = false
		var fails := 0
		for r in results:
			if not r.ok:
				fails += 1
		print("[DEVMODE] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	var probe := Probe.new()
	probe.name = "DevModeProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
