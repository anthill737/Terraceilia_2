extends Node
class_name LaborMarket

## LaborMarket: utility-based occupational mobility and migration.
## Signals main.gd when agents should switch roles or leave the simulation.
## Operates on day_changed cadence - called once per game day from main.gd.
## Switching decisions use per-pop expected-utility scores from CareerEvaluator.

# ─── Signals ────────────────────────────────────────────────────────────────
signal migrate_requested(agent: Node, reason: String)
signal role_switch_requested(household: Node, new_role: String)

# ─── EMA constants (diagnostics + spawn suppression) ────────────────────────
const EMA_ALPHA: float = 0.2

# ─── Training / cooldown constants ──────────────────────────────────────────
const FARMER_TRAINING_DAYS: int = 2
const BAKER_TRAINING_DAYS: int = 3
const SWITCH_COOLDOWN_DAYS: int = 14

# ─── Utility-based switching gates ─────────────────────────────────────────
const MIN_TENURE_DAYS: int = 14
const EVAL_INTERVAL_DAYS: int = 7
const IMPROVEMENT_MARGIN: float = 0.15
const RECENT_SWITCH_MARGIN: float = 0.25
const RECENT_SWITCH_WINDOW_DAYS: int = 30
const SAVINGS_BUFFER_REQUIRED: float = 200.0
const FOOD_BUFFER_FRACTION: float = 2.0 / 3.0

# ─── Migration constants ──────────────────────────────────────────────────────
const MIGRATION_NO_FOOD_DAYS: int = 4      # Consecutive days without food → migrate
const MIGRATION_NEG_PROFIT_DAYS: int = 8  # Consecutive days negative cashflow → migrate
const MIGRATION_SURVIVAL_DAYS: int = 5    # Days in survival mode → migrate

# ─── Startup grace period ─────────────────────────────────────────────────────
## Days at sim start during which household migration is suppressed.
## Matches SimulationRunner.STARTUP_GRACE_DAYS — keep in sync if tuning.
const STARTUP_GRACE_DAYS: int = 5

# ─── Spawn suppression ────────────────────────────────────────────────────────
const SPAWN_SUPPRESS_SCARCITY: float = 0.5  # Suppress new household spawn above this

# ─── EMA state ──────────────────────────────────────────────────────────────
var farmer_profit_ema: float = 0.0
var baker_profit_ema: float = 0.0
var bread_scarcity_ema: float = 0.0
var wheat_scarcity_ema: float = 0.0

# ─── Prev-day money snapshots (for daily profit delta) ──────────────────────
var farmer_prev_money: Dictionary = {}  # agent → float
var baker_prev_money: Dictionary = {}   # agent → float

# ─── Shared array references (assigned by main.gd after init) ───────────────
## These must be set to the SAME array objects as main.gd uses so additions
## are automatically visible here.
var all_farmers: Array = []
var all_bakers: Array = []
var all_households: Array = []

# ─── Dependencies ────────────────────────────────────────────────────────────
var market = null
var event_bus = null
var econ_stats = null
var field_count_ref: Array = []
var max_fields: int = 10

var _initialized: bool = false

# ─── Career instrumentation counters (reset daily) ──────────────────────────
var switches_today: int = 0
var blocked_today: int = 0
var evals_today: int = 0
var reason_utility_today: int = 0
var reason_scarcity_today: int = 0

# ── Startup bootstrap tracking ────────────────────────────────────────────────
## Set to true the first time the market holds any bread inventory.
## Migration is suppressed until this is true AND the startup grace period expires.
## See SimulationRunner.STARTUP_GRACE_DAYS for the grace window.
var ever_had_bread_supply: bool = false

# ─── Per-eval-day diagnostic aggregation (reset each eval day) ───────────────
var _eval_diag: Dictionary = {}


## Call after instantiation to wire market and event bus.
func bind(p_market, p_event_bus) -> void:
	market = p_market
	event_bus = p_event_bus
	_initialized = true


# ─── Main daily update ────────────────────────────────────────────────────────

