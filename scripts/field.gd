extends Node
class_name Field

enum State { EMPTY, PLANTED, MATURE }

var state: State = State.EMPTY
var ticks_to_mature: int = 0

# PART 3: Farmer assignment (bidirectional)
var assigned_farmer: Node = null


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


# ====================================================================
# PART 3: FIELD-FARMER ASSIGNMENT (BIDIRECTIONAL)
# ====================================================================

func assign_to_farmer(farmer) -> void:
	"""Assign this field to a farmer (bidirectional update)."""
	# If already assigned to a different farmer, remove from old farmer first
	if assigned_farmer != null and assigned_farmer != farmer:
		if assigned_farmer.has_method("unassign_field"):
			assigned_farmer.unassign_field(self)
	
	# Set new assignment
	assigned_farmer = farmer
	
	# Update farmer's side
	if farmer and farmer.has_method("assign_field"):
		farmer.assign_field(self)


func unassign_farmer() -> void:
	"""Unassign this field from its current farmer (bidirectional update)."""
	if assigned_farmer != null:
		var old_farmer = assigned_farmer
		assigned_farmer = null
		
		# Update farmer's side
		if old_farmer and old_farmer.has_method("unassign_field"):
			old_farmer.unassign_field(self)

