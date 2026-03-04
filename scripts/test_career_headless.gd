extends Node

## Headless test runner for career switching validation.
## Loads the full Main.tscn, fast-forwards 36 game days, then validates
## that [CAREER EVAL], [CAREER DECISION], and [CAREER BLOCKED] logs
## appear with the expected format and cadence.
##
## Run:  godot --headless --path <project_dir> res://scenes/TestCareer.tscn
## Or open scenes/TestCareer.tscn from the editor and press F6.

var _main: Node = null
var _log: Array[String] = []
var _tick: int = 0
var _frame: int = 0
var _initialized: bool = false
var _done: bool = false
var _all_passed: bool = true
var _last_day_logged: int = -1

const TARGET_DAY: int = 36
const TICKS_PER_DAY: int = 10
# In normal gameplay ~60 physics frames elapse per tick (agents move/trade).
# We give each tick this many physics frames to keep the economy functional.
const FRAMES_PER_TICK: int = 6


func _ready() -> void:
	print("[TEST] ══════════════════════════════════════════════════════")
	print("[TEST] Career Switching Headless Validator")
	print("[TEST] Target: %d days (%d ticks)" % [TARGET_DAY, TARGET_DAY * TICKS_PER_DAY])
	print("[TEST] ══════════════════════════════════════════════════════")
	print("[TEST] Loading Main.tscn...")
	var scene = load("res://scenes/Main.tscn")
	if scene == null:
		print("[TEST] FATAL: Could not load Main.tscn")
		get_tree().quit(1)
		return
	_main = scene.instantiate()
	add_child(_main)
	print("[TEST] Main scene loaded.")


func _physics_process(_delta: float) -> void:
	if _done or _main == null:
		return

	if not _initialized:
		_initialize_test()
		_initialized = true
		return

	_frame += 1

	# Only pump a new tick every FRAMES_PER_TICK physics frames, so agents
	# get multiple movement/state updates between ticks (like normal gameplay).
	if _frame % FRAMES_PER_TICK != 0:
		return

	_tick += 1
	_main.clock.tick = _tick
	_main._on_tick(_tick)

	var day: int = _tick / TICKS_PER_DAY
	if day % 7 == 0 and day != _last_day_logged:
		_last_day_logged = day
		var pop_count: int = _main.pop_mgr.count() if _main.pop_mgr else 0
		print("[TEST] ... day %d | pop=%d | %d log lines" % [day, pop_count, _log.size()])

	# Stop if sim failed (town extinct) or target reached
	var sim_failed: bool = _main.get("sim_failed") == true
	if sim_failed:
		print("[TEST] Simulation failed at day %d (town extinct). Validating partial run..." % day)
		_validate()
		_done = true
		get_tree().quit(0 if _all_passed else 1)
		return

	if day >= TARGET_DAY:
		_validate()
		_done = true
		get_tree().quit(0 if _all_passed else 1)


func _initialize_test() -> void:
	if _main.clock and _main.clock.timer:
		_main.clock.timer.stop()
	# Capture any log lines emitted during _ready() (e.g. [BOOTSTRAP])
	if _main.log_buffer and _main.log_buffer.size() > 0:
		for line in _main.log_buffer:
			_log.append(line)
	if _main.bus:
		_main.bus.event_logged.connect(_on_log)
	# Speed up physics for faster test execution
	Engine.physics_ticks_per_second = 240
	print("[TEST] Clock stopped. EventBus hooked. Physics=%d/s. Running..." % Engine.physics_ticks_per_second)


func _on_log(msg: String) -> void:
	_log.append(msg)


# ─── Validation ──────────────────────────────────────────────────────────────