## Called once per game day (from main._on_calendar_day_changed).
func update_daily(day: int) -> void:
	if not _initialized:
		return

	switches_today = 0
	blocked_today = 0
	evals_today = 0
	reason_utility_today = 0
	reason_scarcity_today = 0

	# Update profit EMAs from daily money deltas
	var farmer_avg_delta: float = _compute_avg_delta(all_farmers, farmer_prev_money)
	var baker_avg_delta: float = _compute_avg_delta(all_bakers, baker_prev_money)
	farmer_profit_ema = _ema(farmer_profit_ema, farmer_avg_delta)
	baker_profit_ema = _ema(baker_profit_ema, baker_avg_delta)

	# Update scarcity EMAs (binary per day: 1.0 if stock empty, 0.0 otherwise)
	var bread_scarce: float = 1.0 if (market != null and market.bread <= 0) else 0.0
	var wheat_scarce: float = 1.0 if (market != null and market.wheat <= 0) else 0.0
	bread_scarcity_ema = _ema(bread_scarcity_ema, bread_scarce)
	wheat_scarcity_ema = _ema(wheat_scarcity_ema, wheat_scarce)

	# Daily macro-conditions snapshot for correlation with switching outcomes
	_emit_econ_snap(day)

	# Periodic diagnostic log (every 5 days)
	if event_bus and day % 5 == 0:
		event_bus.log("[LaborMkt] Day %d | f_profit=%.2f b_profit=%.2f bread_scar=%.2f wheat_scar=%.2f" % [
			day, farmer_profit_ema, baker_profit_ema, bread_scarcity_ema, wheat_scarcity_ema])

	# Track first-ever bread supply (checked before household evaluation each day).
	# market.on_day_changed fires before update_daily, so market.bread reflects
	# current inventory after yesterday's trading and overnight decay.
	if not ever_had_bread_supply and market != null and market.bread > 0:
		ever_had_bread_supply = true
		if event_bus:
			event_bus.log("[LaborMkt] Day %d: first bread supply established (market.bread=%d) - migration now eligible after grace" % [day, market.bread])

	# On the 7-day cadence, recompute utility for ALL agents and log [CAREER EVAL]
	if day % EVAL_INTERVAL_DAYS == 0:
		_evaluate_careers_for_all_agents(day)

	# Evaluate each household for role switch or migration
	# Iterate a duplicate to guard against array modification during iteration
	for h in all_households.duplicate():
		if h and is_instance_valid(h):
			_evaluate_household(h, day)

	# Evaluate producers for sustained-loss migration
	_evaluate_producer_migration(day)

	# ── Daily career summary (instrumentation only) ──────────────────────
	# Sanity: on eval days evals_today must equal # of [CAREER EVAL] lines emitted
	var expected_eval_agents: int = 0
	if day % EVAL_INTERVAL_DAYS == 0:
		for a in all_farmers:
			if a and is_instance_valid(a) and a.get_node_or_null("CareerEvaluator") != null:
				expected_eval_agents += 1
		for a in all_bakers:
			if a and is_instance_valid(a) and a.get_node_or_null("CareerEvaluator") != null:
				expected_eval_agents += 1
		for a in all_households:
			if a and is_instance_valid(a) and a.get_node_or_null("CareerEvaluator") != null:
				expected_eval_agents += 1
		if evals_today < expected_eval_agents:
			var warn: String = "[CAREER WARN] day=%d evals_today=%d < expected=%d — counter/emit mismatch" % [
				day, evals_today, expected_eval_agents]
			push_warning(warn)
			print(warn)
			if event_bus:
				event_bus.log(warn)

	var avg_f: float = farmer_profit_ema
	var avg_b: float = baker_profit_ema
	var summary_line: String = "[CAREER SUMMARY] day=%d evals=%d switches=%d blocked=%d avg_profit_farmer=%.2f avg_profit_baker=%.2f reason_counts(scarcity=%d utility=%d)" % [
		day, evals_today, switches_today, blocked_today, avg_f, avg_b, reason_scarcity_today, reason_utility_today]
	print(summary_line)
	if event_bus:
		event_bus.log(summary_line)


