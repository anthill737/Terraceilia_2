extends Node

## Economy test. Runs the real game (Main.tscn) at 10x speed with 240 physics steps a second,
## the same way the survival test does, so people walk to the market and trade as in play.
##
## The old version stepped the village clock by hand: each game day got about a quarter of a
## second of walking, so nobody ever reached the market. Nothing was bought or sold, everyone
## starved, and it still printed PASS. This version fails if that happens.
##
## Every frame, in every village, it checks the books: no negative or NaN money or stock,
## prices inside their bands, stock within capacity, hunger in range, nobody listed twice.
## At the end it checks that the economy actually ran in every village:
##   - farmers sold wheat to the market and bakers bought wheat from it,
##   - bakers sold bread to the market and people bought bread from it,
##   - firewood was sold to the market and bought from it,
##   - someone was paid a wage,
##   - the village is still alive.
##
##   godot --headless --path . res://scenes/TestEconomy.tscn -- [--days=30] [--village-seeds=a,b]
##
## Exit code 0 on pass, 1 on any failure.

const DEFAULT_DAYS: int = 30


class Probe extends Node:
	var days: int = DEFAULT_DAYS
	var started_ms: int = 0
	var done: bool = false
	var failures: Array = []
	var frames_checked: int = 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--days="):
				days = maxi(1, int(arg.substr(7)))
		started_ms = Time.get_ticks_msec()
		print("[ECON TEST] real-time economy test, %d days per village" % days)

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
		var finished := 0
		for v in world.villages:
			if v == null or v.calendar == null or v.market == null:
				continue
			_check_books(v)
			if v.calendar.day_index >= days or v.sim_failed:
				finished += 1
		frames_checked += 1
		if failures.size() > 20:
			_finish(world)
		elif finished >= world.villages.size():
			_finish(world)
		elif Time.get_ticks_msec() - started_ms > (days * 8 + 120) * 1000:
			_fail("timed out before day %d" % days)
			_finish(world)

	func _fail(msg: String) -> void:
		if failures.size() <= 20:
			failures.append(msg)
			print("[ECON TEST] FAIL " + msg)

	func _check_books(v) -> void:
		var m = v.market
		var tag := "village %d day %d" % [v.village_id, v.calendar.day_index]
		if is_nan(m.money) or m.money < -0.001:
			_fail("%s: market money %s" % [tag, m.money])
		if m.wheat < 0 or m.bread < 0 or m.firewood < 0:
			_fail("%s: negative market stock wheat=%d bread=%d firewood=%d" % [tag, m.wheat, m.bread, m.firewood])
		if m.wheat > m.wheat_capacity or m.bread > m.bread_capacity or m.firewood > m.firewood_capacity:
			_fail("%s: market over capacity wheat=%d/%d bread=%d/%d firewood=%d/%d" % [
				tag, m.wheat, m.wheat_capacity, m.bread, m.bread_capacity, m.firewood, m.firewood_capacity])
		for pair in [["wheat", m.wheat_price, m.WHEAT_PRICE_FLOOR, INF],   # no ceiling (docs/BREAD_MARKET.md)
				["bread", m.bread_price, m.BREAD_PRICE_FLOOR, INF],
				["firewood", m.firewood_price, m.FIREWOOD_PRICE_FLOOR, INF]]:
			if is_nan(pair[1]) or pair[1] < pair[2] - 0.001 or pair[1] > pair[3] + 0.001:
				_fail("%s: %s price %s outside %.2f..%.2f" % [tag, pair[0], pair[1], pair[2], pair[3]])
		var seen := {}
		for grp in [v.households] + v.owner_groups():
			for a in grp:
				if a == null or not is_instance_valid(a):
					continue
				if seen.has(a):
					_fail("%s: %s is listed in two trades at once" % [tag, a.name])
				seen[a] = true
				var w = a.get("wallet")
				if w == null or is_nan(w.money) or w.money < -0.001:
					_fail("%s: %s wallet %s" % [tag, a.name, w.money if w else "missing"])
				var inv = a.get("inv")
				if inv != null:
					for item in inv.items.keys():
						if int(inv.items[item]) < 0:
							_fail("%s: %s has %s %s" % [tag, a.name, inv.items[item], item])
				var h = a.get("hunger")
				if h != null and (h.hunger_days < 0 or h.hunger_days > h.hunger_max_days):
					_fail("%s: %s hunger %d/%d" % [tag, a.name, h.hunger_days, h.hunger_max_days])

	func _finish(world) -> void:
		done = true
		for v in world.villages:
			if v == null or v.market == null:
				continue
			var t: Dictionary = v.market.totals
			var lm = v.labor_market
			var wages: float = lm.wages_paid_total if lm else 0.0
			var alive: int = v.households.size() + v.all_farmers.size() + v.all_bakers.size() + v.all_woodworkers.size() + v.all_smiths.size() + v.all_tailors.size()
			print("[ECON TEST] village %d after %d days: %d people, wheat farmers->market %d, market->bakers %d, bread bakers->market %d, market->people %d, firewood ->market %d, market-> %d, wages $%.0f, starved %d" % [
				v.village_id, v.calendar.day_index, alive, t.wheat_from_farmers, t.wheat_to_bakers,
				t.bread_from_bakers, t.bread_to_people, t.firewood_in, t.firewood_out, wages, v.starved_deaths])
			var need := [["people still alive", alive > 0 and not v.sim_failed],
				["farmers sold wheat", t.wheat_from_farmers > 0], ["bakers bought wheat", t.wheat_to_bakers > 0],
				["bakers sold bread", t.bread_from_bakers > 0], ["people bought bread", t.bread_to_people > 0],
				["firewood sold to the market", t.firewood_in > 0], ["firewood bought from the market", t.firewood_out > 0],
				["someone was paid a wage", wages > 0.0]]
			for n in need:
				if n[1]:
					print("[ECON TEST] PASS village %d: %s" % [v.village_id, n[0]])
				else:
					_fail("village %d: %s" % [v.village_id, n[0]])
		print("[ECON TEST] checked the books on %d frames" % frames_checked)
		if failures.is_empty():
			print("[ECON TEST] SUITE: PASS")
			get_tree().quit(0)
		else:
			print("[ECON TEST] SUITE: FAIL (%d)" % failures.size())
			get_tree().quit(1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	var probe := Probe.new()
	probe.name = "EconomyProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