func _validate() -> void:
	var final_day: int = _tick / TICKS_PER_DAY
	print("")
	print("═".repeat(60))
	print(" VALIDATION RESULTS  (day %d, %d ticks, %d log lines)" % [
		final_day, _tick, _log.size()])
	print("═".repeat(60))

	_check_bootstrap_log()
	_check_bootstrap_inventory()
	_check_career_eval_cadence(final_day)
	_check_career_decision_utility()
	_check_no_scarcity_selector()
	_check_career_blocked()
	_check_career_summary(final_day)
	_check_evals_count_matches()
	_check_no_mass_churn()
	_check_log_format_fields()
	_check_no_bad_pop_names()
	_check_eval_summary_on_eval_days(final_day)
	_check_econ_snap_daily(final_day)
	_check_trade_activity(final_day)

	print("")
	print("═".repeat(60))
	print(" OVERALL: %s" % ("PASS" if _all_passed else "FAIL"))
	print("═".repeat(60))


func _check_bootstrap_log() -> void:
	print("\n── Check 0a: [BOOTSTRAP] Seeded market appears exactly once ──")
	var count: int = 0
	for line in _log:
		if "[BOOTSTRAP] Seeded market:" in line:
			count += 1
			print("  %s" % line)
	if count == 1:
		print("  RESULT: PASS (exactly 1 bootstrap line)")
	else:
		print("  RESULT: FAIL (found %d, expected 1)" % count)
		_all_passed = false


func _check_bootstrap_inventory() -> void:
	print("\n── Check 0b: Market was seeded and day-1 inventory not both zero ──")
	if _main == null or _main.market == null:
		print("  RESULT: FAIL (no market reference)")
		_all_passed = false
		return
	var seeded: bool = _main.market.market_seeded
	print("  market_seeded flag: %s" % seeded)
	if not seeded:
		print("  RESULT: FAIL (market_seeded is false)")
		_all_passed = false
		return
	var day1_ok: bool = false
	for line in _log:
		if "[ECON SNAP]" in line and "day=1" in line:
			var w_idx: int = line.find("wheat=")
			var b_idx: int = line.find("bread=")
			if w_idx != -1 and b_idx != -1:
				var w_val: int = _extract_int(line, "wheat=")
				var b_val: int = _extract_int(line, "bread=")
				print("  Day 1 ECON SNAP: wheat=%d bread=%d" % [w_val, b_val])
				day1_ok = not (w_val == 0 and b_val == 0)
			break
	if day1_ok:
		print("  RESULT: PASS")
	else:
		var m_wheat: int = _main.market.wheat
		var m_bread: int = _main.market.bread
		var final_day: int = _tick / TICKS_PER_DAY
		print("  No day-1 snap found; current day %d: wheat=%d bread=%d" % [final_day, m_wheat, m_bread])
		if m_wheat > 0 or m_bread > 0:
			print("  RESULT: PASS (inventory nonzero at end)")
		else:
			print("  RESULT: FAIL (both zero)")
			_all_passed = false


func _check_career_eval_cadence(final_day: int) -> void:
	print("\n── Check 1: [CAREER EVAL] appears every 7 days for ALL agents ──")
	var eval_days: Dictionary = {}   # day -> count
	var agents_by_day: Dictionary = {} # day -> {pop_id: true}
	for line in _log:
		if "[CAREER EVAL]" not in line:
			continue
		var d: int = _extract_int(line, "day=")
		var pop: String = _extract_field(line, "pop=")
		if not eval_days.has(d):
			eval_days[d] = 0
			agents_by_day[d] = {}
		eval_days[d] += 1
		agents_by_day[d][pop] = true

	# day_changed never fires for day 0 (calendar starts at 0), so first eval is day 7
	var expected_days: Array[int] = []
	var d: int = 7
	while d <= final_day:
		expected_days.append(d)
		d += 7

	var pass_count: int = 0
	for ed in expected_days:
		var count: int = eval_days.get(ed, 0)
		var agents: int = agents_by_day.get(ed, {}).size()
		if count > 0:
			print("  Day %2d: %d evals (%d agents) PASS" % [ed, count, agents])
			pass_count += 1
		else:
			print("  Day %2d: MISSING - FAIL" % ed)
			_all_passed = false

	var total_evals: int = 0
	for day_key in eval_days:
		total_evals += eval_days[day_key]
	print("  Total [CAREER EVAL] lines: %d" % total_evals)

	# At least day-0 and day-7 must appear for a meaningful test
	var min_required: int = mini(2, expected_days.size())
	if pass_count >= min_required:
		print("  RESULT: PASS (%d/%d reachable days)" % [pass_count, expected_days.size()])
	else:
		print("  RESULT: FAIL (%d/%d reachable days, need >=%d)" % [
			pass_count, expected_days.size(), min_required])