# ─── Unified career evaluation (single authority) ────────────────────────────

## Recompute utility for ALL agents (farmers, bakers, households) and log
## [CAREER EVAL] for each. Called from update_daily on the 7-day cadence.
func _evaluate_careers_for_all_agents(day: int) -> void:
	_reset_eval_diag()

	var all_agents: Array = []
	for f in all_farmers:
		if f and is_instance_valid(f):
			all_agents.append(f)
	for b in all_bakers:
		if b and is_instance_valid(b):
			all_agents.append(b)
	for h in all_households:
		if h and is_instance_valid(h):
			all_agents.append(h)

	for agent in all_agents:
		var ce = agent.get_node_or_null("CareerEvaluator")
		if ce == null:
			continue

		# Force evaluation by resetting last_eval_day so the cadence check passes
		ce.last_eval_day = -999
		ce.evaluate(day, agent, econ_stats, bread_scarcity_ema, wheat_scarcity_ema)

		_log_career_eval(day, agent, ce)

	_emit_eval_summary(day)


## Log [CAREER EVAL] for a single agent including gate status.
func _log_career_eval(day: int, agent: Node, ce) -> void:
	evals_today += 1
	var pop_id: String = agent.person_name if agent.get("person_name") and agent.person_name != "" else agent.name
	var role: String = agent.current_role if agent.get("current_role") else "?"
	var cash: float = agent.get_cash() if agent.has_method("get_cash") else 0.0
	var bread: int = agent.inv.get_qty("bread") if agent.get("inv") and agent.inv else 0
	var food_target: int = agent.food_reserve.min_reserve_units if agent.get("food_reserve") and agent.food_reserve else 3
	var food_required: int = ceili(food_target * FOOD_BUFFER_FRACTION)
	var profit_f: float = ce.last_income_farmer * ce.last_sf_farmer
	var profit_b: float = ce.last_income_baker * ce.last_sf_baker

	# Determine best role and gate status for this agent
	var best_role: String = ce.recommended_role
	var allowed: int = 1
	var block: String = "none"

	if best_role != role:
		# Check gates in priority order
		if agent.get("switch_cooldown_days") != null and agent.switch_cooldown_days > 0:
			allowed = 0
			block = "cooldown"
		elif agent.get("days_in_role") != null and agent.days_in_role < MIN_TENURE_DAYS:
			allowed = 0
			block = "tenure"
		elif cash < SAVINGS_BUFFER_REQUIRED:
			allowed = 0
			block = "savings"
		elif bread < food_required:
			allowed = 0
			block = "food_buffer"
		elif best_role == "Farmer" and field_count_ref.size() >= max_fields:
			allowed = 0
			block = "land_cap"
		else:
			# Margin gate
			var u_best: float = maxf(ce.utility_farmer, ce.utility_baker)
			var u_cur: float = ce.utility_current
			var margin: float = IMPROVEMENT_MARGIN
			var last_sw: int = agent.last_switch_day if agent.get("last_switch_day") != null else -999
			if last_sw >= 0 and (day - last_sw) < RECENT_SWITCH_WINDOW_DAYS:
				margin = RECENT_SWITCH_MARGIN
			if u_cur == 0.0:
				if u_best <= 0.0:
					allowed = 0
					block = "margin_zero"
			elif u_best < u_cur * (1.0 + margin):
				allowed = 0
				block = "margin"

	# Store eval summary on agent for inspector
	var scar_b: float = 1.0 if (market and market.bread <= 0) else 0.0
	var scar_w: float = 1.0 if (market and market.wheat <= 0) else 0.0
	if agent.get("last_career_eval") != null:
		agent.last_career_eval = ce.get_eval_summary(agent, scar_b, scar_w)

	var line: String = "[CAREER EVAL] day=%d pop=%s role=%s cash=%.2f food=%d/%d skill(F=%.2f B=%.2f) profit(F=%.2f B=%.2f) income(F=%.2f B=%.2f) U(F=%.2f B=%.2f) best=%s allowed=%d block=%s" % [
		day, pop_id, role, cash,
		bread, food_target,
		agent.skill_farmer if agent.get("skill_farmer") != null else 0.0,
		agent.skill_baker if agent.get("skill_baker") != null else 0.0,
		profit_f, profit_b,
		ce.last_income_farmer, ce.last_income_baker,
		ce.utility_farmer, ce.utility_baker,
		best_role, allowed, block]
	print(line)
	if event_bus:
		event_bus.log(line)

	# ── Aggregation for [CAREER EVAL SUMMARY] ────────────────────────────
	_eval_diag.total += 1
	if best_role == "Farmer":
		_eval_diag.best_farmer += 1
	else:
		_eval_diag.best_baker += 1

	if best_role == role:
		_eval_diag.best_stay += 1
		_eval_diag.allowed_stay += 1
	elif allowed == 1:
		if best_role == "Farmer":
			_eval_diag.allowed_farmer += 1
		else:
			_eval_diag.allowed_baker += 1
	else:
		_eval_diag.allowed_stay += 1
		if best_role == "Farmer":
			_eval_diag.blocked_best_farmer += 1
		else:
			_eval_diag.blocked_best_baker += 1
		match block:
			"cooldown":
				_eval_diag.block_cooldown += 1
			"tenure":
				_eval_diag.block_tenure += 1
			"savings":
				_eval_diag.block_cash += 1
			"food_buffer":
				_eval_diag.block_food += 1
			"land_cap":
				_eval_diag.block_land_cap += 1
			"margin", "margin_zero":
				_eval_diag.block_margin += 1
			_:
				_eval_diag.block_other += 1

	# ── Store per-agent diagnostic fields for inspector ──────────────────
	if agent.get("last_switch_allowed") != null:
		agent.last_switch_allowed = (allowed == 1)
	if agent.get("last_block_reason") != null:
		agent.last_block_reason = block

	# ── Build example strings (cap at 5 each) ────────────────────────────
	var ex: String = "Pop %s role=%s Uf=%.2f Ub=%.2f best=%s block=%s cash=%.0f food=%d/%d" % [
		pop_id, role, ce.utility_farmer, ce.utility_baker, best_role, block, cash, bread, food_target]
	if best_role != role and allowed == 0 and _eval_diag.examples_blocked.size() < 5:
		_eval_diag.examples_blocked.append(ex)
	elif best_role != role and allowed == 1 and _eval_diag.examples_allowed.size() < 5:
		_eval_diag.examples_allowed.append(ex)


