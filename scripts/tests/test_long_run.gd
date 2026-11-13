extends Node
## Long run (docs/BREAD_MARKET.md): plays the real game (Main.tscn) at 10x for a long time and
## checks that the towns hold. Works with dev mode, so any town and inputs can be run
## (--scenario=name, --set key=value after "--").
##
## Stops when every village is dead or full, or at --days, or at --max-seconds of real time.
## Fails (exit code 1) when, in any village:
##   - nobody is left at the end,
##   - someone starved to death holding enough coins for a loaf,
##   - the market's purse ran dry,
##   - the town went DAYS_WITHOUT days in a row with people but no farmer, or no baker,
## or when the books do not balance: across both towns, people's coins plus the markets' purses
## must change by exactly the coins newcomers brought minus the coins leavers took.
##
##   godot --headless --fixed-fps 5 --disable-vsync --path . res://scenes/TestLongRun.tscn --
##       [--days=1500] [--max-seconds=900] [--village-seeds=a,b] [--scenario=x] [--set k=v]
##       [--rows=file.jsonl] [--news=file.txt] [--result=file.json] [--no-ui]
##       [--wipe-day=N --wipe-village=V]
## --rows writes one line per village per day; --news the town news in plain words; --no-ui stops
## the on-screen panels redrawing (the town is untouched); --wipe-day removes every farmer and
## every hired hand of village V overnight on day N, to see whether the town recovers.
## At --fixed-fps 5 a 1,500-day run takes about two minutes.

const DEAD_HOLD := 30
const DAYS_WITHOUT := 30
const BOOKS_TOLERANCE := 1.0


