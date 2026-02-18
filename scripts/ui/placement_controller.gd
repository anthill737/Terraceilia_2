extends Node
class_name PlacementController

## Handles click-to-place spawning for Farmers, Bakers, and Fields.
## Armed by AdminMenu buttons, spawns entities at world click position.

var active := false
var place_type := ""  # "farmer" | "baker" | "field"
var controller_ref = null  # main.gd reference
var ghost_node: Node2D = null  # Optional preview sprite

# UI reference for detecting clicks over UI
var admin_menu = null

# Event logging
var event_bus: EventBus = null


func _ready() -> void:
	# No longer handles input directly - WorldClickCatcher does that
	pass


func set_controller(controller) -> void:
	"""Set reference to main.gd controller."""
	controller_ref = controller
	if controller and controller.has_node("EventBus"):
		event_bus = controller.get_node("EventBus")


func set_admin_menu(menu) -> void:
	"""Set reference to AdminMenu for UI click detection."""
	admin_menu = menu


func arm(type: String) -> void:
	"""Arm placement mode for the given entity type."""
	if type not in ["farmer", "baker", "field"]:
		push_error("PlacementController: Invalid type '%s'" % type)
		return
	
	active = true
	place_type = type
	
	# Optional: Create ghost preview
	_create_ghost_preview(type)
	
	if event_bus:
		event_bus.log("PLACE MODE: %s armed (click world to place, Esc to cancel)" % type.capitalize())


func cancel() -> void:
	"""Cancel placement mode."""
	if not active:
		return
	
	active = false
	place_type = ""
	
	# Destroy ghost preview
	if ghost_node:
		ghost_node.queue_free()
		ghost_node = null
	
	if event_bus:
		event_bus.log("PLACE MODE: canceled")


func _create_ghost_preview(type: String) -> void:
	"""Create optional ghost preview sprite that follows cursor."""
	# TODO: Add visual preview that follows mouse
	# For now, skip preview - just use status text
	pass


func place_at(world_pos: Vector2) -> void:
	"""Place the armed entity at the given world position."""
	if not active:
		return
	
	if controller_ref == null:
		push_error("PlacementController: No controller reference set")
		return
	
	# Spawn entity
	_spawn_at_position(world_pos)


func _spawn_at_position(pos: Vector2) -> void:
	"""Spawn the armed entity type at the given world position."""
	if controller_ref == null:
		push_error("PlacementController: No controller reference set")
		return
	
	if event_bus:
		event_bus.log("PLACE: Spawning %s at (%.0f,%.0f)" % [place_type, pos.x, pos.y])
	
	match place_type:
		"farmer":
			if controller_ref.has_method("spawn_farmer_at"):
				controller_ref.spawn_farmer_at(pos)
		"baker":
			if controller_ref.has_method("spawn_baker_at"):
				controller_ref.spawn_baker_at(pos)
		"field":
			if controller_ref.has_method("spawn_field_at"):
				controller_ref.spawn_field_at(pos)
		_:
			push_error("PlacementController: Unknown place_type '%s'" % place_type)