# ─── Household evaluation ────────────────────────────────────────────────────

## Evaluate a single household: migration first (with grace gate), then role switch.
func _evaluate_household(h: Node, day: int) -> void:
	# Tick down switch cooldown
	if h.switch_cooldown_days > 0:
		h.switch_cooldown_days -= 1

	# Track survival mode (any day with failed food = survival mode day)
	if h.consecutive_failed_food_days > 0:
		h.days_in_survival_mode += 1
	else:
		h.days_in_survival_mode = 0

	# ── Startup grace / bootstrap gate ───────────────────────────────────────
	# Migration is suppressed during the startup grace window, and also until
	# bread has ever existed at market (prevents evicting households before the
	# supply chain has had any chance to bootstrap).
	var in_grace: bool = (day < STARTUP_GRACE_DAYS)
	var allow_migration: bool = (not in_grace) and ever_had_bread_supply

	# During startup grace: log any would-be migration, bypass switch cooldown
	# so role mobility can still fire (EMA-based), then reset streaks so
	# households get a clean measurement after grace expires.
	if in_grace:
		if h.days_in_survival_mode >= MIGRATION_SURVIVAL_DAYS or \
				h.consecutive_failed_food_days >= MIGRATION_NO_FOOD_DAYS:
			if event_bus:
				event_bus.log("[MIGRATION] suppressed (startup grace) - day=%d fail_streak=%d survival=%d" % [
					day, h.consecutive_failed_food_days, h.days_in_survival_mode])
			h.switch_cooldown_days = 0  # Allow role mobility as pressure relief
		h.consecutive_failed_food_days = 0
		h.days_in_survival_mode = 0
		# Fall through to role switch evaluation (utility-driven)

	# ── Migration check (priority over role switch) ──────────────────────────
	if h.days_in_survival_mode >= MIGRATION_SURVIVAL_DAYS:
		if allow_migration:
			if event_bus:
				event_bus.log("[LaborMkt] %s migrating: %d days in survival mode" % [h.name, h.days_in_survival_mode])
			migrate_requested.emit(h, "survival")
			return
		else:
			# Post-grace but bread never established - suppress and reset
			if event_bus:
				event_bus.log("[MIGRATION] suppressed (no bread ever) - day=%d fail_streak=%d survival=%d" % [
					day, h.consecutive_failed_food_days, h.days_in_survival_mode])
			h.consecutive_failed_food_days = 0
			h.days_in_survival_mode = 0
			h.switch_cooldown_days = 0  # Allow role mobility as pressure relief

	if h.consecutive_failed_food_days >= MIGRATION_NO_FOOD_DAYS:
		if allow_migration:
			if event_bus:
				event_bus.log("[LaborMkt] %s migrating: %d consecutive days no food" % [h.name, h.consecutive_failed_food_days])
			migrate_requested.emit(h, "no_food")
			return
		else:
			if event_bus:
				event_bus.log("[MIGRATION] suppressed (no bread ever) - day=%d fail_streak=%d" % [
					day, h.consecutive_failed_food_days])
			h.consecutive_failed_food_days = 0
			h.days_in_survival_mode = 0
			h.switch_cooldown_days = 0  # Allow role mobility as pressure relief

	# ── Utility-based role switch check ──────────────────────────────────────
	# Only evaluate on the 7-day cadence
	if day % EVAL_INTERVAL_DAYS != 0:
		return

	var pop_id: String = h.person_name if h.get("person_name") and h.person_name != "" else h.name

	if h.switch_cooldown_days > 0:
		_log_career_blocked(day, pop_id, "?", "cooldown", h.switch_cooldown_days, h)
		return

	# Gate: minimum tenure in current role
	if h.days_in_role < MIN_TENURE_DAYS:
		_log_career_blocked(day, pop_id, "?", "tenure", h.days_in_role, h)
		return

	# Gate: not starving
	var h_hunger = h.get_node_or_null("HungerNeed")
	if h_hunger and h_hunger.is_starving:
		_log_career_blocked(day, pop_id, "?", "starving", 0, h)
		return

	# Gate: food buffer (fraction-based)
	var h_inv = h.get_node_or_null("Inventory")
	var bread_count: int = h_inv.get_qty("bread") if h_inv else 0
	var food_target: int = h.food_reserve.min_reserve_units if h.get("food_reserve") and h.food_reserve else 3
	var food_required: int = ceili(food_target * FOOD_BUFFER_FRACTION)
	if bread_count < food_required:
		_log_career_blocked(day, pop_id, "?", "food_buffer", bread_count, h)
		return

	# Gate: savings buffer
	var cash: float = h.get_cash() if h.has_method("get_cash") else 0.0
	if cash < SAVINGS_BUFFER_REQUIRED:
		_log_career_blocked(day, pop_id, "?", "savings", int(cash), h)
		return

	# Read utility scores from agent's CareerEvaluator
	var ce = h.get_node_or_null("CareerEvaluator")
	if ce == null:
		return
	var u_farmer: float = ce.utility_farmer
	var u_baker: float = ce.utility_baker
	var u_current: float = ce.utility_current

	# Determine best alternative
	var best_u: float = maxf(u_farmer, u_baker)
	var best_role: String = "Farmer" if u_farmer >= u_baker else "Baker"

	# Skip if the best role IS the current role
	if best_role == h.current_role:
		return

	# Gate: land cap (block farmer switches when fields are full)
	if best_role == "Farmer" and field_count_ref.size() >= max_fields:
		_log_career_blocked(day, pop_id, "Farmer", "land_cap", field_count_ref.size(), h)
		return

	# Gate: improvement margin (higher if recently switched)
	var margin: float = IMPROVEMENT_MARGIN
	var last_sw: int = h.last_switch_day if h.get("last_switch_day") != null else -999
	if last_sw >= 0 and (day - last_sw) < RECENT_SWITCH_WINDOW_DAYS:
		margin = RECENT_SWITCH_MARGIN

	if u_current == 0.0:
		if best_u <= 0.0:
			_log_career_blocked(day, pop_id, best_role, "margin_zero", 0, h)
			return
	elif best_u < u_current * (1.0 + margin):
		_log_career_blocked(day, pop_id, best_role, "margin", int(margin * 100.0), h)
		return

	# All gates passed — request switch
	var new_role: String = best_role.to_lower()
	switches_today += 1
	reason_utility_today += 1

	var delta: float = best_u - u_current
	var ratio: float = best_u / maxf(0.01, absf(u_current))
	var decision_line: String = "[CAREER DECISION] day=%d pop=%s from=%s to=%s reason=utility Uc=%.2f Ub=%.2f delta=%.2f ratio=%.2f cash=%.0f food=%d/%d" % [
		day, pop_id, h.current_role, best_role,
		u_current, best_u, delta, ratio, cash, bread_count, food_target]
	print(decision_line)
	if event_bus:
		event_bus.log(decision_line)
	if h.has_method("log_event"):
		h.log_event("Switched: %s->%s reason=utility delta=%.2f ratio=%.2f cash=$%.0f" % [
			h.current_role, best_role, delta, ratio, cash])
	if h.get("last_career_decision") != null:
		h.last_career_decision = "day=%d utility %s->%s Uc=%.2f Ub=%.2f delta=%.2f ratio=%.2f" % [
			day, h.current_role, best_role, u_current, best_u, delta, ratio]
	role_switch_requested.emit(h, new_role)
	h.switch_cooldown_days = SWITCH_COOLDOWN_DAYS


