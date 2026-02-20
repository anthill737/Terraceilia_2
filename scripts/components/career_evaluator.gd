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

# ─── Stored results (read by inspector / LaborMarket) ────────────────────────
var utility_farmer: float = 0.0
var utility_baker: float = 0.0
var utility_current: float = 0.0
var recommended_role: String = ""
var last_eval_day: int = -999


func evaluate(day: int, agent: Node, econ_stats: Node) -> void:
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

	# ── Compute U for each role ──────────────────────────────────────────
	utility_farmer = _compute_utility(
		income_farmer * sf_farmer,
		sk_farmer,
		_switch_cost(current_role, "Farmer", cooldown),
		risk if current_role != "Farmer" else 0.0
	)
	utility_baker = _compute_utility(
		income_baker * sf_baker,
		sk_baker,
		_switch_cost(current_role, "Baker", cooldown),
		risk if current_role != "Baker" else 0.0
	)

	match current_role:
		"Farmer":
			utility_current = utility_farmer
		"Baker":
			utility_current = utility_baker
		_:
			# Households have no production income of their own
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
