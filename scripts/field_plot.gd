extends Node
class_name FieldPlot

enum State { EMPTY, PLANTED }

var state: State = State.EMPTY
var ticks_to_mature: int = 0
var market_shocks = null  # Reference to shock system (MarketShocks instance)


func bind_shocks(shocks) -> void:
	market_shocks = shocks


func plant() -> bool:
	if state == State.EMPTY:
		state = State.PLANTED
		ticks_to_mature = 2
		return true
	return false


func tick() -> void:
	if state == State.PLANTED and ticks_to_mature > 0:
		ticks_to_mature -= 1


func is_mature() -> bool:
	return state == State.PLANTED and ticks_to_mature == 0


func harvest() -> Dictionary:
	if is_mature():
		state = State.EMPTY
		var base_wheat: int = 10
		var base_seeds: int = 2
		
		# Apply seasonal yield multiplier if available
		if market_shocks:
			var multiplier: float = market_shocks.get_wheat_yield_multiplier()
			base_wheat = int(round(float(base_wheat) * multiplier))
			# Seeds not affected by season
		
		return {"wheat": base_wheat, "seeds": base_seeds}
	else:
		return {"wheat": 0, "seeds": 0}


func get_state_string() -> String:
	match state:
		State.EMPTY:
			return "EMPTY"
		State.PLANTED:
			if ticks_to_mature > 0:
				return "PLANTED (t=%d)" % ticks_to_mature
			else:
				return "MATURE"
		_:
			return "UNKNOWN"