# ─── Producer migration evaluation ───────────────────────────────────────────

## Check producers for sustained negative cashflow and emit migration signal.
func _evaluate_producer_migration(_day: int) -> void:
	for f in all_farmers.duplicate():
		if f and is_instance_valid(f):
			if f.consecutive_days_negative_cashflow >= MIGRATION_NEG_PROFIT_DAYS:
				if event_bus:
					event_bus.log("[LaborMkt] %s migrating: %d days negative cashflow" % [
						f.name, f.consecutive_days_negative_cashflow])
				migrate_requested.emit(f, "negative_profit")

	for b in all_bakers.duplicate():
		if b and is_instance_valid(b):
			if b.consecutive_days_negative_cashflow >= MIGRATION_NEG_PROFIT_DAYS:
				if event_bus:
					event_bus.log("[LaborMkt] %s migrating: %d days negative cashflow" % [
						b.name, b.consecutive_days_negative_cashflow])
				migrate_requested.emit(b, "negative_profit")


# ─── Spawn suppression ────────────────────────────────────────────────────────

## Returns true when bread scarcity is high enough that new household spawns
## should be suppressed (no point growing population into a famine).
func should_suppress_spawn() -> bool:
	return bread_scarcity_ema >= SPAWN_SUPPRESS_SCARCITY


