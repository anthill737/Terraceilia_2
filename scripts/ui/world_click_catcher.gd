extends Control
class_name WorldClickCatcher

## Full-screen click catcher for placement mode.
## Sits behind UI panels but captures all world clicks reliably.

var placement_controller = null
var admin_menu = null
var world_root = null  # Reference to world space node (should be Node2D)
var event_bus: EventBus = null


func _ready() -> void:
	# Ensure we receive GUI input
	mouse_filter = Control.MOUSE_FILTER_PASS
	
	# Fill entire viewport
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func set_references(pc, menu, world, bus: EventBus) -> void:
	"""Wire up all necessary references."""
	placement_controller = pc
	admin_menu = menu
	world_root = world
	event_bus = bus


func _gui_input(event: InputEvent) -> void:
	"""Capture clicks for placement mode."""
	# Debug: Log all mouse button events
	if event is InputEventMouseButton and event.pressed:
		if event_bus:
			var pc_status = "null" if placement_controller == null else ("active" if placement_controller.active else "inactive")
			event_bus.log("CATCHER DEBUG: MouseButton=%d placement_controller=%s" % [event.button_index, pc_status])
	
	# Only handle input when placement is active
	if placement_controller == null:
		if event is InputEventMouseButton and event.pressed and event_bus:
			event_bus.log("CATCHER ERROR: placement_controller is null")
		return
	
	if not placement_controller.active:
		return
	
	# Handle left-click for placement
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# Get screen mouse position
		var screen_pos = get_viewport().get_mouse_position()
		
		# Check if clicking over AdminMenu panel
		var over_menu = _is_over_admin_panel(screen_pos)
		
		# Log click for debugging
		if event_bus:
			event_bus.log("CLICK CATCHER: received click screen=(%.0f,%.0f) over_menu=%s active=%s type=%s" % 
				[screen_pos.x, screen_pos.y, str(over_menu), str(placement_controller.active), placement_controller.place_type])
		
		# Don't place if over menu
		if over_menu:
			return
		
		# Get world position
		# In simple 2D without camera transform, screen position == world position
		var world_pos = screen_pos
		
		# If world_root is a Node2D, use its get_global_mouse_position for accuracy
		if world_root and world_root.has_method("get_global_mouse_position"):
			world_pos = world_root.get_global_mouse_position()
		
		# Place entity at world position
		placement_controller.place_at(world_pos)
		
		# Mark event as handled
		accept_event()
	
	# Handle right-click or Esc to cancel
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if placement_controller:
			placement_controller.cancel()
		accept_event()
	elif event.is_action_pressed("ui_cancel"):
		if placement_controller:
			placement_controller.cancel()
		accept_event()


func _is_over_admin_panel(mouse_pos: Vector2) -> bool:
	"""Check if mouse position is inside AdminMenu panel."""
	if admin_menu == null or not admin_menu.visible:
		return false
	
	var panel_rect = admin_menu.get_panel_rect()
	return panel_rect.has_point(mouse_pos)
