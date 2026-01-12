extends Node
class_name Field

enum State { EMPTY, PLANTED, MATURE }

var state: State = State.EMPTY
var ticks_to_mature: int = 0


func plant() -> void:
	state = State.PLANTED
	ticks_to_mature = 2


func tick() -> void:
	if state == State.PLANTED:
		ticks_to_mature -= 1
		if ticks_to_mature <= 0:
			state = State.MATURE


func harvest() -> void:
	state = State.EMPTY
	ticks_to_mature = 0


func is_empty() -> bool:
	return state == State.EMPTY


func is_mature() -> bool:
	return state == State.MATURE


func get_state_string() -> String:
	match state:
		State.EMPTY:
			return "EMPTY"
		State.PLANTED:
			return "PLANTED"
		State.MATURE:
			return "MATURE"
		_:
			return "UNKNOWN"