# ─── Eval-day diagnostic aggregation ─────────────────────────────────────────

func _reset_eval_diag() -> void:
	_eval_diag = {
		"total": 0,
		"best_farmer": 0,
		"best_baker": 0,
		"best_stay": 0,
		"allowed_farmer": 0,
		"allowed_baker": 0,
		"allowed_stay": 0,
		"blocked_best_farmer": 0,
		"blocked_best_baker": 0,
		"blocked_best_stay": 0,
		"block_land_cap": 0,
		"block_cooldown": 0,
		"block_tenure": 0,
		"block_food": 0,
		"block_cash": 0,
		"block_margin": 0,
		"block_other": 0,
		"examples_blocked": [],
		"examples_allowed": [],
	}


func _emit_eval_summary(day: int) -> void:
	var d: Dictionary = _eval_diag
	var summary: String = "[CAREER EVAL SUMMARY] day=%d evals=%d best(F=%d B=%d H=%d) allowed(F=%d B=%d H=%d) blocked_best(F=%d B=%d H=%d) blocked_reasons(land=%d cd=%d ten=%d food=%d cash=%d margin=%d other=%d)" % [
		day, d.total,
		d.best_farmer, d.best_baker, d.best_stay,
		d.allowed_farmer, d.allowed_baker, d.allowed_stay,
		d.blocked_best_farmer, d.blocked_best_baker, d.blocked_best_stay,
		d.block_land_cap, d.block_cooldown, d.block_tenure,
		d.block_food, d.block_cash, d.block_margin, d.block_other]
	print(summary)
	if event_bus:
		event_bus.log(summary)
	for ex in d.examples_blocked:
		var line: String = "[CAREER EXAMPLE BLOCKED] %s" % ex
		print(line)
		if event_bus:
			event_bus.log(line)
	for ex in d.examples_allowed:
		var line: String = "[CAREER EXAMPLE ALLOWED] %s" % ex
		print(line)
		if event_bus:
			event_bus.log(line)


