extends Node
class_name CareerEvaluator

## Computes per-agent expected utility for each role on a weekly cadence.
## Results are stored for inspector display and consumed by LaborMarket
## for switching decisions.

# ─── Tunable weights ─────────────────────────────────────────────────────────
const WEIGHT_INCOME: float = 1.0
const WEIGHT_SKILL: float = 2.0
const WEIGHT_SWITCH_COST: float = 1.0
const WEIGHT_RISK: float = 3.0

const EVAL_INTERVAL_DAYS: int = 7

const CASH_LOW_THRESHOLD: float = 200.0
const FOOD_LOW_THRESHOLD: int = 2

const TRAINING_DAYS: Dictionary = {
	"Farmer": 2,
	"Baker": 3,
}

# ─── Scarcity bonus (pressure term, NOT selector) ───────────────────────────
const SCARCITY_WEIGHT: float = 1.0
const MAX_SCARCITY_BONUS: float = 1.0

# ─── Forward-looking scarcity expectation (Household entrants only) ──────────
var scarcity_expectation_weight_farmer: float = 2.0
var scarcity_expectation_weight_baker: float = 2.0

# ─── Stored results (read by inspector / LaborMarket) ────────────────────────
var utility_farmer: float = 0.0
var utility_baker: float = 0.0
var utility_current: float = 0.0
var recommended_role: String = ""
var last_eval_day: int = -999

# ─── Stored intermediates (instrumentation — no behavior impact) ─────────────
var last_income_farmer: float = 0.0
var last_income_baker: float = 0.0
var last_sf_farmer: float = 1.0
var last_sf_baker: float = 1.0
var last_risk: float = 0.0
var last_pop_avg: float = 0.0
var last_global_farmer_avg: float = 0.0
var last_global_baker_avg: float = 0.0
var last_switch_cost_farmer: float = 0.0
var last_switch_cost_baker: float = 0.0
var last_diag_expected_farmer: float = 0.0
var last_diag_expected_baker: float = 0.0
var last_diag_U_farmer: float = 0.0
var last_diag_U_baker: float = 0.0
var last_scarcity_bonus_farmer: float = 0.0
var last_scarcity_bonus_baker: float = 0.0
var last_household_scar_income_f: float = 0.0
var last_household_scar_income_b: float = 0.0


func evaluate(day: int, agent: Node, econ_stats: Node, bread_scarcity: float = 0.0, wheat_scarcity: float = 0.0) -> void:
	if day - last_eval_day < EVAL_INTERVAL_DAYS:
		return
	last_eval_day = day

	var current_role: String = agent.current_role
	var pop_avg: float = agent.cashflow_rolling_7d_avg()
	var sk_farmer: float = agent.skill_farmer
	var sk_baker: float = agent.skill_baker
	var cash: float = agent.get_cash()
	var bread: int = agent.inv.get_qty("bread") if agent.inv else 0
	var cooldown: int = agent.switch_cooldown_days

	# ── Expected income per role ─────────────────────────────────────────
	var income_farmer: float = _expected_income("Farmer", pop_avg, current_role, econ_stats)
	var income_baker: float = _expected_income("Baker", pop_avg, current_role, econ_stats)

	# ── Skill factors ────────────────────────────────────────────────────
	var sf_farmer: float = lerpf(0.8, 1.2, sk_farmer)
	var sf_baker: float = lerpf(0.8, 1.2, sk_baker)

	# ── Risk penalty (shared across non-current roles) ───────────────────
	var risk: float = 0.0
	if cash < CASH_LOW_THRESHOLD:
		risk += (CASH_LOW_THRESHOLD - cash) / CASH_LOW_THRESHOLD
	if bread < FOOD_LOW_THRESHOLD:
		risk += float(FOOD_LOW_THRESHOLD - bread) / float(FOOD_LOW_THRESHOLD)

	# ── Global averages (for diagnostic comparison) ──────────────────────
	var g_farmer: float = 0.0
	var g_baker: float = 0.0
	if econ_stats and econ_stats.has_method("role_rolling_7d_avg"):
		g_farmer = econ_stats.role_rolling_7d_avg("Farmer")
		g_baker = econ_stats.role_rolling_7d_avg("Baker")

	# ── Scarcity bonus (pressure term, capped) ──────────────────────────
	var scar_bonus_farmer: float = minf(wheat_scarcity * SCARCITY_WEIGHT, MAX_SCARCITY_BONUS)
	var scar_bonus_baker: float = minf(bread_scarcity * SCARCITY_WEIGHT, MAX_SCARCITY_BONUS)

	# ── Expected income (income slot for U) ─────────────────────────────
	var expected_f: float = income_farmer * sf_farmer
	var expected_b: float = income_baker * sf_baker

	# Forward-looking scarcity expectation for Household entrants only
	last_household_scar_income_f = 0.0
	last_household_scar_income_b = 0.0
	if current_role == "Household":
		last_household_scar_income_f = wheat_scarcity * scarcity_expectation_weight_farmer
		last_household_scar_income_b = bread_scarcity * scarcity_expectation_weight_baker
		expected_f += last_household_scar_income_f
		expected_b += last_household_scar_income_b

	# ── Store intermediates (instrumentation only) ───────────────────────
	last_income_farmer = income_farmer
	last_income_baker = income_baker
	last_sf_farmer = sf_farmer
	last_sf_baker = sf_baker
	last_risk = risk
	last_pop_avg = pop_avg
	last_global_farmer_avg = g_farmer
	last_global_baker_avg = g_baker
	last_switch_cost_farmer = _switch_cost(current_role, "Farmer", cooldown)
	last_switch_cost_baker = _switch_cost(current_role, "Baker", cooldown)
	last_diag_expected_farmer = expected_f
	last_diag_expected_baker = expected_b
	last_diag_U_farmer = expected_f + (sk_farmer * 2.0)
	last_diag_U_baker = expected_b + (sk_baker * 2.0)
	last_scarcity_bonus_farmer = scar_bonus_farmer
	last_scarcity_bonus_baker = scar_bonus_baker

	# ── Compute U for each role ──────────────────────────────────────────
	utility_farmer = _compute_utility(
		expected_f,
		sk_farmer,
		_switch_cost(current_role, "Farmer", cooldown),
		risk if current_role != "Farmer" else 0.0
	) + scar_bonus_farmer
	utility_baker = _compute_utility(
		expected_b,
		sk_baker,
		_switch_cost(current_role, "Baker", cooldown),
		risk if current_role != "Baker" else 0.0
	) + scar_bonus_baker

	match current_role:
		"Farmer":
			utility_current = utility_farmer
		"Baker":
			utility_current = utility_baker
		_:
			utility_current = _compute_utility(pop_avg, 0.0, 0.0, 0.0)

	# ── Recommended role (argmax) ────────────────────────────────────────
	if utility_farmer >= utility_baker:
		recommended_role = "Farmer"
	else:
		recommended_role = "Baker"

	# ── Life-event log ───────────────────────────────────────────────────
	var best_u: float = maxf(utility_farmer, utility_baker)
	if agent.has_method("log_event"):
		agent.log_event("Career eval: current=%s Uc=%.2f best=%s Ub=%.2f" % [
			current_role, utility_current, recommended_role, best_u])


