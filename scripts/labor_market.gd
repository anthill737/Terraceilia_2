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
const SAVINGS_BUFFER_REQUIRED: float = 100.0
const HUNGER_SAFETY_BREAD: int = 2

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

	# Evaluate each household for role switch or migration
	# Iterate a duplicate to guard against array modification during iteration
	for h in all_households.duplicate():
		if h and is_instance_valid(h):
			_evaluate_household(h, day)

	# Evaluate producers for sustained-loss migration
	_evaluate_producer_migration(day)

	# ── Daily career summary (instrumentation only) ──────────────────────
	var avg_f: float = farmer_profit_ema
	var avg_b: float = baker_profit_ema
	var summary_line: String = "[CAREER SUMMARY] day=%d evals=%d switches=%d blocked=%d avg_profit_farmer=%.2f avg_profit_baker=%.2f reason_counts(scarcity=%d utility=%d)" % [
		day, evals_today, switches_today, blocked_today, avg_f, avg_b, reason_scarcity_today, reason_utility_today]
	print(summary_line)
	if event_bus:
		event_bus.log(summary_line)


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

	evals_today += 1
	var pop_id: String = h.person_name if h.get("person_name") and h.person_name != "" else h.name

	if h.switch_cooldown_days > 0:
		_log_career_blocked(day, pop_id, "?", "cooldown", h.switch_cooldown_days, h)
		return

	# Gate: minimum tenure in current role
	if h.days_in_role < MIN_TENURE_DAYS:
		_log_career_blocked(day, pop_id, "?", "tenure", h.days_in_role, h)
		return

	# Gate: not starving and has minimum food buffer
	var h_hunger = h.get_node_or_null("HungerNeed")
	if h_hunger and h_hunger.is_starving:
		_log_career_blocked(day, pop_id, "?", "starving", 0, h)
		return
	var h_inv = h.get_node_or_null("Inventory")
	if h_inv and h_inv.get_qty("bread") < HUNGER_SAFETY_BREAD:
		_log_career_blocked(day, pop_id, "?", "food_buffer", h_inv.get_qty("bread") if h_inv else 0, h)
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

	# All gates passed — request switch (reason is always "utility" in current code)
	var new_role: String = best_role.to_lower()
	switches_today += 1
	reason_utility_today += 1

	var decision_line: String = "[CAREER DECISION] pop=%s from=%s to=%s reason=utility day=%d U_F=%.2f U_B=%.2f U_cur=%.2f margin=%.0f%%" % [
		pop_id, h.current_role, best_role, day,
		u_farmer, u_baker, u_current, margin * 100.0]
	print(decision_line)
	if event_bus:
		event_bus.log(decision_line)
	if h.has_method("log_event"):
		h.log_event("Switched: %s->%s reason=utility margin=%.0f%% cash=$%.0f" % [
			h.current_role, best_role, margin * 100.0, cash])
	if h.get("last_career_decision") != null:
		h.last_career_decision = "day=%d utility %s->%s U_F=%.2f U_B=%.2f margin=%.0f%%" % [
			day, h.current_role, best_role, u_farmer, u_baker, margin * 100.0]
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


# ─── Private helpers ─────────────────────────────────────────────────────────

func _log_career_blocked(day: int, pop_id: String, desired_role: String, block: String, detail_val: int, h: Node) -> void:
	blocked_today += 1
	var line: String = "[CAREER BLOCKED] pop=%s desired=%s block=%s day=%d val=%d" % [
		pop_id, desired_role, block, day, detail_val]
	print(line)
	if event_bus:
		event_bus.log(line)
	if h and h.get("last_career_decision") != null:
		h.last_career_decision = "day=%d blocked=%s (val=%d)" % [day, block, detail_val]


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