func _emit_econ_snap(day: int) -> void:
	var pop: int = all_farmers.size() + all_bakers.size() + all_households.size()
	var fields: int = field_count_ref.size()
	var wheat_inv: int = market.wheat if market else 0
	var bread_inv: int = market.bread if market else 0
	var snap: String = "[ECON SNAP] day=%d pop=%d fields=%d/%d inv(wheat=%d bread=%d) scar(w=%.2f b=%.2f) profit(F=%.2f B=%.2f)" % [
		day, pop, fields, max_fields,
		wheat_inv, bread_inv,
		wheat_scarcity_ema, bread_scarcity_ema,
		farmer_profit_ema, baker_profit_ema]
	print(snap)
	if event_bus:
		event_bus.log(snap)


# ─── Private helpers ─────────────────────────────────────────────────────────

func _log_career_blocked(day: int, pop_id: String, desired_role: String, block: String, detail_val: int, h: Node) -> void:
	blocked_today += 1
	var current_role: String = h.current_role if h.get("current_role") else "?"
	var ce = h.get_node_or_null("CareerEvaluator") if h else null
	var uc: float = ce.utility_current if ce else 0.0
	var ub: float = maxf(ce.utility_farmer, ce.utility_baker) if ce else 0.0
	var line: String = "[CAREER BLOCKED] day=%d pop=%s current=%s desired=%s block=%s Uc=%.2f Ub=%.2f" % [
		day, pop_id, current_role, desired_role, block, uc, ub]
	print(line)
	if event_bus:
		event_bus.log(line)
	if h and h.get("last_career_decision") != null:
		h.last_career_decision = "day=%d blocked=%s desired=%s Uc=%.2f Ub=%.2f" % [day, block, desired_role, uc, ub]


func _ema(prev: float, new_val: float) -> float:
	return EMA_ALPHA * new_val + (1.0 - EMA_ALPHA) * prev


## Compute the average daily money delta across a list of agents.
## Updates prev_money dict with current values for next call.
func _compute_avg_delta(agents: Array, prev_money: Dictionary) -> float:
	if agents.is_empty():
		return 0.0
	var total_delta: float = 0.0
	var count: int = 0
	for agent in agents:
		if not (agent and is_instance_valid(agent)):
			continue
		var w = agent.get_node_or_null("Wallet")
		if w == null:
			continue
		var cur: float = w.money
		var prev: float = prev_money.get(agent, cur)  # First day: delta = 0
		total_delta += (cur - prev)
		prev_money[agent] = cur
		count += 1
	if count == 0:
		return 0.0
	return total_delta / float(count)
