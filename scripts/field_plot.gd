extends Node
class_name FieldPlot

enum State { EMPTY, PLANTED }

var state: State = State.EMPTY
var ticks_to_mature: int = 0


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
		return {"wheat": 10, "seeds": 2}
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
