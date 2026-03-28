extends Node
class_name EconomyStatsManager

## Tracks rolling profit per profession (7-day) for a single village.
## Read-only diagnostics — no effect on AI or economy rules.
##
## Call bind_agents() once after agents are initialized so that roll_daily()
## only reads this village's agents, not a global scene-tree query.

var _cashflow_7d: Dictionary = {
	"Household": [],
	"Farmer":    [],
	"Baker":     [],
}

var _farmers: Array = []
var _bakers: Array = []
var _households: Array = []


## Bind this stats manager to village-local agent arrays.
## Must be called before the first roll_daily().
func bind_agents(farmers: Array, bakers: Array, households: Array) -> void:
	_farmers = farmers
	_bakers = bakers
	_households = households


func roll_daily() -> void:
	var role_agents: Dictionary = {
		"Farmer":    _farmers,
		"Baker":     _bakers,
		"Household": _households,
	}
	for role: String in role_agents:
		var day_net: float = 0.0
		for pop: Node in role_agents[role]:
			if not is_instance_valid(pop):
				continue
			var arr: Array = pop.get("cashflow_7d") if pop.get("cashflow_7d") != null else []
			if not arr.is_empty():
				day_net += float(arr[-1])
		var hist: Array = _cashflow_7d[role]
		hist.append(day_net)
		if hist.size() > 7:
			hist.pop_front()
		_cashflow_7d[role] = hist


func role_rolling_7d_sum(role: String) -> float:
	var hist: Array = _cashflow_7d.get(role, [])
	var s: float = 0.0
	for v in hist:
		s += float(v)
	return s


func role_rolling_7d_avg(role: String) -> float:
	var hist: Array = _cashflow_7d.get(role, [])
	if hist.is_empty():
		return 0.0
	return role_rolling_7d_sum(role) / float(hist.size())
