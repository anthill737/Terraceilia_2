extends Node
class_name LaborMarket

## LaborMarket: utility-based occupational mobility and migration.
## Signals main.gd when agents should switch roles or leave the simulation.
## Operates on day_changed cadence - called once per game day from main.gd.
## Switching decisions use per-pop expected-utility scores from CareerEvaluator.

# ─── Signals ────────────────────────────────────────────────────────────────
signal migrate_requested(agent: Node, reason: String)
signal role_switch_requested(household: Node, new_role: String)
## Batch 3: a business that fails closes; its owner stays in town as a household.
signal business_failed(agent: Node)

# ─── EMA constants (diagnostics + spawn suppression) ────────────────────────
const EMA_ALPHA: float = 0.2

# ─── Training / cooldown constants ──────────────────────────────────────────
const FARMER_TRAINING_DAYS: int = 2
const BAKER_TRAINING_DAYS: int = 3
const SWITCH_COOLDOWN_DAYS: int = 14

# ─── Utility-based switching gates ─────────────────────────────────────────
const MIN_TENURE_DAYS: int = 7
const EVAL_INTERVAL_DAYS: int = 7
const IMPROVEMENT_MARGIN: float = 0.15
const RECENT_SWITCH_MARGIN: float = 0.25
const RECENT_SWITCH_WINDOW_DAYS: int = 30
const SAVINGS_BUFFER_REQUIRED: float = 100.0   # batch 3: coins saved before opening a business (was 200)
const STARTUP_COST: float = 50.0               # batch 3: paid to the town market on opening
const COLD_DAYS_TO_LEAVE: int = 10  # was 4: six households with full purses left over one empty woodpile
const FOOD_BUFFER_FRACTION: float = 2.0 / 3.0

# ─── Migration constants ──────────────────────────────────────────────────────
const MIGRATION_NO_FOOD_DAYS: int = 4      # Consecutive days without food → migrate
const MIGRATION_NEG_PROFIT_DAYS: int = 8  # Consecutive days negative cashflow → migrate
const MIGRATION_SURVIVAL_DAYS: int = 5    # Days in survival mode → migrate
## A producer only leaves when the losing streak has also left them broke: less than this many
## days of upkeep, or than BROKE_LOAVES loaves of bread at today's price. A working market drives
## profit towards zero; breaking even is not failure (docs/ECONOMY_BATCH1.md).
const BROKE_UPKEEP_DAYS: float = 8.0
const BROKE_LOAVES: float = 3.0

# ─── Labor mode (docs/ECONOMY_BATCH1.md) ─────────────────────────────────────
## "switching": farmers and bakers change trade when the career evaluator says so.
## "wages": producers keep their trade; one with more work than hands hires households as
## farm or bakery hands and pays them a daily wage out of their own wallet.
## Set by config ("labor": {"mode": ...}) or --labor-mode=<mode> after "--".
var labor_mode: String = "wages"   # hiring (batch 2 default); "switching" lets producers change trade
const WAGE_MARKUP: float = 1.25           # batch 3: wage = (1 loaf + 1 firewood at today's prices) x this
## Output with 0, 1 and 2 hired hands, as a multiple of what the owner makes alone. Each
## further hand adds the same share less again (here four fifths of the one before): see
## hand_gain. The third number was 1.75 (a half less each time), which made a third hand
## worth nothing and a bigger shop pointless.
const HAND_STEPS: Array = [1.0, 1.5, 1.9]
const MAX_HANDS: int = 2             # hired hands a shop holds at level 1
const SHOP_MAX_LEVEL: int = 6        # each level above the first holds one more hand
const HIRE_CASH_DAYS: float = 10.0        # employer keeps this many days of wages in hand
const FIRE_LOSS_DAYS: int = 5             # days of falling cash before a hand is let go
## Producer trade switches: days between switches for one person.
const PRODUCER_SWITCH_COOLDOWN_DAYS: int = 21
## Fields with no farmer (village sets it): a farmer can take one over instead of a new plot.
var free_field_count: Callable = func() -> int: return 0
## Asks the builders (Housing) to extend `p`'s shop by a level. Set by the village.
var extend_shop: Callable = func(_p, _day: int) -> bool: return false

# ─── Startup grace period ─────────────────────────────────────────────────────
## Days at sim start during which household migration is suppressed.
## Matches SimulationRunner.STARTUP_GRACE_DAYS — keep in sync if tuning.
const STARTUP_GRACE_DAYS: int = 5

# ─── Spawn suppression ────────────────────────────────────────────────────────
const SPAWN_SUPPRESS_SCARCITY: float = 0.5  # Suppress new household spawn above this

# ─── Forward-looking scarcity expectation weights (Part A) ───────────────────
var _scarcity_weight_farmer: float = 2.0
var _scarcity_weight_baker: float = 2.0

# ─── Anti-stampede: per-eval role quota (Part B) ─────────────────────────────
var _quota_pct: float = 0.10
var _quota_min: int = 1
var _quota_max: int = 5
var _current_quota: int = 1
var _entries_to_farmer_today: int = 0
var _entries_to_baker_today: int = 0
var _blocked_quota_farmer_today: int = 0
var _blocked_quota_baker_today: int = 0

# ─── EMA state ──────────────────────────────────────────────────────────────
var farmer_profit_ema: float = 0.0
var baker_profit_ema: float = 0.0
var bread_scarcity_ema: float = 0.0
var wheat_scarcity_ema: float = 0.0
var firewood_scarcity_ema: float = 0.0
var _wood_entry_day: int = -999
var _smith_entry_day: int = -999
var _tailor_entry_day: int = -999

# ─── Prev-day money snapshots (for daily profit delta) ──────────────────────
var farmer_prev_money: Dictionary = {}  # agent → float
var baker_prev_money: Dictionary = {}   # agent → float

# ─── Shared array references (assigned by main.gd after init) ───────────────
## These must be set to the SAME array objects as main.gd uses so additions
## are automatically visible here.
var all_farmers: Array = []
var all_bakers: Array = []
var all_households: Array = []
var all_woodworkers: Array = []
var all_smiths: Array = []
var all_tailors: Array = []
## Everyone's clothes (Clothing). Set by the village.
var clothing = null

# ─── Dependencies ────────────────────────────────────────────────────────────
var market = null
var event_bus = null
var econ_stats = null
var pop_mgr = null
var field_count_ref: Array = []
var max_fields: int = 10

var _initialized: bool = false

# Guard: ensures [POP SNAP] prints exactly once per sim day.
var _last_pop_snap_day: int = -1

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


func load_career_entry_config(cfg: Dictionary) -> void:
	var ce_cfg: Dictionary = cfg.get("career_entry", {})
	_scarcity_weight_farmer = float(ce_cfg.get("scarcity_expectation_weight_farmer", 2.0))
	_scarcity_weight_baker = float(ce_cfg.get("scarcity_expectation_weight_baker", 2.0))
	_quota_pct = float(ce_cfg.get("career_entry_quota_pct", 0.10))
	_quota_min = int(ce_cfg.get("career_entry_quota_min", 1))
	_quota_max = int(ce_cfg.get("career_entry_quota_max", 5))
	labor_mode = str(cfg.get("labor", {}).get("mode", labor_mode))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--labor-mode="):
			labor_mode = arg.substr(13)
	if event_bus:
		event_bus.emit_log("[LaborMkt] labor mode: %s" % labor_mode)
	print("[LaborMkt] labor mode: %s" % labor_mode)


# ─── Main daily update ────────────────────────────────────────────────────────

## Called once per game day (from main._on_calendar_day_changed).
## Days in a row the market has been short of what each trade makes. A business opens only
## after OPEN_SHORT_DAYS of it: on a single dip a village once ended up with 8 farms.
const OPEN_SHORT_DAYS: int = 3
var _short_days: Dictionary = {"Farmer": 0, "Baker": 0, "Woodworker": 0, "Smith": 0, "Tailor": 0}

