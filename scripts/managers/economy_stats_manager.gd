extends Node
class_name EconomyStatsManager

## Tracks global rolling profit per profession (7-day).
## Read-only diagnostics — no effect on AI or economy rules.

var _cashflow_7d: Dictionary = {
	"Household": [],
	"Farmer":    [],
	"Baker":     [],
}

const _ROLE_GROUPS: Dictionary = {
	"Household": "households",
	"Farmer":    "farmers",
	"Baker":     "bakers",
}


func roll_daily() -> void:
	for role: String in _ROLE_GROUPS:
		var day_net: float = 0.0
		for pop: Node in get_tree().get_nodes_in_group(_ROLE_GROUPS[role]):
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
