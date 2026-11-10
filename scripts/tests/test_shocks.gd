extends Node
## Shock test: runs the real game (Main.tscn, 10x) and sets troubles off on purpose, then checks
## the economy answers and recovers on its own:
##
##   Village 1: a fire at the bakery on day SHOCK_DAY (the oven bakes 30% for 4 days), and
##              rats in the market store on the same day (60% of the wheat and bread gone).
##   Village 2: blight on day SHOCK_DAY (harvests 40% for 6 days).
##
## Checks, per village:
##   - the trouble was felt: the price of the hit good rose, or its stock fell hard;
##   - the trouble ended and the multipliers went back to normal;
##   - recovery: by the end the price is back within RECOVER_BAND of what it was before;
##   - nobody starved to death, and the village did not shrink by more than one person.
## And: a merchant carried goods between the villages at least once.
##
##   godot --headless --path . res://scenes/TestShocks.tscn
## Exit code 0 when every check passes.

const SHOCK_DAY := 15
const END_DAY := 48
const RECOVER_BAND := 0.25


class Probe extends Node:
	var world = null
	var started_ms := 0
	var done := false
	var results := []
	var last_day := {}
	var rows := {}           # village id -> [{day, bread_p, wheat_p, bread, wheat, pop, starved}]
	var set_off := false

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
		world = main.get_node_or_null("World")
		if world == null or world.villages.size() < 2:
			return
		world.set_meta("no_shocks", true)   # only the troubles this test sets off
		var finished := 0
		for v in world.villages:
			if v == null or v.calendar == null or v.market == null or v.shocks == null:
				continue
			var day: int = v.calendar.day_index
			if day >= END_DAY:
				finished += 1
			if last_day.get(v.village_id, -1) == day:
				continue
			last_day[v.village_id] = day
			var m = v.market
			var pop: int = v.households.size() + v.all_farmers.size() + v.all_bakers.size() + v.all_woodworkers.size()
			if not rows.has(v.village_id):
				rows[v.village_id] = []
			rows[v.village_id].append({"day": day, "bread_p": m.bread_price, "wheat_p": m.wheat_price,
				"bread": m.bread, "wheat": m.wheat, "pop": pop, "starved": v.starved_deaths})
			if day % 3 == 0 or (day >= SHOCK_DAY and day <= SHOCK_DAY + 8):
				print("[SHOCKS] v%d day %d: bread $%.2f (%d on shelf), wheat $%.2f (%d), %d people, trouble: %s" % [
					v.village_id, day, m.bread_price, m.bread, m.wheat_price, m.wheat, pop,
					v.shocks.describe() if v.shocks.describe() != "" else "none"])
		if not set_off:
			var v1 = world.villages[0]
			var v2 = world.villages[1]
			if v1.calendar.day_index >= SHOCK_DAY and v2.calendar.day_index >= SHOCK_DAY:
				set_off = true
				v1.shocks.start("rats", SHOCK_DAY)
				v1.shocks.start("oven_fire", SHOCK_DAY)
				v2.shocks.start("blight", SHOCK_DAY)
		if finished >= world.villages.size():
			_finish()
		elif Time.get_ticks_msec() - started_ms > (END_DAY * 8 + 120) * 1000:
			_check("finished in time", false, "timed out")
			_finish()

	func _check(name: String, ok: bool, detail: String) -> void:
		results.append({"check": name, "ok": ok, "detail": detail})
		print("[SHOCKS] %s %s (%s)" % ["PASS" if ok else "FAIL", name, detail])

	func _avg(vid: int, key: String, from_day: int, to_day: int) -> float:
		var s := 0.0
		var n := 0
		for r in rows.get(vid, []):
			if r.day >= from_day and r.day <= to_day:
				s += float(r[key])
				n += 1
		return s / float(maxi(1, n))

	func _peak(vid: int, key: String, from_day: int, to_day: int) -> float:
		var best := -1.0
		for r in rows.get(vid, []):
			if r.day >= from_day and r.day <= to_day:
				best = maxf(best, float(r[key]))
		return best

	func _low(vid: int, key: String, from_day: int, to_day: int) -> float:
		var best := 1.0e9
		for r in rows.get(vid, []):
			if r.day >= from_day and r.day <= to_day:
				best = minf(best, float(r[key]))
		return best

	func _judge(v, good: String, what: String) -> void:
		var vid: int = v.village_id
		var pk: String = good + "_p"
		var before_p: float = _avg(vid, pk, SHOCK_DAY - 5, SHOCK_DAY - 1)
		var before_stock: float = _avg(vid, good, SHOCK_DAY - 5, SHOCK_DAY - 1)
		var peak_p: float = _peak(vid, pk, SHOCK_DAY, SHOCK_DAY + 14)
		var low_stock: float = _low(vid, good, SHOCK_DAY, SHOCK_DAY + 14)
		var after_p: float = _avg(vid, pk, END_DAY - 5, END_DAY)
		_check("village %d felt the %s" % [vid, what], peak_p >= before_p * 1.06 or low_stock <= before_stock * 0.5,
			"%s $%.2f before, peak $%.2f; stock %.0f before, lowest %.0f" % [good, before_p, peak_p, before_stock, low_stock])
		_check("village %d: the trouble ended and output is back to normal" % vid,
			v.shocks.active.is_empty() and is_equal_approx(v.market.shock_harvest_mult, 1.0) and is_equal_approx(v.market.shock_oven_mult, 1.0),
			"troubles so far: %d" % v.shocks.history.size())
		_check("village %d: the %s price settled back" % [vid, good], absf(after_p - before_p) <= RECOVER_BAND * before_p,
			"$%.2f before, $%.2f at the end (peak $%.2f)" % [before_p, after_p, peak_p])
		var pop_before: float = _avg(vid, "pop", SHOCK_DAY - 1, SHOCK_DAY - 1)
		var pop_after: float = _avg(vid, "pop", END_DAY, END_DAY)
		var starved_before: float = _avg(vid, "starved", SHOCK_DAY - 1, SHOCK_DAY - 1)
		_check("village %d: nobody starved and the village held" % vid,
			float(v.starved_deaths) <= starved_before and pop_after >= pop_before - 1.0,
			"%d -> %d people, starved %d" % [int(pop_before), int(pop_after), v.starved_deaths])

	func _finish() -> void:
		done = true
		var v1 = world.villages[0]
		var v2 = world.villages[1]
		_judge(v1, "bread", "bakery fire and the rats")
		_judge(v2, "wheat", "blight")
		var trips: int = v1.trade_stats.trips + v2.trade_stats.trips
		_check("a merchant carried goods between the villages", trips > 0,
			"%d sale(s), %d units, profit $%.1f" % [trips, v1.trade_stats.units + v2.trade_stats.units, v1.trade_stats.profit + v2.trade_stats.profit])
		var fails := 0
		for r in results:
			if not r.ok:
				fails += 1
		print("[SHOCKS] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	var probe := Probe.new()
	probe.name = "ShockProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