func update_daily(day: int) -> void:
	if not _initialized:
		return
	for role in _short_days.keys():
		_short_days[role] = int(_short_days[role]) + 1 if _market_wants(role) else 0

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

	# Update scarcity EMAs (proportional: 1.0 when empty, 0.0 at/above target)
	var bread_scarce: float = 0.0
	var wheat_scarce: float = 0.0
	if market != null:
		if market.bread_target > 0:
			bread_scarce = clampf(1.0 - float(market.bread) / float(market.bread_target), 0.0, 1.0)
		elif market.bread <= 0:
			bread_scarce = 1.0
		if market.wheat_target > 0:
			wheat_scarce = clampf(1.0 - float(market.wheat) / float(market.wheat_target), 0.0, 1.0)
		elif market.wheat <= 0:
			wheat_scarce = 1.0
	bread_scarcity_ema = _ema(bread_scarcity_ema, bread_scarce)
	if market != null:
		firewood_scarcity_ema = _ema(firewood_scarcity_ema, clampf(1.0 - float(market.firewood) / float(maxi(1, market.firewood_target)), 0.0, 1.0))
	wheat_scarcity_ema = _ema(wheat_scarcity_ema, wheat_scarce)

	# Daily population + macro-conditions snapshots
	_emit_pop_snap(day)
	_emit_econ_snap(day)

	# Periodic diagnostic log (every 5 days)
	if event_bus and day % 5 == 0:
		event_bus.emit_log("[LaborMkt] Day %d | f_profit=%.2f b_profit=%.2f bread_scar=%.2f wheat_scar=%.2f" % [
			day, farmer_profit_ema, baker_profit_ema, bread_scarcity_ema, wheat_scarcity_ema])

	# Track first-ever bread supply (checked before household evaluation each day).
	# market.on_day_changed fires before update_daily, so market.bread reflects
	# current inventory after yesterday's trading and overnight decay.
	if not ever_had_bread_supply and market != null and market.bread > 0:
		ever_had_bread_supply = true
		if event_bus:
			event_bus.emit_log("[LaborMkt] Day %d: first bread supply established (market.bread=%d) - migration now eligible after grace" % [day, market.bread])

	# On the 7-day cadence, recompute utility for ALL agents and log [CAREER EVAL]
	if day % EVAL_INTERVAL_DAYS == 0:
		_evaluate_careers_for_all_agents(day)

	# Evaluate each household for role switch or migration
	# Iterate a duplicate to guard against array modification during iteration
	for h in all_households.duplicate():
		if h and is_instance_valid(h):
			_evaluate_household(h, day)

	# Producers change trade (switching mode) on the evaluation cadence.
	if labor_mode == "switching" and day % EVAL_INTERVAL_DAYS == 0:
		for p in all_farmers.duplicate() + all_bakers.duplicate():
			if p and is_instance_valid(p):
				_evaluate_producer_switch(p, day)

	# Hands and wages: pay today's wages, then hire or let go.
	# Batch 2: hiring hands is how households earn, so it runs in both modes; the modes now
	# differ only in whether farmers and bakers may change trade.
	_update_hands(day)
	# People with no work live off a garden plot and gathered wood (docs/WORKING_TOWN.md).
	_update_cottagers(day)
	# Batch 3: every hearth burns one firewood a day.
	_update_firewood(day)
	# Shops wear their tools out and buy new ones from the smith (docs/SMITH.md).
	_update_tools(day)

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
				event_bus.emit_log(warn)

	var avg_f: float = farmer_profit_ema
	var avg_b: float = baker_profit_ema
	var summary_line: String = "[CAREER SUMMARY] day=%d evals=%d switches=%d blocked=%d avg_profit_farmer=%.2f avg_profit_baker=%.2f reason_counts(scarcity=%d utility=%d)" % [
		day, evals_today, switches_today, blocked_today, avg_f, avg_b, reason_scarcity_today, reason_utility_today]
	print(summary_line)
	if event_bus:
		event_bus.emit_log(summary_line)


# ─── Unified career evaluation (single authority) ────────────────────────────

