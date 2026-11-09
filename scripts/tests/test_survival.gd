extends Node
## Survival test (docs/ECONOMY_BATCH1.md): runs the real game (Main.tscn) at 10x speed with
## 240 physics ticks a second, so agents walk and trade as in play (the old fast-forward
## harness broke travel), and samples both villages once per game day.
##
## It fails when, after the first 10 days, a village:
##   - dies out, or
##   - has no farmer or no baker for 5 days in a row, or
##   - has someone starving on more than 5% of days while its market still had bread.
## Money is summed every day (people + market) and reported; it is not yet a check, because
## births still bring new money (batch 2).
##
##   godot --headless --path . res://scenes/TestSurvival.tscn -- [--days=120]
##       [--labor-mode=switching|wages] [--village-seeds=12345,66666] [--result=path.json]

const GRACE_DAYS := 10
const NO_ROLE_DAYS := 5
const STARVE_WITH_FOOD_SHARE := 0.05


class Probe extends Node:
	var days := 120
	var result_path := ""
	var started_ms := 0
	var last_day := {}
	var people := {}            # village id -> {instance id: role}
	var log_rows := []
	var stats := {}             # village id -> counters
	var done := false
	var trade := false

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--days="): days = int(arg.substr(7))
			if arg.begins_with("--result="): result_path = arg.substr(9)
			if arg == "--trade": trade = true
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
		if world == null:
			return
		if trade and not world.trade_enabled:
			world.trade_enabled = true
			print("[SURVIVAL] trade on")
		var finished := 0
		for v in world.villages:
			if v == null or v.calendar == null:
				continue
			var day: int = v.calendar.day_index
			if day >= days:
				finished += 1
				continue
			if last_day.get(v.village_id, -1) == day:
				continue
			last_day[v.village_id] = day
			_sample(v, day)
		if finished >= world.villages.size() and world.villages.size() > 0:
			_finish()
		elif Time.get_ticks_msec() - started_ms > (days * 8 + 120) * 1000:
			print("[SURVIVAL] timed out")
			_finish()

	func _sample(v, day: int) -> void:
		var vid: int = v.village_id
		var s: Dictionary = stats.get(vid, {"no_farmer_run": 0, "no_baker_run": 0, "worst_no_farmer": 0, "worst_no_baker": 0,
			"starve_with_food_days": 0, "days": 0, "switches": 0, "left": 0, "extinct_day": -1, "first_money": -1.0})
		var m = v.market
		var roles := {"Farmer": 0, "Baker": 0, "Household": 0}
		var cash: Array = []
		var starving := 0
		var hands := 0
		var now := {}
		for group in [v.all_farmers, v.all_bakers, v.households]:
			for a in group:
				if a == null or not is_instance_valid(a):
					continue
				now[a.get_instance_id()] = a.current_role
				roles[a.current_role] = int(roles.get(a.current_role, 0)) + 1
				cash.append(a.get_cash())
				if a.hunger and a.hunger.is_starving:
					starving += 1
				hands += LaborMarket.hands_of(a)
		var prev: Dictionary = people.get(vid, {})
		for k in prev:
			if not now.has(k):
				s.left += 1
			elif now[k] != prev[k] and prev[k] != "Household":
				s.switches += 1     # a farmer or baker who changed trade
		people[vid] = now
		cash.sort()
		var people_money := 0.0
		for c in cash: people_money += c
		var total_money: float = people_money + m.money
		if s.first_money < 0.0: s.first_money = total_money
		if day >= GRACE_DAYS:
			s.days += 1
			s.no_farmer_run = s.no_farmer_run + 1 if roles.Farmer == 0 else 0
			s.no_baker_run = s.no_baker_run + 1 if roles.Baker == 0 else 0
			s.worst_no_farmer = maxi(s.worst_no_farmer, s.no_farmer_run)
			s.worst_no_baker = maxi(s.worst_no_baker, s.no_baker_run)
			if starving > 0 and m.bread > 0:
				s.starve_with_food_days += 1
		if cash.is_empty() and s.extinct_day < 0:
			s.extinct_day = day
		stats[vid] = s
		var n := cash.size()
		var row := {"v": vid, "day": day, "pop": n, "farmers": roles.Farmer, "bakers": roles.Baker, "households": roles.Household,
			"hands": hands, "wheat_p": snappedf(m.wheat_price, 0.01), "bread_p": snappedf(m.bread_price, 0.01),
			"m_wheat": m.wheat, "m_bread": m.bread, "m_money": snappedf(m.money, 0.1), "people_money": snappedf(people_money, 0.1),
			"cash_min": snappedf(cash[0], 0.1) if n else 0.0, "cash_med": snappedf(cash[n / 2], 0.1) if n else 0.0,
			"starving": starving, "switches": s.switches, "left": s.left}
		log_rows.append(row)
		print("[SURVIVAL] " + JSON.stringify(row))

	func _finish() -> void:
		done = true
		var checks := 0
		var failures := 0
		var results := []
		for vid in stats:
			var s: Dictionary = stats[vid]
			var lines := [
				["village %d did not die out" % vid, s.extinct_day < 0, "extinct on day %d" % s.extinct_day],
				["village %d never without a farmer for %d days" % [vid, NO_ROLE_DAYS], s.worst_no_farmer < NO_ROLE_DAYS, "longest %d days" % s.worst_no_farmer],
				["village %d never without a baker for %d days" % [vid, NO_ROLE_DAYS], s.worst_no_baker < NO_ROLE_DAYS, "longest %d days" % s.worst_no_baker],
				["village %d starving with bread in the market on at most %d%% of days" % [vid, int(STARVE_WITH_FOOD_SHARE * 100)],
					float(s.starve_with_food_days) <= STARVE_WITH_FOOD_SHARE * maxf(1.0, float(s.days)), "%d of %d days" % [s.starve_with_food_days, s.days]],
			]
			for l in lines:
				checks += 1
				if not l[1]: failures += 1
				results.append({"check": l[0], "ok": l[1], "detail": l[2]})
				print("[SURVIVAL] %s %s (%s)" % ["PASS" if l[1] else "FAIL", l[0], l[2]])
		print("[SURVIVAL] COMPLETE checks=%d failures=%d" % [checks, failures])
		if result_path != "":
			var f := FileAccess.open(result_path, FileAccess.WRITE)
			if f:
				f.store_string(JSON.stringify({"checks": checks, "failures": failures, "results": results, "stats": stats, "days": log_rows}, " "))
		get_tree().quit(0 if failures == 0 else 1)


func _ready() -> void:
	# Real travel at 10x needs enough physics steps per second of game time.
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	var probe := Probe.new()
	probe.name = "SurvivalProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