func _compute_utility(income: float, skill: float, switch_cost: float, risk: float) -> float:
	return (
		WEIGHT_INCOME * income
		+ WEIGHT_SKILL * skill
		- WEIGHT_SWITCH_COST * switch_cost
		- WEIGHT_RISK * risk
	)


func _expected_income(role: String, pop_avg: float, current_role: String, econ_stats: Node) -> float:
	if current_role == role:
		return pop_avg
	# For non-current roles, use global average (we don't track per-role history).
	# Experience gives a small confidence boost via the skill_factor already.
	var global_avg: float = 0.0
	if econ_stats and econ_stats.has_method("role_rolling_7d_avg"):
		global_avg = econ_stats.role_rolling_7d_avg(role)
	return global_avg


func _switch_cost(current_role: String, target_role: String, cooldown: int) -> float:
	if current_role == target_role:
		return 0.0
	var training: int = TRAINING_DAYS.get(target_role, 3)
	return float(training + cooldown)


func get_eval_summary(agent: Node, scarcity_bread: float, scarcity_wheat: float) -> Dictionary:
	var bread: int = agent.inv.get_qty("bread") if agent.inv else 0
	var food_target: int = agent.food_reserve.min_reserve_units if agent.get("food_reserve") and agent.food_reserve else 3
	return {
		"day": last_eval_day,
		"agent_id": agent.person_id,
		"agent_name": agent.person_name if agent.person_name != "" else agent.name,
		"current_role": agent.current_role,
		"cash": agent.get_cash(),
		"hunger": "%d/%d" % [agent.hunger.hunger_days, agent.hunger.hunger_max_days] if agent.hunger else "?",
		"bread_reserve": bread,
		"food_target": food_target,
		"pop_cashflow_7d_avg": last_pop_avg,
		"role_profit_7d_avg_farmer": last_global_farmer_avg,
		"role_profit_7d_avg_baker": last_global_baker_avg,
		"skill_farmer": agent.skill_farmer,
		"skill_baker": agent.skill_baker,
		"sf_farmer": last_sf_farmer,
		"sf_baker": last_sf_baker,
		"income_farmer": last_income_farmer,
		"income_baker": last_income_baker,
		"switch_cost_farmer": last_switch_cost_farmer,
		"switch_cost_baker": last_switch_cost_baker,
		"risk": last_risk,
		"U_farmer": utility_farmer,
		"U_baker": utility_baker,
		"U_current": utility_current,
		"diag_expected_farmer": last_diag_expected_farmer,
		"diag_expected_baker": last_diag_expected_baker,
		"diag_U_farmer": last_diag_U_farmer,
		"diag_U_baker": last_diag_U_baker,
		"recommended_role": recommended_role,
		"scarcity_bread": scarcity_bread,
		"scarcity_wheat": scarcity_wheat,
		"scarcity_bonus_farmer": last_scarcity_bonus_farmer,
		"scarcity_bonus_baker": last_scarcity_bonus_baker,
		"household_scar_income_f": last_household_scar_income_f,
		"household_scar_income_b": last_household_scar_income_b,
	}
