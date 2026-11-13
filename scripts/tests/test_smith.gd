extends Node
## Smith test (docs/SMITH.md). Runs the real game (Main.tscn, 10x) twice.
##
##   1. A normal game starts with no smith and no tools, and in a village of three shops a
##      smithy would not be a living, so nobody opens one.
##   2. In a bigger town with a smith: the smith makes tools at the forge with firewood and
##      puts them out; shops buy them and the smith is paid, not the town; a shop with tools
##      makes a tenth more; a bigger shop wears out more tools; a shop buys a tool only when
##      it is worth its price, and never with its food money; a shop's upkeep is the tools it
##      wears out; and a smithy is not a trade the town replaces at once.
##
##   godot --headless --fixed-fps 30 --path . res://scenes/TestSmith.tscn
## Exit code 0 when every check passes.


class Probe extends Node:
	var phase := 1
	var stage := 0
	var results := []
	var done := false
	var started_ms := 0
	var day0 := -1
	var smith_cash := 0.0
	var purse := 0.0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		started_ms = Time.get_ticks_msec()

	func _check(label: String, ok: bool, detail: String = "") -> void:
		results.append(ok)
		print("[SMITH TEST] %s %s%s" % ["PASS" if ok else "FAIL", label, "" if detail == "" else " (" + detail + ")"])

	func _near(a: float, b: float) -> bool:
		return absf(a - b) < 0.011

	func _process(_d: float) -> void:
		if done:
			return
		if Time.get_ticks_msec() - started_ms > 360000:
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
		if v.calendar == null or v.market == null or v.labor_market == null or v.recovery == null:
			return
		var day: int = v.calendar.day_index
		var m = v.market
		var lm = v.labor_market
		if phase == 1:
			if day >= 6:
				_check("a normal game starts with no smith and no tools", v.all_smiths.is_empty() and m.has_good("tools") and m.good_stock("tools") == 0 and v.smithy != null,
					"%d smiths, %d tools on the shelf" % [v.all_smiths.size(), m.good_stock("tools")])
				var someone = v.households[0] if not v.households.is_empty() else null
				var ce = someone.get_node_or_null("CareerEvaluator") if someone != null else null
				var spend: Dictionary = lm.tool_spending_per_day()
				_check("in a village of three shops a smithy would not be a living", ce != null and lm._smith_utility(ce) < 0.0 and float(spend.tools) < 1.0,
					"the shops would use %.2f tools a day; a smith would clear %.2f a day" % [float(spend.tools), lm._smith_utility(ce) if ce != null else 0.0])
				_check("and a smithy is not a trade the town fills at once", not bool(Recovery.TRADES["Smith"].get("basic", true)) and not v.recovery._wanted("Smith", 0))
				phase = 2
				stage = 0
				Tuning.clear()
				Tuning.set_value("troubles", false)
				Tuning.set_value("arrival_prosperity_bar", 2.0)   # staged: nobody new comes
				Tuning.set_value("home_improvements", false)
				for pair in [["farmers", 2], ["bakers", 2], ["woodworkers", 1], ["smiths", 1], ["others", 8], ["coins_owners", 400.0], ["market_firewood", 70], ["market_wheat", 60], ["market_bread", 40]]:
					Tuning.set_value(str(pair[0]), pair[1])
				Tuning.source = "TestSmith"
				Tuning.keep_on_restart = true
				main.get_node("DevMenu").restart()
			return
		if v.all_smiths.is_empty() or v.all_bakers.is_empty():
			return
		var smith = v.all_smiths[0]
		var baker = v.all_bakers[0]
		match stage:
			0:
				if day >= 2:
					smith_cash = smith.get_cash()
					purse = m.money
					day0 = day
					stage = 1
			1:
				if day >= day0 + 12:
					var g: Dictionary = m.goods["tools"]
					_check("the smith makes tools and puts them out at the market", int(g["in"]) > 0 and str(smith.current_role) == "Smith",
						"%d tools put out in %d days" % [int(g["in"]), day - day0])
					var with_tools := 0
					for p in v.all_farmers + v.all_bakers + v.all_woodworkers:
						if is_instance_valid(p) and p.inv.get_qty("tools") > 0:
							with_tools += 1
					_check("shops buy them", int(g.out) > 0 and with_tools > 0, "%d bought; %d shops have tools" % [int(g.out), with_tools])
					_check("the buyers pay the smith, not the town", float(m.paid_to_makers.tools) > 0.0 and _near(float(m.paid_to_town.tools), 0.0),
						"%.1f coins to the smith, %.1f to the town" % [float(m.paid_to_makers.tools), float(m.paid_to_town.tools)])
					# A shop with tools makes a tenth more.
					var had: int = baker.inv.get_qty("tools")
					baker.inv.items["tools"] = 0
					var without: int = baker.current_job._oven_capacity()
					var f0: float = LaborMarket.tool_factor(baker)
					baker.inv.items["tools"] = 1
					var with_one: int = baker.current_job._oven_capacity()
					_check("a shop with tools makes a tenth more", _near(f0, 1.0) and _near(LaborMarket.tool_factor(baker), 1.1) and with_one > without,
						"%d loaves a day with tools, %d without" % [with_one, without])
					# A bigger shop wears out more.
					var kept_hands: Array = (baker.get_meta("hands", []) as Array).duplicate()
					baker.set_meta("hands", [])
					var alone: float = LaborMarket.tools_per_day(baker)
					baker.set_meta("hands", [v.households[0], v.households[1]])
					var three: float = LaborMarket.tools_per_day(baker)
					baker.set_meta("hands", kept_hands)
					_check("a bigger shop wears out more tools", _near(alone, 1.0 / 8.0) and _near(three, 3.0 / 8.0), "%.3f a day alone, %.3f with two hands" % [alone, three])
					_check("a shop's upkeep is the tools it wears out, at today's price", _near(baker.current_job.maintenance_cost_per_day, LaborMarket.tools_per_day(baker) * m.good_price("tools"))
						and baker.current_job.maintenance_cost_per_day > 0.0, "%.2f coins a day" % baker.current_job.maintenance_cost_per_day)
					# Worth its price, or not bought.
					var worth: float = lm.tool_worth(baker)
					var price_was: float = m.good_price("tools")
					m.goods["tools"].price = worth * 2.0 + 1.0
					var no_at_twice: bool = not lm.wants_tools(baker)
					m.goods["tools"].price = maxf(0.5, worth * 0.5)
					var yes_at_half: bool = lm.wants_tools(baker) or worth <= 0.0
					_check("a shop buys a tool only when it is worth its price", worth > 0.0 and no_at_twice and yes_at_half, "a tool is worth %.2f to the baker" % worth)
					# Food money first.
					baker.inv.items["tools"] = 0
					var cash: float = baker.get_cash()
					baker.wallet.debit(cash - 5.0)   # staged: five coins left
					var out_then: int = int(m.goods["tools"].out)
					lm._update_tools(day)
					var bought_poor: int = baker.inv.get_qty("tools")
					baker.wallet.credit(cash - 5.0)
					m._shelve_for_test("tools", smith, 20)   # staged: tools on the shelf to buy (enough for every shop)
					lm._update_tools(day)
					_check("no tools are bought with the food money", bought_poor == 0 and baker.inv.get_qty("tools") > 0,
						"none with 5 coins; %d with %.0f" % [baker.inv.get_qty("tools"), baker.get_cash()])
					m.goods["tools"].price = price_was
					baker.inv.items["tools"] = maxi(had, baker.inv.get_qty("tools"))
					_check("nobody starved", v.starved_deaths == 0, "%d" % v.starved_deaths)
					Tuning.set_value("tools", false)
					_check("with the switch off, shops use no tools", _near(LaborMarket.tool_factor(baker), 1.0) and not lm.wants_tools(baker) and _near(LaborMarket.tool_cost_per_day(baker), 0.0))
					_finish()

	func _finish() -> void:
		done = true
		Tuning.clear()
		Tuning.keep_on_restart = false
		var fails: int = results.count(false)
		print("[SMITH TEST] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	Tuning.clear()
	Tuning.set_value("troubles", false)
	Tuning.set_value("arrival_prosperity_bar", 2.0)   # staged: nobody new comes during the test
	Tuning.source = "TestSmith"
	Tuning.keep_on_restart = true
	var probe := Probe.new()
	probe.name = "SmithProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
