extends Node2D
class_name FieldPlot

enum State { EMPTY, PLANTED }

var state: State = State.EMPTY
var ticks_to_mature: int = 0

# PART 3: Farmer assignment (bidirectional)
var assigned_farmer: Node = null


func _ready() -> void:
	# Make field visible with a simple colored square
	queue_redraw()


func _draw() -> void:
	var soil := Color(0.40, 0.27, 0.15)
	draw_rect(Rect2(-17, -17, 34, 34), soil)
	for i in 5:
		draw_line(Vector2(-15, -13 + i * 6.5), Vector2(15, -13 + i * 6.5), soil.darkened(0.3), 1.5)
	if state == State.PLANTED:
		var ripe := ticks_to_mature <= 0
		var col := Color(0.92, 0.78, 0.30) if ripe else Color(0.35, 0.75, 0.30)
		var hgt := 7.0 if ripe else 3.5
		for i in 5:
			for k in 6:
				var p := Vector2(-13 + k * 5.2, -13 + i * 6.5)
				draw_line(p, p + Vector2(0, -hgt), col, 2.0)
	draw_rect(Rect2(-17, -17, 34, 34), Color(0.20, 0.13, 0.07), false, 2)


func plant() -> bool:
	if state == State.EMPTY:
		state = State.PLANTED
		ticks_to_mature = 2
		queue_redraw()  # Update visual
		return true
	return false


func tick() -> void:
	if state == State.PLANTED and ticks_to_mature > 0:
		ticks_to_mature -= 1
		queue_redraw()  # Update visual


func is_mature() -> bool:
	return state == State.PLANTED and ticks_to_mature == 0


func harvest() -> Dictionary:
	if is_mature():
		state = State.EMPTY
		queue_redraw()  # Update visual
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