func _check_career_decision_utility() -> void:
	print("\n── Check 2: [CAREER DECISION] reason=utility ──")
	var total: int = 0
	var utility_count: int = 0
	var non_utility: Array[String] = []
	for line in _log:
		if "[CAREER DECISION]" not in line:
			continue
		total += 1
		if "reason=utility" in line:
			utility_count += 1
			print("  %s" % line)
		else:
			non_utility.append(line)

	if non_utility.size() > 0:
		print("  NON-UTILITY decisions:")
		for line in non_utility:
			print("    %s" % line)
		_all_passed = false

	if total == 0:
		print("  No switches occurred (economy may not warrant any)")
		print("  RESULT: INFO")
	elif utility_count == total:
		print("  RESULT: PASS (%d/%d are reason=utility)" % [utility_count, total])
	else:
		print("  RESULT: FAIL (%d/%d non-utility)" % [total - utility_count, total])


func _check_no_scarcity_selector() -> void:
	print("\n── Check 3: No scarcity-as-selector switching ──")
	var suspect_lines: Array[String] = []
	for line in _log:
		if "[CAREER" in line or "[LaborMkt]" in line or "[SPAWN" in line:
			continue
		var lower: String = line.to_lower()
		if ("bread_scar" in lower or "wheat_scar" in lower) and "switch" in lower:
			suspect_lines.append(line)

	if suspect_lines.is_empty():
		print("  RESULT: PASS (no scarcity-driven switch lines found)")
	else:
		print("  RESULT: WARN (%d suspect lines)" % suspect_lines.size())
		for line in suspect_lines:
			print("    %s" % line)


func _check_career_blocked() -> void:
	print("\n── Check 4: [CAREER BLOCKED] logs ──")
	var total: int = 0
	var reasons: Dictionary = {}
	for line in _log:
		if "[CAREER BLOCKED]" not in line:
			continue
		total += 1
		var reason: String = _extract_field(line, "block=")
		reasons[reason] = reasons.get(reason, 0) + 1

	print("  Total blocked: %d" % total)
	for reason in reasons:
		print("    %-15s %d" % [reason, reasons[reason]])

	# Verify format has required fields
	var format_ok: bool = true
	for line in _log:
		if "[CAREER BLOCKED]" not in line:
			continue
		if "Uc=" not in line or "Ub=" not in line or "current=" not in line:
			print("  BAD FORMAT: %s" % line)
			format_ok = false
			_all_passed = false
		break

	print("  Format: %s" % ("OK" if format_ok else "FAIL"))
	print("  RESULT: INFO")


func _check_career_summary(final_day: int) -> void:
	print("\n── Check 5: [CAREER SUMMARY] daily logs ──")
	var count: int = 0
	for line in _log:
		if "[CAREER SUMMARY]" in line:
			count += 1

	print("  Total summaries: %d (expected ~%d)" % [count, final_day])
	if count >= final_day - 1:
		print("  RESULT: PASS")
	else:
		print("  RESULT: WARN (fewer than expected)")


func _check_no_mass_churn() -> void:
	print("\n── Check 6: No mass churn ──")
	var switches_per_day: Dictionary = {}
	for line in _log:
		if "[CAREER SUMMARY]" not in line:
			continue
		var d: int = _extract_int(line, "day=")
		var s: int = _extract_int(line, "switches=")
		switches_per_day[d] = s

	var max_sw: int = 0
	var max_day: int = 0
	var total_sw: int = 0
	for d in switches_per_day:
		total_sw += switches_per_day[d]
		if switches_per_day[d] > max_sw:
			max_sw = switches_per_day[d]
			max_day = d

	print("  Total switches across all days: %d" % total_sw)
	print("  Max switches on a single day: %d (day %d)" % [max_sw, max_day])
	if max_sw <= 2:
		print("  RESULT: PASS")
	else:
		print("  RESULT: WARN (high churn on day %d)" % max_day)
		_all_passed = false