class Probe extends Node:
	var max_days := 1500
	var max_seconds := 900
	var rows_path := ""
	var news_path := ""
	var result_path := ""
	var no_ui := false
	var past_full := false
	var wipe_day := -1
	var wipe_village := 1
	var rows_file: FileAccess = null
	var news_file: FileAccess = null
	var news_bytes := 0
	const NEWS_CAP := 30 * 1024 * 1024
	var started_ms := 0
	var last_day := {}
	var people := {}
	var st := {}
	var hooked := {}
	var done := false
	var ui_off := false
	var wiped := false
	var rows_written := 0
	# The books, across both towns.
	var books_start := -1.0
	var brought_start := 0.0
	var taken_start := 0.0
	var books_day := -1
	var books_worst := 0.0
	var books_worst_day := -1

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--days="): max_days = int(arg.substr(7))
			if arg.begins_with("--max-seconds="): max_seconds = int(arg.substr(14))
			if arg.begins_with("--rows="): rows_path = arg.substr(7)
			if arg.begins_with("--news="): news_path = arg.substr(7)
			if arg.begins_with("--result="): result_path = arg.substr(9)
			if arg == "--no-ui": no_ui = true
			if arg == "--past-full": past_full = true   # keep going after a town reaches its size limit
			if arg.begins_with("--wipe-day="): wipe_day = int(arg.substr(11))
			if arg.begins_with("--wipe-village="): wipe_village = int(arg.substr(15))
		if rows_path != "":
			rows_file = FileAccess.open(rows_path, FileAccess.WRITE)
		if news_path != "":
			news_file = FileAccess.open(news_path, FileAccess.WRITE)
		started_ms = Time.get_ticks_msec()

	func _process(_d: float) -> void:
		if done:
			return
		var main := get_tree().current_scene
		if main == null or main == self:
			return
		var world := main.get_node_or_null("World")
		if world == null or world.villages.is_empty():
			return
		if Tuning.has_start() and not world.get_meta("dev_start_done", false):
			return
		var clock = main.get("clock")
		if clock and clock.speed_multiplier < 10.0:
			clock.set_speed(10.0)
		if no_ui and not ui_off:
			ui_off = true
			var lp = main.get("_log_panel_ctrl")
			if lp != null:
				lp.set_process(false)
		for v in world.villages:
			if v != null and v.event_bus != null and not hooked.has(v.village_id):
				hooked[v.village_id] = true
				var vref = v
				v.event_bus.event_logged.connect(func(msg: String) -> void: _event(vref, msg))
		var max_day := 0
		var sampled := false
		for v in world.villages:
			if v == null or v.calendar == null:
				continue
			var day: int = v.calendar.day_index
			max_day = maxi(max_day, day)
			if last_day.get(v.village_id, -1) == day:
				continue
			last_day[v.village_id] = day
			if wipe_day >= 0 and not wiped and v.village_id == wipe_village and day >= wipe_day:
				_wipe(v, day)
			_sample(v, day)
			sampled = true
		if sampled:
			_check_books(world, max_day)
		var ended := 0
		for vid in st:
			if st[vid].dead_run >= DEAD_HOLD or (st[vid].full_day >= 0 and not past_full):
				ended += 1
		if st.size() >= world.villages.size() and ended >= st.size():
			_finish("every village is dead or full")
		elif max_day >= max_days:
			_finish("day %d reached" % max_days)
		elif Time.get_ticks_msec() - started_ms > max_seconds * 1000:
			_finish("time limit of %d s reached on day %d" % [max_seconds, max_day])

	## People's coins plus the markets' purses, across both towns, against what came and went.
	func _check_books(world: Node, day: int) -> void:
		var total := 0.0
		var brought := 0.0
		var taken := 0.0
		for v in world.villages:
			if v == null or v.market == null:
				continue
			total += v.market.money
			brought += v.coins_brought
			taken += v.coins_taken
			for group in (v.owner_groups() + [v.households]):
				for a in group:
					if a != null and is_instance_valid(a):
						total += a.get_cash()
		if books_start < 0.0:
			books_start = total
			brought_start = brought
			taken_start = taken
			return
		var err: float = (total - books_start) - ((brought - brought_start) - (taken - taken_start))
		if absf(err) > absf(books_worst):
			books_worst = err
			books_worst_day = day

	func _event(v, msg: String) -> void:
		var s = st.get(v.village_id)
		if s != null and msg.contains("[DEATH]") and msg.contains(" starved ("):
			# "[DEATH] day=12 Name starved ($4.2, market bread 0 at $3.10)"
			var coins: float = float(msg.get_slice("($", 1).get_slice(",", 0))
			var price: float = float(msg.get_slice(" at $", 1).get_slice(")", 0))
			if coins >= price:
				s.starved_with_coins += 1
		if news_file == null or news_bytes > NEWS_CAP:
			return
		var news: String = LogPanelController.news_line(msg)
		if news == "":
			return
		var line := "v%d d%d %s\n" % [v.village_id, v.calendar.day_index if v.calendar else -1, news]
		news_bytes += line.length()
		news_file.store_string(line)

	func _wipe(v, day: int) -> void:
		wiped = true
		var gone: Array = []
		for f in v.all_farmers.duplicate():
			if f != null and is_instance_valid(f):
				gone.append(f)
		for h in v.households.duplicate():
			if h != null and is_instance_valid(h) and h.has_meta("employer") and is_instance_valid(h.get_meta("employer")) \
					and not bool(h.get_meta("servant", false)):
				gone.append(h)
		for a in gone:
			v.labor_market.migrate_requested.emit(a, "staged wipe-out")
		print("[LONGRUN] WIPE village %d day %d: every farmer and hired hand removed (%d people)" % [v.village_id, day, gone.size()])
		if news_file != null:
			news_file.store_string("v%d d%d STAGED WIPE-OUT: %d removed\n" % [v.village_id, day, gone.size()])

	func _sample(v, day: int) -> void:
		var vid: int = v.village_id
		var s: Dictionary = st.get(vid, {"dead_run": 0, "full_day": -1, "peak_pop": 0, "peak_day": 0, "start_pop": -1, "end_pop": 0,
			"left": 0, "starved_with_coins": 0, "purse_min": INF, "no_farmer_run": 0, "no_baker_run": 0, "worst_no_farmer": 0,
			"worst_no_baker": 0, "bread_min": INF, "bread_max": 0.0, "reached": {}})
		var m = v.market
		var roles := {"Farmer": 0, "Baker": 0, "Household": 0, "Woodworker": 0, "Smith": 0, "Tailor": 0, "Merchant": 0}
		var rags := 0
		var cash: Array = []
		var starving := 0
		var cold := 0
		var cottagers := 0
		var now := {}
		for group in (v.owner_groups() + [v.households]):
			for a in group:
				if a == null or not is_instance_valid(a):
					continue
				now[a.get_instance_id()] = true
				roles[a.current_role] = int(roles.get(a.current_role, 0)) + 1
				cash.append(a.get_cash())
				if a.hunger and a.hunger.is_starving:
					starving += 1
				if int(a.get_meta("cold_days", 0)) > 0:
					cold += 1
				if bool(a.get_meta("cottager", false)):
					cottagers += 1
				if not Clothing.dressed(a):
					rags += 1
		var prev: Dictionary = people.get(vid, {})
		for k in prev:
			if not now.has(k):
				s.left += 1
		people[vid] = now
		cash.sort()
		var n: int = cash.size()
		var pockets := 0.0
		for c in cash:
			pockets += c
		if s.start_pop < 0:
			s.start_pop = n
		s.end_pop = n
		if n > s.peak_pop:
			s.peak_pop = n
			s.peak_day = day
		for size in [10, 15, 20, 25, 30, 40, 50]:
			if n >= size and not s.reached.has(size):
				s.reached[size] = day
		s.dead_run = s.dead_run + 1 if n == 0 else 0
		if n >= int(v.MAX_TOTAL_POP) and s.full_day < 0:
			s.full_day = day
		s.purse_min = minf(s.purse_min, m.money)
		s.bread_min = minf(s.bread_min, m.bread_price)
		s.bread_max = maxf(s.bread_max, m.bread_price)
		if n > 0 and day >= 10:
			s.no_farmer_run = s.no_farmer_run + 1 if roles.Farmer == 0 else 0
			s.no_baker_run = s.no_baker_run + 1 if roles.Baker == 0 else 0
			s.worst_no_farmer = maxi(s.worst_no_farmer, s.no_farmer_run)
			s.worst_no_baker = maxi(s.worst_no_baker, s.no_baker_run)
		st[vid] = s
		if rows_file == null:
			return
		var hs: Dictionary = v.housing.summary() if v.housing else {"houses": 0, "empty": 0}
		var row := {"v": vid, "day": day, "pop": n, "F": roles.Farmer, "B": roles.Baker, "W": roles.Woodworker, "S": roles.Smith, "T": roles.Tailor, "H": roles.Household, "rags": rags,
			"cp": snappedf(m.good_price("clothes"), 0.01) if m.has_good("clothes") else 0.0, "mc": m.good_stock("clothes") if m.has_good("clothes") else 0,
			"cbought": v.clothing.stats.bought if v.clothing else 0, "csewn": v.clothing.stats.sewn if v.clothing else 0,
			"tp": snappedf(m.good_price("tools"), 0.01) if m.has_good("tools") else 0.0, "mt": m.good_stock("tools") if m.has_good("tools") else 0,
			"hands": 0, "servants": v.housing.servant_count() if v.housing else 0, "cott": cottagers,
			"idle": v.labor_market.idle_count if v.labor_market else 0,
			"wp": snappedf(m.wheat_price, 0.01), "bp": snappedf(m.bread_price, 0.01), "fp": snappedf(m.firewood_price, 0.01),
			"mw": m.wheat, "wt": m.wheat_target, "mb": m.bread, "bt": m.bread_target, "mf": m.firewood,
			"mm": snappedf(m.money, 0.1), "pm": snappedf(pockets, 0.1),
			"cmin": snappedf(cash[0], 0.1) if n else 0.0, "cmed": snappedf(cash[n / 2], 0.1) if n else 0.0, "cmax": snappedf(cash[n - 1], 0.1) if n else 0.0,
			"starving": starving, "cold": cold, "left": s.left, "starved": v.starved_deaths,
			"houses": hs.houses, "empty": hs.empty, "tot": m.totals.duplicate(),
			"pros": snappedf(v.prosperity_meter.prosperity_score, 0.01) if v.prosperity_meter else -1.0,
			"brought": snappedf(v.coins_brought, 0.1), "taken": snappedf(v.coins_taken, 0.1)}
		for group in v.owner_groups():
			for a in group:
				if a != null and is_instance_valid(a):
					row.hands += LaborMarket.hands_of(a)
		rows_file.store_string(JSON.stringify(row) + "\n")
		rows_written += 1
		if rows_written % 40 == 0:
			rows_file.flush()
			if news_file != null:
				news_file.flush()

	func _finish(reason: String) -> void:
		done = true
		var day_s: float = Tuning.f("day_seconds", SimulationClock.TICK_SECONDS * 10.0)
		print("[LONGRUN] END %s (%d s)" % [reason, int((Time.get_ticks_msec() - started_ms) / 1000)])
		var results: Array = []
		for vid in st:
			var s: Dictionary = st[vid]
			var times: Array = []
			for size in s.reached:
				times.append("%d people in %.0f min" % [size, float(s.reached[size]) * day_s / 60.0])
			print("[LONGRUN] village %d: %d -> %d people (peak %d on day %d), %d left or died, bread %.2f..%.2f, purse low %.0f, longest without a farmer %d days, without a baker %d. At normal speed: %s" % [
				vid, s.start_pop, s.end_pop, s.peak_pop, s.peak_day, s.left, s.bread_min, s.bread_max, s.purse_min,
				s.worst_no_farmer, s.worst_no_baker, ", ".join(times)])
			results.append(["village %d still has people" % vid, s.end_pop > 0, "%d at the end" % s.end_pop])
			results.append(["village %d: nobody starved holding coins for a loaf" % vid, s.starved_with_coins == 0, "%d did" % s.starved_with_coins])
			results.append(["village %d: the market's purse never ran dry" % vid, s.purse_min > 1.0, "lowest %.1f" % s.purse_min])
			results.append(["village %d: never %d days without a farmer" % [vid, DAYS_WITHOUT], s.worst_no_farmer < DAYS_WITHOUT, "longest %d" % s.worst_no_farmer])
			results.append(["village %d: never %d days without a baker" % [vid, DAYS_WITHOUT], s.worst_no_baker < DAYS_WITHOUT, "longest %d" % s.worst_no_baker])
		results.append(["the books balance: coins only came with newcomers and went with leavers", absf(books_worst) <= BOOKS_TOLERANCE,
			"worst gap %.2f coins on day %d" % [books_worst, books_worst_day]])
		var fails := 0
		var out: Array = []
		for r in results:
			if not r[1]:
				fails += 1
			out.append({"check": r[0], "ok": r[1], "detail": r[2]})
			print("[LONGRUN] %s %s (%s)" % ["PASS" if r[1] else "FAIL", r[0], r[2]])
		print("[LONGRUN] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		if rows_file != null:
			rows_file.close()
		if news_file != null:
			news_file.close()
		if result_path != "":
			var f := FileAccess.open(result_path, FileAccess.WRITE)
			if f:
				f.store_string(JSON.stringify({"reason": reason, "checks": out, "stats": st, "books_worst": books_worst}, " "))
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	var probe := Probe.new()
	probe.name = "LongRunProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
