extends Node
class_name LaborMarket

## LaborMarket: tracks EMA signals for occupational mobility and migration.
## Signals main.gd when agents should switch roles or leave the simulation.
## Operates on day_changed cadence - called once per game day from main.gd.

# ─── Signals ────────────────────────────────────────────────────────────────
signal migrate_requested(agent: Node, reason: String)
signal role_switch_requested(household: Node, new_role: String)

# ─── EMA constants ──────────────────────────────────────────────────────────
const EMA_ALPHA: float = 0.2              # Smoothing factor (higher = more reactive)
const ROLE_SWITCH_THRESHOLD: float = 0.3  # Scarcity EMA above this triggers role switch evaluation

# ─── Training / cooldown constants ──────────────────────────────────────────
const FARMER_TRAINING_DAYS: int = 2
const BAKER_TRAINING_DAYS: int = 3
const SWITCH_COOLDOWN_DAYS: int = 7  # Days before same household can switch again

# ─── Migration constants ──────────────────────────────────────────────────────
const MIGRATION_NO_FOOD_DAYS: int = 4      # Consecutive days without food → migrate
const MIGRATION_NEG_PROFIT_DAYS: int = 8  # Consecutive days negative cashflow → migrate
const MIGRATION_SURVIVAL_DAYS: int = 5    # Days in survival mode → migrate

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

	# Evaluate each household for role switch or migration
	# Iterate a duplicate to guard against array modification during iteration
	for h in all_households.duplicate():
		if h and is_instance_valid(h):
			_evaluate_household(h, day)

	# Evaluate producers for sustained-loss migration
	_evaluate_producer_migration(day)


# ─── Household evaluation ────────────────────────────────────────────────────

## Evaluate a single household: migration first, then role switch.
func _evaluate_household(h: Node, _day: int) -> void:
	# Tick down switch cooldown
	if h.switch_cooldown_days > 0:
		h.switch_cooldown_days -= 1

	# Track survival mode (any day with failed food = survival mode day)
	if h.consecutive_failed_food_days > 0:
		h.days_in_survival_mode += 1
	else:
		h.days_in_survival_mode = 0

	# ── Migration check (priority over role switch) ──────────────────────────
	if h.days_in_survival_mode >= MIGRATION_SURVIVAL_DAYS:
		if event_bus:
			event_bus.log("[LaborMkt] %s migrating: %d days in survival mode" % [h.name, h.days_in_survival_mode])
		migrate_requested.emit(h, "survival")
		return

	if h.consecutive_failed_food_days >= MIGRATION_NO_FOOD_DAYS:
		if event_bus:
			event_bus.log("[LaborMkt] %s migrating: %d consecutive days no food" % [h.name, h.consecutive_failed_food_days])
		migrate_requested.emit(h, "no_food")
		return

	# ── Role switch check (only if cooldown elapsed) ─────────────────────────
	if h.switch_cooldown_days > 0:
		return

	# Needs-driven triggers: scarcity OR repeated failed food trips
	var food_stress: bool = (h.consecutive_failed_food_days >= 2 or h.days_in_survival_mode >= 2)

	var want_farm: bool = (wheat_scarcity_ema >= ROLE_SWITCH_THRESHOLD or
		(food_stress and farmer_profit_ema >= baker_profit_ema))
	var want_bake: bool = (bread_scarcity_ema >= ROLE_SWITCH_THRESHOLD or
		(food_stress and baker_profit_ema >= farmer_profit_ema))

	# No switch needed
	if not want_farm and not want_bake:
		return

	# Tie-break: pick the scarcer good's producer
	var new_role: String
	if want_farm and want_bake:
		new_role = "farmer" if wheat_scarcity_ema >= bread_scarcity_ema else "baker"
	elif want_farm:
		new_role = "farmer"
	else:
		new_role = "baker"

	if event_bus:
		event_bus.log("[LaborMkt] %s → switching to %s (bread_scar=%.2f wheat_scar=%.2f)" % [
			h.name, new_role, bread_scarcity_ema, wheat_scarcity_ema])
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