func _check_log_format_fields() -> void:
	print("\n── Check 7: Log format correctness ──")
	var eval_ok: bool = true
	var decision_ok: bool = true
	var checked_eval: int = 0
	var checked_decision: int = 0

	for line in _log:
		if "[CAREER EVAL]" in line:
			checked_eval += 1
			if checked_eval > 3:
				continue
			for field in ["day=", "pop=", "role=", "cash=", "food=", "skill(F=",
						  "profit(F=", "income(F=", "U(F=", "best=", "allowed=", "block="]:
				if field not in line:
					print("  EVAL missing '%s': %s" % [field, line])
					eval_ok = false
					_all_passed = false
					break

		if "[CAREER DECISION]" in line:
			checked_decision += 1
			for field in ["day=", "pop=", "from=", "to=", "reason=utility",
						  "Uc=", "Ub=", "delta=", "ratio=", "cash=", "food="]:
				if field not in line:
					print("  DECISION missing '%s': %s" % [field, line])
					decision_ok = false
					_all_passed = false
					break

	print("  [CAREER EVAL] format: %s (checked %d)" % [
		"PASS" if eval_ok else "FAIL", mini(checked_eval, 3)])
	print("  [CAREER DECISION] format: %s (checked %d)" % [
		"PASS" if decision_ok else "FAIL", checked_decision])


func _check_evals_count_matches() -> void:
	print("\n── Check 8: [CAREER SUMMARY] evals matches [CAREER EVAL] count per day ──")
	var eval_counts: Dictionary = {}
	var summary_evals: Dictionary = {}
	for line in _log:
		if "[CAREER EVAL]" in line:
			var d: int = _extract_int(line, "day=")
			eval_counts[d] = eval_counts.get(d, 0) + 1
		if "[CAREER SUMMARY]" in line:
			var d: int = _extract_int(line, "day=")
			var e: int = _extract_int(line, "evals=")
			summary_evals[d] = e

	var mismatches: int = 0
	for d in summary_evals:
		var expected: int = eval_counts.get(d, 0)
		var actual: int = summary_evals[d]
		if actual != expected:
			print("  Day %d: summary evals=%d but [CAREER EVAL] lines=%d MISMATCH" % [d, actual, expected])
			mismatches += 1

	if mismatches == 0:
		print("  RESULT: PASS (all days match)")
	else:
		print("  RESULT: FAIL (%d mismatches)" % mismatches)
		_all_passed = false


func _check_no_bad_pop_names() -> void:
	print("\n── Check 9: No @CharacterBody2D@ pop names in logs ──")
	var bad_lines: Array[String] = []
	for line in _log:
		if "CharacterBody2D@" in line and "[NAME FIXUP]" not in line:
			bad_lines.append(line)

	if bad_lines.is_empty():
		print("  RESULT: PASS (no unresolved auto-generated names)")
	else:
		print("  RESULT: FAIL (%d bad name references)" % bad_lines.size())
		for line in bad_lines:
			print("    %s" % line)
		_all_passed = false