## Recompute utility for ALL agents (farmers, bakers, households) and log
## [CAREER EVAL] for each. Called from update_daily on the 7-day cadence.
func _evaluate_careers_for_all_agents(day: int) -> void:
	_reset_eval_diag()

	# Precompute quota once from PopulationManager (no per-agent scene tree scan)
	var total_pop: int = pop_mgr.count() if pop_mgr else (all_farmers.size() + all_bakers.size() + all_households.size())
	_current_quota = clampi(int(floor(float(total_pop) * _quota_pct)), _quota_min, _quota_max)
	_entries_to_farmer_today = 0
	_entries_to_baker_today = 0
	_blocked_quota_farmer_today = 0
	_blocked_quota_baker_today = 0

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

		# Propagate scarcity expectation weights
		ce.scarcity_expectation_weight_farmer = _scarcity_weight_farmer
		ce.scarcity_expectation_weight_baker = _scarcity_weight_baker

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
	var profit_f: float = ce.last_diag_expected_farmer
	var profit_b: float = ce.last_diag_expected_baker

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
		elif cash < Tuning.f("shop_savings_needed", SAVINGS_BUFFER_REQUIRED):
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

	# For Household, income includes scarcity expectation
	var log_income_f: float = ce.last_diag_expected_farmer if role == "Household" else ce.last_income_farmer
	var log_income_b: float = ce.last_diag_expected_baker if role == "Household" else ce.last_income_baker

	var line: String = "[CAREER EVAL] day=%d pop=%s role=%s cash=%.2f food=%d/%d skill(F=%.2f B=%.2f) profit(F=%.2f B=%.2f) income(F=%.2f B=%.2f) U(F=%.2f B=%.2f) best=%s allowed=%d block=%s" % [
		day, pop_id, role, cash,
		bread, food_target,
		agent.skill_farmer if agent.get("skill_farmer") != null else 0.0,
		agent.skill_baker if agent.get("skill_baker") != null else 0.0,
		profit_f, profit_b,
		log_income_f, log_income_b,
		ce.utility_farmer, ce.utility_baker,
		best_role, allowed, block]
	print(line)
	if event_bus:
		event_bus.emit_log(line)

	# Emit [CAREER EXPECT] for Household agents when scarcity contributes
	if role == "Household" and (ce.last_household_scar_income_f > 0.0 or ce.last_household_scar_income_b > 0.0):
		var expect_line: String = "[CAREER EXPECT] day=%d pop=%s role=Household income(F=%.2f=profit*skill+%.2f*%.1f) income(B=%.2f=profit*skill+%.2f*%.1f)" % [
			day, pop_id,
			ce.last_diag_expected_farmer, wheat_scarcity_ema, _scarcity_weight_farmer,
			ce.last_diag_expected_baker, bread_scarcity_ema, _scarcity_weight_baker]
		print(expect_line)
		if event_bus:
			event_bus.emit_log(expect_line)

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
			"quota_farmer":
				_eval_diag.block_quota_farmer += 1
			"quota_baker":
				_eval_diag.block_quota_baker += 1
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
	if h.has_meta("merchant"):
		return   # merchants keep their trade; the leave and new-business rules are for households
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
				event_bus.emit_log("[MIGRATION] suppressed (startup grace) - day=%d fail_streak=%d survival=%d" % [
					day, h.consecutive_failed_food_days, h.days_in_survival_mode])
			h.switch_cooldown_days = 0  # Allow role mobility as pressure relief
		h.consecutive_failed_food_days = 0
		h.days_in_survival_mode = 0
		# Fall through to role switch evaluation (utility-driven)

	# ── Migration check (priority over role switch) ──────────────────────────
	if h.days_in_survival_mode >= MIGRATION_SURVIVAL_DAYS:
		if allow_migration:
			if event_bus:
				event_bus.emit_log("[LaborMkt] %s migrating: %d days in survival mode" % [h.name, h.days_in_survival_mode])
			migrate_requested.emit(h, "survival")
			return
		else:
			# Post-grace but bread never established - suppress and reset
			if event_bus:
				event_bus.emit_log("[MIGRATION] suppressed (no bread ever) - day=%d fail_streak=%d survival=%d" % [
					day, h.consecutive_failed_food_days, h.days_in_survival_mode])
			h.consecutive_failed_food_days = 0
			h.days_in_survival_mode = 0
			h.switch_cooldown_days = 0  # Allow role mobility as pressure relief

	if h.consecutive_failed_food_days >= MIGRATION_NO_FOOD_DAYS:
		if allow_migration:
			if event_bus:
				event_bus.emit_log("[LaborMkt] %s migrating: %d consecutive days no food" % [h.name, h.consecutive_failed_food_days])
			migrate_requested.emit(h, "no_food")
			return
		else:
			if event_bus:
				event_bus.emit_log("[MIGRATION] suppressed (no bread ever) - day=%d fail_streak=%d" % [
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
	if cash < Tuning.f("shop_savings_needed", SAVINGS_BUFFER_REQUIRED):
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
	# Batch 3: opening a wood yard is a third option, judged the same way. At most one
	# household takes it per evaluation week, so a firewood shortage is not answered by a crowd.
	var u_wood: float = _woodworker_utility(ce)
	if u_wood > best_u and day - _wood_entry_day >= EVAL_INTERVAL_DAYS:
		best_u = u_wood
		best_role = "Woodworker"
	# A smithy is weighed the same way (docs/SMITH.md).
	var u_smith: float = _smith_utility(ce)
	if u_smith > best_u and day - _smith_entry_day >= EVAL_INTERVAL_DAYS:
		best_u = u_smith
		best_role = "Smith"
	# And a tailor's shop (docs/CLOTHES.md).
	var u_tailor: float = _tailor_utility(ce)
	if u_tailor > best_u and day - _tailor_entry_day >= EVAL_INTERVAL_DAYS:
		best_u = u_tailor
		best_role = "Tailor"

	# Skip if the best role IS the current role
	if best_role == h.current_role:
		return

	# Gate: the town has to want more of what the new business makes. Profits of the farmer
	# already in town said nothing about whether the market would buy a second farmer's wheat;
	# new farmers opened with the wheat store full, never sold a sack and starved.
	if int(_short_days.get(best_role, 0)) < OPEN_SHORT_DAYS:
		_log_career_blocked(day, pop_id, best_role, "no_demand", 0, h)
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
	elif best_u < u_current + absf(u_current) * margin:
		_log_career_blocked(day, pop_id, best_role, "margin", int(margin * 100.0), h)
		return

	# Gate: per-eval role quota (anti-stampede)
	if best_role == "Farmer" and _entries_to_farmer_today >= _current_quota:
		_blocked_quota_farmer_today += 1
		_log_career_blocked(day, pop_id, "Farmer", "quota_farmer", _current_quota, h)
		return
	if best_role == "Baker" and _entries_to_baker_today >= _current_quota:
		_blocked_quota_baker_today += 1
		_log_career_blocked(day, pop_id, "Baker", "quota_baker", _current_quota, h)
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
		event_bus.emit_log(decision_line)
	if h.has_method("log_event"):
		h.log_event(
			"Decided to switch from %s to %s — looked like a better deal (gain %.2f, ratio %.2f); had $%.0f on hand." %
			[h.current_role, best_role, delta, ratio, cash]
		)
	if h.get("last_career_decision") != null:
		h.last_career_decision = "day=%d utility %s->%s Uc=%.2f Ub=%.2f delta=%.2f ratio=%.2f" % [
			day, h.current_role, best_role, u_current, best_u, delta, ratio]
	role_switch_requested.emit(h, new_role)
	h.switch_cooldown_days = SWITCH_COOLDOWN_DAYS

	# Track entry for quota enforcement
	if best_role == "Farmer":
		_entries_to_farmer_today += 1
	elif best_role == "Baker":
		_entries_to_baker_today += 1
	elif best_role == "Woodworker":
		_wood_entry_day = day
	elif best_role == "Smith":
		_smith_entry_day = day
	elif best_role == "Tailor":
		_tailor_entry_day = day


# ─── Producer migration evaluation ───────────────────────────────────────────

## Producers leave only after a losing streak that has left them broke, and never the last of
## their trade: a town that still eats bread keeps its last farmer and its last baker.
func _evaluate_producer_migration(_day: int) -> void:
	for group in _owner_groups():
		for p in group.duplicate():
			if not (p and is_instance_valid(p)):
				continue
			# Close after a losing streak that left them broke, or as soon as they are broke and
			# going hungry (a business with no sales and no costs never has a "losing" day, so
			# such an owner starved before; now they close and look for work).
			var hungry: bool = _broke_and_hungry(p)
			if not hungry:
				if p.consecutive_days_negative_cashflow < MIGRATION_NEG_PROFIT_DAYS:
					continue
				if not _is_broke(p):
					continue
			# The last farm, bakery or lumber yard stays open whatever happens. A trade the town
			# can live without (a smithy) closes like any shop: its last smith used to starve.
			if _live_count(group) <= 1 and bool(Recovery.TRADES.get(str(p.current_role), {}).get("basic", true)):
				if event_bus:
					event_bus.emit_log("[LaborMkt] %s kept: last of their trade (%d losing days, $%.1f)" % [
						p.name, p.consecutive_days_negative_cashflow, p.get_cash()])
				continue
			if event_bus:
				event_bus.emit_log("[LaborMkt] %s closing shop: %s ($%.1f)" % [
					p.name, "broke and going hungry" if hungry else "%d losing days and broke" % p.consecutive_days_negative_cashflow, p.get_cash()])
			_release_hands(p, "employer left")
			# Batch 3: the business closes and its owner looks for work; nobody leaves town for it.
			business_failed.emit(p)


## True when the market is short of what `role` makes: its stock is below the stock target
## (a few days of what people actually buy).
## Tried 2026-11-13 and taken back out: "below the price band under the target" instead. It
## cut bakery openings from 851 to 150 in eight towns, but wheat arrives in lumps and is
## rarely under the band three days running, so a town sat on one farm with wheat at 2.50;
## and with fewer failed shops paying in, the market's purse ran dry in 2 of 8 towns and 43
## people starved holding coins (docs/SKILL.md).
func _market_wants(role: String) -> bool:
	if market == null:
		return true
	match role:
		"Farmer":
			return market.wheat < market.wheat_target
		"Baker":
			return market.bread < market.bread_target
		"Woodworker":
			return market.firewood < market.firewood_target
		"Smith":
			return market.has_good("tools") and Tuning.on("tools", true) and market.good_stock("tools") < market.good_target("tools")
		"Tailor":
			return market.has_good("clothes") and Clothing.on() and market.good_stock("clothes") < market.good_target("clothes")
	return true


## Broke and going hungry: under BROKE rules and already a couple of days without bread.
func _broke_and_hungry(p: Node) -> bool:
	var hn = p.get("hunger")
	return _is_broke(p) and hn != null and hn.hunger_days <= 3


func _is_broke(p: Node) -> bool:
	var upkeep: float = 0.0
	if p.get("current_job") and p.current_job and p.current_job.get("maintenance_cost_per_day") != null:
		upkeep = float(p.current_job.maintenance_cost_per_day)
	var bread_p: float = market.bread_price if market else 2.5
	return p.get_cash() < maxf(BROKE_UPKEEP_DAYS * upkeep, BROKE_LOAVES * bread_p)


func _live_count(group: Array) -> int:
	var n: int = 0
	for a in group:
		if a and is_instance_valid(a):
			n += 1
	return n


# ─── Producer trade switches (switching mode) ────────────────────────────────

## The same gates a household passes, plus: never the last of a trade, and not twice within
## PRODUCER_SWITCH_COOLDOWN_DAYS. Utilities were refreshed for everyone this eval day.
func _evaluate_producer_switch(p: Node, day: int) -> void:
	var ce = p.get_node_or_null("CareerEvaluator")
	if ce == null:
		return
	var role: String = p.current_role
	var best_role: String = "Farmer" if ce.utility_farmer >= ce.utility_baker else "Baker"
	if best_role == role:
		return
	var pop_id: String = p.person_name if p.get("person_name") and p.person_name != "" else p.name
	var last: int = int(p.get_meta("producer_switch_day", -999))
	if day - last < PRODUCER_SWITCH_COOLDOWN_DAYS:
		_log_career_blocked(day, pop_id, best_role, "cooldown", day - last, p)
		return
	if p.days_in_role < MIN_TENURE_DAYS:
		_log_career_blocked(day, pop_id, best_role, "tenure", p.days_in_role, p)
		return
	var cash: float = p.get_cash()
	if cash < Tuning.f("shop_savings_needed", SAVINGS_BUFFER_REQUIRED):
		_log_career_blocked(day, pop_id, best_role, "savings", int(cash), p)
		return
	var own: Array = all_farmers if role == "Farmer" else all_bakers
	if _live_count(own) <= 1:
		_log_career_blocked(day, pop_id, best_role, "last_of_trade", 1, p)
		return
	if best_role == "Farmer" and field_count_ref.size() >= max_fields and free_field_count.call() == 0:
		_log_career_blocked(day, pop_id, "Farmer", "land_cap", field_count_ref.size(), p)
		return
	var u_best: float = maxf(ce.utility_farmer, ce.utility_baker)
	var u_cur: float = ce.utility_current
	var margin: float = RECENT_SWITCH_MARGIN if last >= 0 and day - last < RECENT_SWITCH_WINDOW_DAYS else IMPROVEMENT_MARGIN
	if u_best <= 0.0:
		_log_career_blocked(day, pop_id, best_role, "margin_zero", 0, p)
		return
	if u_cur > 0.0 and u_best < u_cur * (1.0 + margin):
		_log_career_blocked(day, pop_id, best_role, "margin", int(margin * 100.0), p)
		return
	if (best_role == "Farmer" and _entries_to_farmer_today >= _current_quota) or (best_role == "Baker" and _entries_to_baker_today >= _current_quota):
		_log_career_blocked(day, pop_id, best_role, "quota_" + best_role.to_lower(), _current_quota, p)
		return
	switches_today += 1
	reason_utility_today += 1
	if best_role == "Farmer":
		_entries_to_farmer_today += 1
	else:
		_entries_to_baker_today += 1
	p.set_meta("producer_switch_day", day)
	var line: String = "[CAREER DECISION] day=%d pop=%s from=%s to=%s reason=utility Uc=%.2f Ub=%.2f cash=%.0f (producer)" % [
		day, pop_id, role, best_role, u_cur, u_best, cash]
	print(line)
	if event_bus:
		event_bus.emit_log(line)
	if p.has_method("log_event"):
		p.log_event("Decided to give up %s work for %s; had $%.0f on hand." % [role.to_lower(), best_role.to_lower(), cash])
	role_switch_requested.emit(p, best_role.to_lower())


# ─── Hands and wages (both modes since batch 2) ──────────────────────────────────────

## Daily: each employer pays each hand the day's wage in coins (daily_wage: one loaf plus one
## firewood at today's prices, times WAGE_MARKUP; money moves from one wallet to the other,
## none is made or destroyed). An employer lets a hand go when it cannot pay, or after
## FIRE_LOSS_DAYS days of its cash falling; it takes one on when it can keep HIRE_CASH_DAYS of
## wages in hand, its goods are not piling up unsold at the market, and the hand's extra
## output at today's prices is worth more than the wage. Households without an employer are
## the labour pool.
var wages_paid_total: float = 0.0   # all wages ever paid in this village (tests)
## Employers who wanted to take someone on today and found nobody free.
var open_jobs: int = 0
## The last day an employer wanted a hand and found nobody. Whether a given employer wants
## one flickers from day to day (stock, cash), so a job counts as waiting for
## OPEN_SHORT_DAYS after it was last seen, as long as nobody in town is free to take it.
var last_open_job_day: int = -999
## People in town with no work today (cottagers). Newcomers only come when this is small.
var idle_count: int = 0
const GARDEN_BREAD_KEEP: int = 2     # a cottager's garden keeps this much food in the house
const GATHERED_WOOD_PER_DAY: int = 1 # deadwood a cottager gathers: enough for their own hearth
const GATHERED_WOOD_KEEP: int = 3    # (selling it flooded the firewood market and ruined the woodworker)

func _update_hands(day: int) -> void:
	open_jobs = 0
	var own: bool = Tuning.on("owner_wages", true)
	var base: float = daily_wage(market)
	var need: float = wage_floor()
	var step: float = Tuning.f("price_daily_limit", 0.05)   # a wage moves by at most what a price may in a day
	var paid: float = 0.0
	var employed: int = 0
	var wanting: Array = []   # employers who wanted a hand today and found nobody willing
	for p in _owners():
		if not (p and is_instance_valid(p)):
			continue
		var hands: Array = p.get_meta("hands", [])
		hands = hands.filter(func(h): return is_instance_valid(h) and all_households.has(h))
		if own and not p.has_meta("wage_offer"):
			p.set_meta("wage_offer", base)
		var wage: float = maxf(float(p.get_meta("wage_offer", base)), need) if own else base
		var cash_now: float = p.get_cash() + float(p.get_meta("invested_total", 0.0))
		var prev: float = float(p.get_meta("hand_prev_cash", cash_now))
		var falling: int = int(p.get_meta("hand_falling_days", 0))
		falling = falling + 1 if cash_now < prev - 0.01 else 0
		# Pay.
		var kept: Array = []
		for h in hands:
			if p.wallet and h.wallet and p.wallet.money >= wage:
				p.wallet.debit(wage)
				h.wallet.credit(wage)
				p.cashflow_today_expense += wage
				h.cashflow_today_income += wage
				paid += wage
				wages_paid_total += wage
				h.set_meta("boss_bond", mini(BOND_DAYS, int(h.get_meta("boss_bond", 0)) + 1))
				h.set_meta("wage_unpaid", 0)
				kept.append(h)
				_send_to_work(h, p)
			elif own:
				# Not paid today. They stay for now, think less of the boss, and quit if it goes on.
				var missed: int = int(h.get_meta("wage_unpaid", 0)) + 1
				h.set_meta("wage_unpaid", missed)
				h.set_meta("boss_bond", int(h.get_meta("boss_bond", 0)) / 2)
				if missed >= UNPAID_DAYS_TO_QUIT:
					wage_stats.quits_unpaid += 1
					_leave_job(p, h, day, "[HANDS] day=%d %s quits %s: not paid for %d days" % [day, h.name, p.name, missed], "Quit %s: not paid for %d days." % [p.name, missed])
				else:
					kept.append(h)
					_send_to_work(h, p)
			else:
				_let_go(p, h, day, "could not pay")
		hands = kept
		var raised: bool = false
		if not hands.is_empty() and falling >= FIRE_LOSS_DAYS:
			# A losing stretch: the owner cuts the wage if there is anything to cut, and only
			# then lets someone go.
			if own and wage > need + 0.005:
				wage = maxf(need, wage * (1.0 - step))
				wage_stats.cuts += 1
				if event_bus:
					event_bus.emit_log("[HANDS] day=%d %s cuts the wage to $%.2f a day (losing money)" % [day, p.name, wage])
				raised = true
			else:
				_let_go(p, hands.pop_back(), day, "losing money")
			falling = 0
		elif hands.size() >= staff_room(p):
			# Full: a shop that would take another hand if it had the room is extended instead.
			if Tuning.on("shop_extensions", true) and shop_level(p) < SHOP_MAX_LEVEL and p.get_cash() >= HIRE_CASH_DAYS * wage * (hands.size() + 1) \
					and not _overstocked(p) and _hand_value(p, hands.size()) > wage * 1.1:
				extend_shop.call(p, day)
		elif p.get_cash() >= HIRE_CASH_DAYS * wage * (hands.size() + 1) and not _overstocked(p):
			var value: float = _hand_value(p, hands.size())
			if value > wage * 1.1:
				var h = _willing_hand_for(p, wage, need)
				if h != null:
					hands.append(h)
					h.set_meta("employer", p)
					h.set_meta("boss_bond", 0)
					h.set_meta("wage_unpaid", 0)
					_send_to_work(h, p)
					# Paid from the first day: a cottager taken on today stops gardening today, and
					# with the first wage a day late a hungry one starved on the way to the job.
					if p.wallet and h.wallet and p.wallet.money >= wage:
						p.wallet.debit(wage)
						h.wallet.credit(wage)
						p.cashflow_today_expense += wage
						h.cashflow_today_income += wage
						paid += wage
						wages_paid_total += wage
					if event_bus:
						event_bus.emit_log("[HANDS] day=%d %s hired %s at $%.2f/day (extra output worth $%.2f)" % [day, p.name, h.name, wage, value])
					if h.has_method("log_event"):
						h.log_event("Taken on as a hand by %s at $%.2f a day." % [p.name, wage])
				else:
					open_jobs += 1   # work waiting and nobody willing: a newcomer may come for it
					if own:
						# Nobody will come for this wage: the owner offers more, but never more
						# than the hand would bring in.
						wanting.append(p)
						var top: float = value / 1.1
						if wage < top - 0.005:
							wage = minf(top, wage * (1.0 + step))
							wage_stats.raises += 1
						raised = true
		if own and not raised and not hands.is_empty() and idle_count > 0:
			# People in town lack work and nobody is being sought: the wage settles back toward
			# the floor, the least anyone works for.
			if wage > need + 0.005:
				wage = maxf(need, wage * (1.0 - step))
		if own:
			p.set_meta("wage_offer", wage)
		p.set_meta("hands", hands)
		p.set_meta("hand_prev_cash", p.get_cash() + float(p.get_meta("invested_total", 0.0)))
		p.set_meta("hand_falling_days", falling)
		employed += hands.size()
	if own:
		_better_offers(day, wanting)
	if open_jobs > 0:
		last_open_job_day = day
	if day % 5 == 0:
		var line: String = "[HANDS] day=%d employed=%d wage=$%.2f paid_today=$%.2f" % [day, employed, (paid / float(employed)) if employed > 0 else base, paid]
		print(line)
		if event_bus:
			event_bus.emit_log(line)


# ── Wages set by each owner (docs/WAGES.md) ──────────────────────────────────────

const UNPAID_DAYS_TO_QUIT: int = 2   # a hand not paid this many days running quits
const BOND_DAYS: int = 30            # paid days after which a hand is as attached to a boss as they get
const BOND_WORTH: float = 0.2        # what that attachment is worth to them, as a share of the wage
const WALK_SPEED: float = 100.0      # px a second: how fast people walk (the jobs' SPEED)
## A day's rent (Housing). Set by the village.
var rent_per_day: Callable = func() -> float: return 0.0
var wage_stats := {"raises": 0, "cuts": 0, "moves": 0, "quits_unpaid": 0}


## A living wage: what it costs someone to live for a day: a loaf, a log, the rent, and their
## clothes wearing out (a set at today's price over the days it lasts). It is also what a
## maker counts as their own keep when they price their goods (docs/CLOTHES.md).
func wage_floor() -> float:
	if market == null:
		return 5.0
	var clothes: float = market.good_price("clothes") / Clothing.life_days() if Clothing.on() and market.has_good("clothes") else 0.0
	return float(market.bread_price) + float(market.firewood_price) + float(rent_per_day.call()) + clothes


## What it costs `job`'s owner to live for a day (wage_floor), from their own town.
static func keep_of(job) -> float:
	var a = job.get("agent") if job != null else null
	var v = a.get("home_village_ref") if a != null and is_instance_valid(a) else null
	if v != null and is_instance_valid(v) and v.labor_market != null:
		return v.labor_market.wage_floor()
	var m = job.get("market") if job != null else null
	return float(m.bread_price) + float(m.firewood_price) if m != null else 5.0


## The wage `p` pays a hand today: their own offer, or the town's going rate (daily_wage)
## when owners do not set wages.
static func wage_of(p) -> float:
	if p == null or not is_instance_valid(p):
		return daily_wage(null)
	if Tuning.on("owner_wages", true) and p.has_meta("wage_offer"):
		return float(p.get_meta("wage_offer"))
	return daily_wage(p.get("market"))


## Where `p`'s hands spend the day: a field, the bakery or the lumber yard.
func _work_spot(p) -> Node2D:
	var pj = p.get("current_job") if p != null and is_instance_valid(p) else null
	if pj == null:
		return null
	if pj is FarmerJob:
		for f in pj.fields:
			if f != null and is_instance_valid(f) and f is Node2D:
				return f
		return pj.house_node
	if pj is BakerJob:
		return pj.bakery_location
	if pj is WoodworkerJob:
		return pj.yard_location
	if pj is SmithJob:
		return pj.smithy_location
	if pj is TailorJob:
		return pj.shop_location
	return null


## The share of the day `h` would spend walking to `p`'s shop and home again.
func commute_share(h, p) -> float:
	var j = h.get("current_job") if h != null and is_instance_valid(h) else null
	var home = j.get("home_location") if j != null else null
	var spot = _work_spot(p)
	if home == null or spot == null or not is_instance_valid(home) or not is_instance_valid(spot):
		return 0.0
	var secs: float = 2.0 * home.global_position.distance_to(spot.global_position) / WALK_SPEED
	return clampf(secs / Tuning.f("day_seconds", SimulationClock.TICK_SECONDS * 10.0), 0.0, 0.9)


## What a day working for `p` at `wage` is worth to `h`: the wage, less the share of the day
## lost walking there and back, plus (when they already work there) how they get on with the
## boss, which grows with every day paid on time and halves with every day unpaid.
func job_worth(h, p, wage: float) -> float:
	var w: float = wage * (1.0 - commute_share(h, p))
	if h.has_meta("employer") and h.get_meta("employer") == p:
		w += wage * BOND_WORTH * clampf(float(int(h.get_meta("boss_bond", 0))) / float(BOND_DAYS), 0.0, 1.0)
	return w


## Who `p` takes on: anyone free takes a job that pays the floor (wage_floor), and of them
## the owner picks the most skilled, then the poorest (_free_hand_for). The walk and the
## boss are weighed when a hand chooses between two employers (_better_offers), not when
## someone with no work is offered one. Tried the other way first, with the walk taken off
## the wage before anyone would accept: the farms, which are a long walk from every house,
## could hardly hire, and hired hands per town fell from 16 to 11.
func _willing_hand_for(p: Node, _wage: float, _need: float):
	return _free_hand_for(p)


## Hands change employer for a better offer: each employer who wanted a hand today and found
## nobody free takes the person working elsewhere who gains most by coming, if the new job is
## worth IMPROVEMENT_MARGIN more to them than the one they have (wage, walk and boss).
func _better_offers(day: int, wanting: Array) -> void:
	for p in wanting:
		if not is_instance_valid(p):
			continue
		var offer: float = wage_of(p)
		var best = null
		var best_from = null
		var best_gain: float = 0.0
		for e in _owners():
			if e == p or not (e and is_instance_valid(e)):
				continue
			for h in e.get_meta("hands", []):
				if not is_instance_valid(h):
					continue
				var now: float = job_worth(h, e, wage_of(e))
				var then: float = job_worth(h, p, offer)
				if then > now * (1.0 + IMPROVEMENT_MARGIN) and then - now > best_gain:
					best = h
					best_from = e
					best_gain = then - now
		if best == null:
			continue
		var old: Array = best_from.get_meta("hands", [])
		old.erase(best)
		best_from.set_meta("hands", old)
		var mine: Array = p.get_meta("hands", [])
		mine.append(best)
		p.set_meta("hands", mine)
		best.set_meta("employer", p)
		best.set_meta("boss_bond", 0)
		best.set_meta("wage_unpaid", 0)
		_send_to_work(best, p)
		wage_stats.moves += 1
		if event_bus:
			event_bus.emit_log("[HANDS] day=%d %s leaves %s for %s: $%.2f a day against $%.2f" % [day, best.name, best_from.name, p.name, offer, wage_of(best_from)])
		if best.has_method("log_event"):
			best.log_event("Left %s for %s: $%.2f a day against $%.2f." % [best_from.name, p.name, offer, wage_of(best_from)])


## A hand walks out (quits): the same tidy-up as being let go, with their own words.
func _leave_job(p: Node, h, _day: int, news: String, diary: String) -> void:
	if is_instance_valid(h):
		h.remove_meta("employer")
		_send_to_work(h, null)
		if h.has_method("log_event"):
			h.log_event(diary)
	if event_bus:
		event_bus.emit_log(news)


## Value per day of one more hand to `p`, who has `n` hands now, at today's prices: what the
## owner makes alone, times the share the next hand adds (hand_gain), times what a unit is
## worth. Bread is counted less its wheat and oven firewood.
func _hand_value(p: Node, n: int) -> float:
	var job = p.current_job
	if job == null or market == null:
		return 0.0
	var made: float = float(job.get_meta("output_ema", 0.0))
	# What the owner makes alone, times the next place, times how good the person who would
	# fill it is (the most skilled person free today).
	var extra: float = made / hand_mult(p) * hand_gain(p, n + 1) * hand_skill_factor(p, _free_hand_for(p))
	match str(p.current_role):
		"Farmer":
			return extra * market.wheat_price
		"Woodworker":
			return extra * market.firewood_bid()
		"Smith":
			return extra * maxf(0.0, market.good_bid("tools") - market.firewood_price / float(SmithJob.TOOLS_PER_LOG)) if market.has_good("tools") else 0.0
		"Tailor":
			return extra * maxf(0.0, market.good_bid("clothes") - float(TailorJob.FLAX_PER_SET) * market.good_price("flax")) if market.has_good("clothes") and market.has_good("flax") else 0.0
	return extra * maxf(0.0, market.bread_price - market.wheat_price * float(job.get_meta("wheat_per_bread", 2.0)) - market.firewood_price / 5.0)


## True when the employer's goods are already piling up at the market: more hands would only
## make more of what is not selling.
func _overstocked(p: Node) -> bool:
	if market == null:
		return false
	var band: float = 1.0 + float(market.TARGET_BAND_PCT)
	match p.current_role:
		"Farmer":
			return float(market.wheat) > float(market.wheat_target) * band
		"Baker":
			return float(market.bread) > float(market.bread_target) * band
		"Woodworker":
			return float(market.firewood) > float(market.firewood_target) * band
		"Smith":
			return market.has_good("tools") and float(market.good_stock("tools")) > float(market.good_target("tools")) * band
		"Tailor":
			return market.has_good("clothes") and float(market.good_stock("clothes")) > float(market.good_target("clothes")) * band
	return false


## Output with 0, 1 and 2 hired hands (dev mode can change the two steps).
static func hand_steps() -> Array:
	return [float(HAND_STEPS[0]), Tuning.f("hand_output_1", float(HAND_STEPS[1])), Tuning.f("hand_output_2", float(HAND_STEPS[2]))]


## What the first hired hand adds, as a share of what the owner makes alone. A job can say
## otherwise with hand_first_gain(): a farm hand works a field of their own (a whole share).
static func _first_gain(p: Node) -> float:
	var job = p.get("current_job") if p != null else null
	if job != null and job.has_method("hand_first_gain"):
		return float(job.hand_first_gain())
	var steps: Array = hand_steps()
	return float(steps[1]) - float(steps[0])


## What the k-th hired hand (1, 2, 3...) adds: less gain from each extra worker. The second
## adds a fixed share of the first (hand_steps), the third the same share of the second, and
## so on.
static func hand_gain(p: Node, k: int) -> float:
	if k <= 0:
		return 0.0
	var steps: Array = hand_steps()
	var first: float = float(steps[1]) - float(steps[0])
	var falloff: float = clampf((float(steps[2]) - float(steps[1])) / first, 0.0, 1.0) if first > 0.0 else 0.0
	return _first_gain(p) * pow(falloff, float(k - 1))


## Output multiplier of `p`'s shop with `n` hired hands of ordinary skill.
static func hand_mult_n(p: Node, n: int) -> float:
	var m: float = 1.0
	for k in range(1, n + 1):
		m += hand_gain(p, k)
	return m


## How good `h` is at `p`'s trade, as a share of a hand new to it (docs/SKILL.md): what a hand
## adds is the place they fill (hand_gain) times this. Someone new to the trade counts 1.0,
## so a new hand adds what a hand always added, and a master about a third more.
static func hand_skill_factor(p: Node, h) -> float:
	if not Tuning.on("worker_skill", true) or h == null or not is_instance_valid(h) or not h.has_method("skill_in"):
		return 1.0
	return SkillSet.factor(h.skill_in(str(p.current_role))) / SkillSet.factor(SkillSet.START)


## Output multiplier of `p`'s shop with the hands it has today. The most skilled hand counts
## in the first place, where a hand adds most.
static func hand_mult(p: Node) -> float:
	if p == null or not p.has_meta("hands"):
		return 1.0
	var factors: Array = []
	for h in p.get_meta("hands", []):
		if is_instance_valid(h):
			factors.append(hand_skill_factor(p, h))
	factors.sort()
	factors.reverse()
	var m: float = 1.0
	for k in range(factors.size()):
		m += hand_gain(p, k + 1) * float(factors[k])
	return m


## The size of `p`'s business for its upkeep: the people working in it (the owner and the
## hired hands). Upkeep is a plain coin cost that grows with the business (Anthony,
## 2026-11-13: "a bleed proportionate to the size of the business"); it was the same for a
## one-person shop and a shop of eight.
static func shop_size(p) -> float:
	if p == null or not is_instance_valid(p) or not Tuning.on("buy_from_makers", true):
		return 1.0
	return 1.0 + float(hands_of(p))


## ── The morning price: one step every maker goes through ────────────────────────────────
## A woodworker, baker, smith or tailor sets its lowest price once a day, in the morning after
## the day's hiring, and keeps it all day. It spreads the day's costs over what its crew will
## make today: how busy the shop has been lately (what it made each day, as a share of what that
## day's crew could make, kept as a running average) times what today's crew can make. So a
## hand taken on this morning counts in this morning's price, wage and work together.
##
## It used to be spread over the shop's own recent output. The morning a hand was taken on,
## their wage counted at once and their work only as the average caught up, so the price jumped
## overnight: 111 of 126 overnight jumps of 30% or more in a woodworker's lowest price, in eight
## towns over 1,500 days, fell on a hiring day, and most woodpile outages left followed one
## (2026-11-13). Farmers do not go through this: a farm hand works a field of their own that has
## to grow first, so a farm's extra wheat really does come later.

## The least share of a day's work a smith or a tailor spreads its costs over: a shop that sells
## little asks more for each, up to a point. (With no floor, a new smith or tailor had made
## nothing yet, asked about 20 coins each and never sold; and a tailor that sold few asked more,
## sold fewer and asked more again, up to 38 a set. Spread over 60% of a day's work, as the baker
## and the woodworker reckon, tools sold for 2 coins and a smith could live in only 60% of towns.)
const COSTING_FLOOR: float = 0.25


## The goods `job` spreads its costs over this morning: how busy it has been lately times
## `can_make`, what today's crew can make in a day, but never less than `least`. It also notes
## the crew it priced for, so that tonight what it made is measured against that crew.
static func costing_volume(job, can_make: float, least: float) -> float:
	job.set_meta("priced_for", can_make)
	return maxf(busy_share(job) * can_make, least)


## How busy `job` has been lately: a usual day's work as a share of what its crew could make
## (0 before its first day).
static func busy_share(job) -> float:
	return float(job.get_meta("busy_share", 0.0))


## At the end of a day: what `job` made today, as a share of what the crew it priced for this
## morning could make, goes into its running average.
static func note_day_made(job, made: float) -> void:
	var crew: float = float(job.get_meta("priced_for", 0.0))
	if crew <= 0.0:
		return
	var share: float = made / crew
	job.set_meta("busy_share", 0.3 * share + 0.7 * float(job.get_meta("busy_share", share)))


## A shop's level (docs/SHOP_LEVELS.md): 1 as built, up to SHOP_MAX_LEVEL after extensions.
static func shop_level(p: Node) -> int:
	if p == null or not p.has_meta("shop_level"):
		return 1
	return clampi(int(p.get_meta("shop_level", 1)), 1, SHOP_MAX_LEVEL)


## Hired hands `p`'s shop has room for: two as built, one more for each level.
static func staff_room(p: Node) -> int:
	return Tuning.i("max_hands_per_shop", MAX_HANDS) + shop_level(p) - 1


## A hand's daily wage in coins: one loaf plus one firewood at today's prices, times WAGE_MARKUP.
static func daily_wage(m) -> float:
	if m == null:
		return 5.9
	return (float(m.bread_price) + float(m.firewood_price)) * Tuning.f("wage_markup", WAGE_MARKUP)


## Every list of shop owners, one per trade, and everyone in them.
func _owner_groups() -> Array:
	return [all_farmers, all_bakers, all_woodworkers, all_smiths, all_tailors]


func _owners() -> Array:
	var out: Array = []
	for g in _owner_groups():
		out += g
	return out


# ── Tools (docs/SMITH.md) ─────────────────────────────────────────────────────────
## Tools are a real market. A shop with tools makes TOOL_BONUS more. A tool lasts one person
## TOOL_DAYS of work, so a bigger shop wears out more. A shop buys a tool only when it is
## worth more to it than it costs. A town with no smith has no tools and works as it always
## did; a smithy opens when what the town would spend on tools is a living.

const TOOL_BONUS: float = 0.10        # how much more a shop with tools makes
const TOOL_DAYS: float = 8.0          # a tool lasts one person this many days of work
const TOOL_STOCK_DAYS: float = 3.0    # days of tools a shop keeps by
const TOOL_KEEP_DAYS: float = 5.0     # days of bread and firewood a shop owner keeps before buying tools


## True when `p`'s shop is of a trade that uses tools (Recovery.USES_TOOLS) and tools are on.
static func uses_tools(p) -> bool:
	return p != null and is_instance_valid(p) and Tuning.on("tools", true) and Recovery.USES_TOOLS.has(str(p.current_role))


## What a shop makes with tools in hand, as a share of what it makes without.
static func tool_factor(p) -> float:
	if not uses_tools(p):
		return 1.0
	var inv = p.get("inv")
	return 1.0 + TOOL_BONUS if inv != null and inv.get_qty("tools") > 0 else 1.0


## Tools `p`'s shop wears out in a day: one for every TOOL_DAYS person-days worked there.
static func tools_per_day(p) -> float:
	return shop_size(p) / maxf(1.0, Tuning.f("tool_days", TOOL_DAYS))


## What one unit of what `p` makes is worth to them at today's prices (bread less its wheat
## and oven firewood).
func _unit_value(p) -> float:
	if market == null or p == null or not is_instance_valid(p):
		return 0.0
	match str(p.current_role):
		"Farmer":
			return float(market.wheat_price)
		"Woodworker":
			return market.firewood_bid()
		"Tailor":
			return market.good_bid("clothes") if market.has_good("clothes") else 0.0
		"Baker":
			var job = p.current_job
			return maxf(0.0, market.bread_price - market.wheat_price * float(job.get_meta("wheat_per_bread", 2.0) if job else 2.0) - market.firewood_price / 5.0)
	return 0.0


## What one tool is worth to `p`: the extra it lets one person make over the days it lasts.
func tool_worth(p) -> float:
	if not uses_tools(p) or p.current_job == null:
		return 0.0
	var made: float = float(p.current_job.get_meta("output_ema", 0.0))
	var with_tools: bool = p.inv != null and p.inv.get_qty("tools") > 0
	var per_person_without: float = made / shop_size(p) / (1.0 + TOOL_BONUS if with_tools else 1.0)
	return TOOL_BONUS * per_person_without * _unit_value(p) * Tuning.f("tool_days", TOOL_DAYS)


## True when `p` would buy tools at today's price.
func wants_tools(p) -> bool:
	return market != null and market.has_good("tools") and uses_tools(p) and market.good_price("tools") <= tool_worth(p)


## A shop's upkeep: the tools it wears out, at today's price. It grows with the shop and is
## paid to the smith. Nothing while the shop is not buying tools.
static func tool_cost_per_day(p) -> float:
	if not uses_tools(p) or p.get("inv") == null or p.inv.get_qty("tools") <= 0:
		return 0.0
	var m = p.get("market")
	return tools_per_day(p) * (m.good_price("tools") if m != null and m.has_good("tools") else 0.0)


## What the town's shops would spend on tools in a day, and how many they would buy. A shop
## pays today's price, or what a tool is worth to it if that is less (it will not pay more).
func tool_spending_per_day() -> Dictionary:
	var coins: float = 0.0
	var tools: float = 0.0
	if market == null or not market.has_good("tools"):
		return {"coins": 0.0, "tools": 0.0}
	var price: float = market.good_price("tools")
	for p in _owners():
		if p and is_instance_valid(p) and uses_tools(p):
			var worth: float = tool_worth(p)
			if worth > 0.0:
				coins += tools_per_day(p) * minf(price, worth)
				tools += tools_per_day(p)
	return {"coins": coins, "tools": tools}


## What a smithy would clear in a day: its share of what the town would spend on tools, less
## the forge's firewood and the smith's own keep (a loaf and a log). Zero is "no better and
## no worse than a garden plot". So a village too small to keep a smith does not get one.
func _smith_utility(ce) -> float:
	if ce == null or market == null or not market.has_good("tools") or not Tuning.on("tools", true):
		return -999.0
	var spend: Dictionary = tool_spending_per_day()
	var n: float = float(_live_count(all_smiths) + 1)
	var fuel: float = float(spend.tools) / n * float(market.firewood_price) / float(SmithJob.TOOLS_PER_LOG)
	return float(spend.coins) / n - fuel - (float(market.bread_price) + float(market.firewood_price)) - float(ce.last_risk) * 3.0


## What a tailor's shop would clear in a day: its share of what the town would spend on clothes
## at today's price, less the flax it takes and the tailor's own keep (a loaf and a log). Zero is "no better and no
## worse than a garden plot", so a town too small or too poor to keep a tailor does not get one.
func _tailor_utility(ce) -> float:
	if ce == null or market == null or clothing == null or not market.has_good("clothes") or not Clothing.on():
		return -999.0
	var spend: Dictionary = clothing.spending_per_day(market.good_price("clothes"))
	var n: float = float(_live_count(all_tailors) + 1)
	var flax: float = float(spend.sets) / n * float(TailorJob.FLAX_PER_SET) * (market.good_price("flax") if market.has_good("flax") else 0.0)
	return float(spend.coins) / n - flax - (float(market.bread_price) + float(market.firewood_price)) - float(ce.last_risk) * 3.0


## Daily: every shop with tools wears some out; a shop to which a tool is worth its price buys
## enough to keep TOOL_STOCK_DAYS by. The buyer pays whichever smith's stall they pick.
func _update_tools(_day: int) -> void:
	if market == null or not market.has_good("tools") or not Tuning.on("tools", true):
		return
	for p in _owners():
		if not (p and is_instance_valid(p)) or not uses_tools(p) or p.inv == null:
			continue
		if p.inv.get_qty("tools") > 0:
			var wear: float = float(p.get_meta("tool_wear", 0.0)) + tools_per_day(p)
			while wear >= 1.0 and p.inv.get_qty("tools") > 0:
				p.inv.remove("tools", 1)
				wear -= 1.0
			p.set_meta("tool_wear", minf(wear, 1.0))
		if not wants_tools(p):
			continue
		var want: int = maxi(1, ceili(tools_per_day(p) * TOOL_STOCK_DAYS))
		var have: int = p.inv.get_qty("tools")
		# Food and firewood come first: no tools are bought with the coins for the next few
		# days' keep.
		var keep: float = TOOL_KEEP_DAYS * (float(market.bread_price) + float(market.firewood_price))
		var can: int = int(floor(maxf(0.0, p.get_cash() - keep) / maxf(0.01, market.good_price("tools"))))
		if have < want and can > 0:
			market.buy_good(p, "tools", mini(want - have, can))


## Daily: every person burns one firewood. A hearth with none is a cold day; after
## COLD_DAYS_TO_LEAVE cold days in a row the person leaves town. The last of a trade stays.
func _update_firewood(day: int) -> void:
	var groups: Array = [all_households] + _owner_groups()
	var cold: int = 0
	for gi in groups.size():
		var group: Array = groups[gi]
		for a in group.duplicate():
			if not (a and is_instance_valid(a)) or a.inv == null:
				continue
			var have: int = a.inv.get_qty("firewood")
			if have > 0:
				# In a hard frost a hearth burns twice the wood (Shocks).
				# Someone decently dressed gets through a frost on one log; someone in rags does not
				# (docs/CLOTHES.md).
				a.inv.items["firewood"] = have - mini(have, 1 + (market.shock_extra_burn if market and not Clothing.dressed(a) else 0))
				a.set_meta("cold_days", 0)
				continue
			var n: int = int(a.get_meta("cold_days", 0)) + 1
			a.set_meta("cold_days", n)
			cold += 1
			if n < COLD_DAYS_TO_LEAVE or day < STARTUP_GRACE_DAYS or a.has_meta("merchant"):
				continue
			if gi > 0 and _live_count(group) <= 1:
				continue
			if event_bus:
				event_bus.emit_log("[FIREWOOD] day=%d %s leaving: %d days without firewood ($%.1f)" % [day, a.name, n, a.get_cash()])
			if gi > 0:
				_release_hands(a, "employer left")
			migrate_requested.emit(a, "no_firewood")
	if day % 5 == 0 and market != null:
		var line: String = "[FIREWOOD] day=%d price=$%.2f stock=%d/%d cold_hearths=%d woodworkers=%d" % [
			day, market.firewood_price, market.firewood, market.firewood_target, cold, _live_count(all_woodworkers)]
		print(line)
		if event_bus:
			event_bus.emit_log(line)


## How opening a wood yard looks to a household: what a woodworker has been clearing a day,
## plus a pull when firewood is short, less the same switching cost and risk the other trades use.
func _woodworker_utility(ce) -> float:
	if econ_stats == null or ce == null:
		return -999.0
	var n: int = _live_count(all_woodworkers) + 1   # the yards in town and this new one share the trade
	var avg: float = econ_stats.role_rolling_7d_avg("Woodworker") / float(n)
	return avg + firewood_scarcity_ema * 5.0 - 2.0 - float(ce.last_risk) * 3.0


## A hired hand spends the working day at the employer's workplace: a field, the bakery or
## the lumber yard (null: back to their own home).
func _send_to_work(h, p) -> void:
	if h == null or not is_instance_valid(h):
		return
	var j = h.get("current_job")
	if not (j is HouseholdJob):
		return
	var spot: Node2D = null
	var kind: String = ""
	if p != null and is_instance_valid(p):
		var pj = p.get("current_job")
		if pj is FarmerJob:
			for f in pj.fields:
				if f != null and is_instance_valid(f) and f is Node2D:
					spot = f
					break
			if spot == null:
				spot = pj.house_node
			kind = "Working in the fields"
		elif pj is BakerJob:
			spot = pj.bakery_location
			kind = "Working at the bakery"
		elif pj is WoodworkerJob:
			spot = pj.yard_location
			kind = "Cutting wood at the yard"
		elif pj is SmithJob:
			spot = pj.smithy_location
			kind = "Working at the smithy"
		elif pj is TailorJob:
			spot = pj.shop_location
			kind = "Sewing at the tailor's"
	j.set_work_site(spot, kind)


## True when work is waiting for a newcomer: an employer went short of hands in the last few
## days and nobody in town is without work.
func job_waiting(day: int) -> bool:
	return idle_count == 0 and day - last_open_job_day < OPEN_SHORT_DAYS


## True when `h` has no work today: no employer and not building a house.
func is_idle(h) -> bool:
	if h == null or not is_instance_valid(h):
		return false
	if h.has_meta("employer") and is_instance_valid(h.get_meta("employer")):
		return false
	return not h.has_meta("builds_house") and not h.has_meta("merchant")


## People with no work ("cottagers", counted in idle_count for the newcomer rules). They buy
## their bread and firewood at the market like everyone else, out of what they have saved.
## (Anthony, 2026-11-13: the garden plot is a place to live, not free food. Until then
## anyone with no work was handed bread and firewood every day, whatever was in their
## purse.) The old free plot is behind the dev switch "gardens", off.
func _update_cottagers(day: int) -> void:
	idle_count = 0
	for h in all_households.duplicate():
		if not (h and is_instance_valid(h)) or h.inv == null:
			continue
		var quiet_merchant: bool = h.has_meta("merchant") and int(h.get_meta("days_since_trade", 0)) >= 2
		var own_build: bool = h.has_meta("builds_house") and not h.has_meta("hired_builder") \
				and not (h.has_meta("employer") and is_instance_valid(h.get_meta("employer")))
		var idle: bool = is_idle(h)
		# No work, no bread in the house and not the price of a loaf left: they go to look for
		# work somewhere else, as anyone would, instead of sitting at home until they starve.
		if idle and day >= STARTUP_GRACE_DAYS and not Tuning.on("gardens", false) and market != null \
				and h.inv.get_qty("bread") == 0 and h.get_cash() < float(market.bread_price):
			if event_bus:
				event_bus.emit_log("[LaborMkt] %s leaving: no work and no money for bread ($%.1f)" % [h.name, h.get_cash()])
			migrate_requested.emit(h, "no_money")
			continue
		if idle:
			idle_count += 1
			h.set_meta("cottager", true)
		elif h.has_meta("cottager"):
			h.remove_meta("cottager")
		if not Tuning.on("gardens", false) or not (idle or own_build or quiet_merchant):
			if h.has_meta("garden"):
				h.remove_meta("garden")
			continue
		# Living off the plot: enough bread in the house to catch up a missed meal, deadwood
		# for the hearth, and no coins spent on either (HouseholdJob reads "garden"). A merchant
		# with no deal for two days lives this way too, so a quiet spell does not eat the
		# money they trade with (both merchants went broke and left town by day 42 before).
		h.set_meta("garden", true)
		if h.inv.get_qty("bread") < GARDEN_BREAD_KEEP:
			h.inv.add("bread", GARDEN_BREAD_KEEP - h.inv.get_qty("bread"))
		if h.inv.get_qty("bread") > 0:
			h.consecutive_failed_food_days = 0
			h.days_in_survival_mode = 0
		if h.inv.get_qty("firewood") < GATHERED_WOOD_KEEP:
			h.inv.items["firewood"] = h.inv.get_qty("firewood") + GATHERED_WOOD_PER_DAY + (market.shock_extra_burn if market else 0)


## Who `p` takes on: of the people free today, the one most skilled in `p`'s trade, and
## among equals the poorest (docs/SKILL.md).
func _free_hand_for(p: Node):
	if not Tuning.on("worker_skill", true) or p == null:
		return _free_hand()
	var trade: String = str(p.current_role)
	var best = null
	for h in all_households:
		if not (h and is_instance_valid(h)):
			continue
		if h.has_meta("employer") and is_instance_valid(h.get_meta("employer")):
			continue
		if h.has_meta("builds_house") or h.has_meta("merchant"):
			continue
		if best == null or h.skill_in(trade) > best.skill_in(trade) + 0.001 \
				or (absf(h.skill_in(trade) - best.skill_in(trade)) <= 0.001 and h.get_cash() < best.get_cash()):
			best = h
	return best


## The poorest household that has no employer.
func _free_hand():
	var best = null
	for h in all_households:
		if not (h and is_instance_valid(h)):
			continue
		if h.has_meta("employer") and is_instance_valid(h.get_meta("employer")):
			continue
		if h.has_meta("builds_house") or h.has_meta("merchant"):
			continue   # busy building a house (Housing), or a merchant
		if best == null or h.get_cash() < best.get_cash():
			best = h
	return best


func _let_go(p: Node, h, day: int, why: String) -> void:
	var hname: String = h.name if is_instance_valid(h) else "?"
	if is_instance_valid(h):
		h.remove_meta("employer")
		_send_to_work(h, null)
		if h.has_method("log_event"):
			h.log_event("Let go by %s (%s)." % [p.name, why])
	if event_bus:
		event_bus.emit_log("[HANDS] day=%d %s let %s go (%s)" % [day, p.name, hname, why])


func _release_hands(p: Node, why: String) -> void:
	for h in p.get_meta("hands", []):
		if is_instance_valid(h):
			h.remove_meta("employer")
			_send_to_work(h, null)
			if h.has_method("log_event"):
				h.log_event("Out of work: %s." % why)
	p.set_meta("hands", [])


## Hands an employer has today.
static func hands_of(p: Node) -> int:
	if p == null or not p.has_meta("hands"):
		return 0
	return (p.get_meta("hands", []) as Array).size()


# ─── Spawn suppression ────────────────────────────────────────────────────────

## Returns true when bread scarcity is high enough that new household spawns
## should be suppressed (no point growing population into a famine).
func should_suppress_spawn() -> bool:
	return bread_scarcity_ema >= SPAWN_SUPPRESS_SCARCITY or firewood_scarcity_ema >= SPAWN_SUPPRESS_SCARCITY


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
		"block_quota_farmer": 0,
		"block_quota_baker": 0,
		"block_other": 0,
		"examples_blocked": [],
		"examples_allowed": [],
	}


func _emit_eval_summary(day: int) -> void:
	var d: Dictionary = _eval_diag
	var summary: String = "[CAREER EVAL SUMMARY] day=%d evals=%d best(F=%d B=%d H=%d) allowed(F=%d B=%d H=%d) blocked_best(F=%d B=%d H=%d) blocked_reasons(land=%d cd=%d ten=%d food=%d cash=%d margin=%d other=%d) quota=%d entries(F=%d B=%d) blocked_quota(F=%d B=%d)" % [
		day, d.total,
		d.best_farmer, d.best_baker, d.best_stay,
		d.allowed_farmer, d.allowed_baker, d.allowed_stay,
		d.blocked_best_farmer, d.blocked_best_baker, d.blocked_best_stay,
		d.block_land_cap, d.block_cooldown, d.block_tenure,
		d.block_food, d.block_cash, d.block_margin, d.block_other,
		_current_quota, _entries_to_farmer_today, _entries_to_baker_today,
		_blocked_quota_farmer_today, _blocked_quota_baker_today]
	print(summary)
	if event_bus:
		event_bus.emit_log(summary)
	for ex in d.examples_blocked:
		var line: String = "[CAREER EXAMPLE BLOCKED] %s" % ex
		print(line)
		if event_bus:
			event_bus.emit_log(line)
	for ex in d.examples_allowed:
		var line: String = "[CAREER EXAMPLE ALLOWED] %s" % ex
		print(line)
		if event_bus:
			event_bus.emit_log(line)


func _emit_pop_snap(day: int) -> void:
	if day == _last_pop_snap_day:
		return
	_last_pop_snap_day = day
	var h: int = all_households.size()
	var f: int = all_farmers.size()
	var b: int = all_bakers.size()
	var t: int = h + f + b
	var snap: String = "[POP SNAP] day=%d households=%d farmers=%d bakers=%d total=%d" % [day, h, f, b, t]
	print(snap)
	if event_bus:
		event_bus.emit_log(snap)


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
		event_bus.emit_log(snap)


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
		event_bus.emit_log(line)
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