func _check_eval_summary_on_eval_days(final_day: int) -> void:
	print("\n── Check 10: [CAREER EVAL SUMMARY] on 7-day cadence ──")
	var summary_days: Dictionary = {}
	for line in _log:
		if "[CAREER EVAL SUMMARY]" not in line:
			continue
		var d: int = _extract_int(line, "day=")
		summary_days[d] = line

	var expected_days: Array[int] = []
	var dd: int = 7
	while dd <= final_day:
		expected_days.append(dd)
		dd += 7

	var pass_count: int = 0
	for ed in expected_days:
		if summary_days.has(ed):
			print("  Day %2d: PASS" % ed)
			pass_count += 1
		else:
			print("  Day %2d: MISSING - FAIL" % ed)
			_all_passed = false

	var format_ok: bool = true
	for day_key in summary_days:
		var line: String = summary_days[day_key]
		for field in ["evals=", "best(F=", "allowed(F=", "blocked_best(F=", "blocked_reasons(land=", "quota=", "entries(F=", "blocked_quota(F="]:
			if field not in line:
				print("  BAD FORMAT missing '%s': %s" % [field, line])
				format_ok = false
				_all_passed = false
				break

	if expected_days.is_empty():
		print("  RESULT: SKIP (no eval days reached)")
	elif pass_count >= expected_days.size():
		print("  RESULT: PASS (%d/%d, format=%s)" % [pass_count, expected_days.size(), "OK" if format_ok else "FAIL"])
	else:
		print("  RESULT: FAIL (%d/%d)" % [pass_count, expected_days.size()])


func _check_econ_snap_daily(final_day: int) -> void:
	print("\n── Check 11: [ECON SNAP] daily ──")
	var snap_days: Dictionary = {}
	for line in _log:
		if "[ECON SNAP]" not in line:
			continue
		var d: int = _extract_int(line, "day=")
		snap_days[d] = true

	var expected: int = final_day
	var found: int = snap_days.size()
	print("  Found %d [ECON SNAP] lines (expected ~%d)" % [found, expected])

	var format_ok: bool = true
	for line in _log:
		if "[ECON SNAP]" not in line:
			continue
		for field in ["pop=", "fields=", "inv(wheat=", "scar(w=", "profit(F="]:
			if field not in line:
				print("  BAD FORMAT missing '%s': %s" % [field, line])
				format_ok = false
				_all_passed = false
				break
		break

	if found >= expected - 1:
		print("  RESULT: PASS (format=%s)" % ("OK" if format_ok else "FAIL"))
	else:
		print("  RESULT: WARN (fewer than expected)")


func _check_trade_activity(final_day: int) -> void:
	print("\n── Check 12: [TRADE] activity ──")
	var status_count: int = 0
	var import_count: int = 0
	var export_count: int = 0
	var skip_count: int = 0
	for line in _log:
		if "[TRADE STATUS]" in line:
			status_count += 1
		elif "[TRADE IMPORT]" in line:
			import_count += 1
		elif "[TRADE EXPORT]" in line:
			export_count += 1
		elif "[TRADE SKIP]" in line:
			skip_count += 1

	print("  [TRADE STATUS] lines: %d" % status_count)
	print("  [TRADE IMPORT] lines: %d" % import_count)
	print("  [TRADE EXPORT] lines: %d" % export_count)
	print("  [TRADE SKIP] lines: %d" % skip_count)

	# Validate format of first TRADE STATUS
	var format_ok: bool = true
	for line in _log:
		if "[TRADE STATUS]" not in line:
			continue
		for field in ["day=", "imports(wheat=", "exports(wheat=", "cap_rem(wheat_i="]:
			if field not in line:
				print("  BAD FORMAT missing '%s': %s" % [field, line])
				format_ok = false
				_all_passed = false
				break
		break

	if status_count > 0:
		print("  Format: %s" % ("OK" if format_ok else "FAIL"))
	if status_count > 0 or import_count > 0:
		print("  RESULT: PASS (trade system active)")
	else:
		print("  RESULT: WARN (no trade activity — may be OK if RNG skipped or inv never hit threshold)")


# ─── Helpers ─────────────────────────────────────────────────────────────────

func _extract_field(line: String, field: String) -> String:
	var idx: int = line.find(field)
	if idx == -1:
		return ""
	var start: int = idx + field.length()
	var end: int = start
	while end < line.length() and line[end] != " " and line[end] != "\n":
		end += 1
	return line.substr(start, end - start)


func _extract_int(line: String, field: String) -> int:
	var val: String = _extract_field(line, field)
	if val == "":
		return -1
	return int(val)
