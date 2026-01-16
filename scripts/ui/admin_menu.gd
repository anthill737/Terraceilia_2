extends CanvasLayer

## AdminMenu - Player interactivity for spawning and assigning entities
## Toggle with F1 key

# UI References
@onready var panel: Panel = $Panel
@onready var world_click_catcher: WorldClickCatcher = $WorldClickCatcher
@onready var close_button: Button = $Panel/VBoxContainer/Header/CloseButton
@onready var farmer_count_label: Label = $Panel/VBoxContainer/Header/FarmerCount
@onready var baker_count_label: Label = $Panel/VBoxContainer/Header/BakerCount
@onready var field_count_label: Label = $Panel/VBoxContainer/Header/FieldCount

# Spawn buttons
@onready var spawn_farmer_button: Button = $Panel/VBoxContainer/SpawnSection/SpawnFarmer
@onready var spawn_baker_button: Button = $Panel/VBoxContainer/SpawnSection/SpawnBaker
@onready var spawn_field_button: Button = $Panel/VBoxContainer/SpawnSection/SpawnField
@onready var placement_status: Label = $Panel/VBoxContainer/SpawnSection/PlacementStatus

# Assignment controls
@onready var farmer_select: OptionButton = $Panel/VBoxContainer/AssignSection/FarmerSelect
@onready var field_select: OptionButton = $Panel/VBoxContainer/AssignSection/FieldSelect
@onready var assign_button: Button = $Panel/VBoxContainer/AssignSection/Buttons1/AssignButton
@onready var unassign_button: Button = $Panel/VBoxContainer/AssignSection/Buttons1/UnassignButton
@onready var assign_all_button: Button = $Panel/VBoxContainer/AssignSection/Buttons2/AssignAllButton
@onready var unassign_all_button: Button = $Panel/VBoxContainer/AssignSection/Buttons2/UnassignAllButton

# Info labels
@onready var farmer_info_label: Label = $Panel/VBoxContainer/InfoSection/FarmerInfo
@onready var field_info_label: Label = $Panel/VBoxContainer/InfoSection/FieldInfo

# Controller reference
var controller = null  # Main.gd node
var placement_controller = null  # PlacementController for click-to-place


var last_entity_counts := {"farmers": 0, "bakers": 0, "fields": 0}


func _ready() -> void:
	# Connect signals with null checks
	if close_button:
		close_button.pressed.connect(_on_close_pressed)
	else:
		push_error("AdminMenu: close_button is null")
	
	if spawn_farmer_button:
		spawn_farmer_button.pressed.connect(_on_spawn_farmer)
	else:
		push_error("AdminMenu: spawn_farmer_button is null")
		
	if spawn_baker_button:
		spawn_baker_button.pressed.connect(_on_spawn_baker)
	else:
		push_error("AdminMenu: spawn_baker_button is null")
		
	if spawn_field_button:
		spawn_field_button.pressed.connect(_on_spawn_field)
	else:
		push_error("AdminMenu: spawn_field_button is null")
		
	if assign_button:
		assign_button.pressed.connect(_on_assign_field)
	else:
		push_error("AdminMenu: assign_button is null")
		
	if unassign_button:
		unassign_button.pressed.connect(_on_unassign_field)
	else:
		push_error("AdminMenu: unassign_button is null")
		
	if assign_all_button:
		assign_all_button.pressed.connect(_on_assign_all)
	else:
		push_error("AdminMenu: assign_all_button is null")
		
	if unassign_all_button:
		unassign_all_button.pressed.connect(_on_unassign_all)
	else:
		push_error("AdminMenu: unassign_all_button is null")
		
	if farmer_select:
		farmer_select.item_selected.connect(_on_farmer_selected)
	else:
		push_error("AdminMenu: farmer_select is null")
		
	if field_select:
		field_select.item_selected.connect(_on_field_selected)
	else:
		push_error("AdminMenu: field_select is null")
	
	# Start hidden
	hide()
	set_process(true)


func set_controller(ctrl) -> void:
	"""Wire to main controller (main.gd)."""
	controller = ctrl
	
	# Wire WorldClickCatcher with world reference and event_bus (only if placement_controller is set)
	if world_click_catcher and controller and placement_controller:
		var event_bus = controller.get_node_or_null("EventBus")
		world_click_catcher.set_references(placement_controller, self, controller, event_bus)
		if event_bus:
			event_bus.log("UI: WorldClickCatcher wired from set_controller")


func set_placement_controller(pc) -> void:
	"""Wire to PlacementController for click-to-place spawning."""
	placement_controller = pc
	
	# Wire WorldClickCatcher if it exists
	if world_click_catcher and controller:
		var event_bus = controller.get_node_or_null("EventBus")
		world_click_catcher.set_references(placement_controller, self, controller, event_bus)
		if event_bus:
			event_bus.log("UI: WorldClickCatcher wired from set_placement_controller")


func get_panel_rect() -> Rect2:
	"""Return the global rect of the admin panel for click detection."""
	if panel:
		return panel.get_global_rect()
	return Rect2()


func _process(_delta: float) -> void:
	"""Monitor placement mode and auto-refresh on entity changes."""
	if not visible:
		return
	
	# Clear placement status when mode ends
	if placement_controller and not placement_controller.active:
		if placement_status and placement_status.text != "":
			placement_status.text = ""
	
	# Auto-refresh if entity counts changed
	if controller:
		var current_counts = {
			"farmers": controller.farmers.size(),
			"bakers": controller.bakers.size(),
			"fields": controller.fields.size()
		}
		if current_counts != last_entity_counts:
			last_entity_counts = current_counts
			refresh()


func toggle_visibility() -> void:
	"""Toggle menu visibility and refresh if opening."""
	if visible:
		hide()
		if controller and controller.event_bus:
			controller.event_bus.log("UI: AdminMenu closed")
	else:
		show()
		refresh()
		if controller and controller.event_bus:
			controller.event_bus.log("UI: AdminMenu opened")


func refresh() -> void:
	"""Refresh all dropdowns and counts."""
	if controller == null:
		return
	
	# Update counts
	farmer_count_label.text = "Farmers: %d" % controller.farmers.size()
	baker_count_label.text = "Bakers: %d" % controller.bakers.size()
	field_count_label.text = "Fields: %d" % controller.fields.size()
	
	# Refresh farmer dropdown
	farmer_select.clear()
	for farmer in controller.farmers:
		if farmer:
			farmer_select.add_item(farmer.name)
	
	# Refresh field dropdown
	field_select.clear()
	for field in controller.fields:
		if field:
			var label = field.name
			if field.assigned_farmer:
				label += " (-> %s)" % field.assigned_farmer.name
			else:
				label += " (unassigned)"
			field_select.add_item(label)
	
	# Update info
	_update_info()


func _update_info() -> void:
	"""Update info section based on current selection."""
	if controller == null:
		return
	
	# Farmer info
	var farmer_idx = farmer_select.selected
	if farmer_idx >= 0 and farmer_idx < controller.farmers.size():
		var farmer = controller.farmers[farmer_idx]
		var field_count = farmer.assigned_fields.size()
		var field_names = []
		for field in farmer.assigned_fields:
			if field:
				field_names.append(field.name)
		farmer_info_label.text = "Selected Farmer: %s\nAssigned Fields: %d\n%s" % [
			farmer.name,
			field_count,
			", ".join(field_names) if field_names.size() > 0 else "None"
		]
	else:
		farmer_info_label.text = "Selected Farmer: None"
	
	# Field info
	var field_idx = field_select.selected
	if field_idx >= 0 and field_idx < controller.fields.size():
		var field = controller.fields[field_idx]
		var farmer_name = field.assigned_farmer.name if field.assigned_farmer else "None"
		field_info_label.text = "Selected Field: %s\nAssigned to: %s" % [field.name, farmer_name]
	else:
		field_info_label.text = "Selected Field: None"


# ====================================================================
# SPAWN CALLBACKS - Arm placement mode for click-to-place
# ====================================================================

func _on_spawn_farmer() -> void:
	if placement_controller:
		placement_controller.arm("farmer")
		if placement_status:
			placement_status.text = "Placing: FARMER (click world, Esc to cancel)"


func _on_spawn_baker() -> void:
	if placement_controller:
		placement_controller.arm("baker")
		if placement_status:
			placement_status.text = "Placing: BAKER (click world, Esc to cancel)"


func _on_spawn_field() -> void:
	if placement_controller:
		placement_controller.arm("field")
		if placement_status:
			placement_status.text = "Placing: FIELD (click world, Esc to cancel)"


# ====================================================================
# ASSIGNMENT CALLBACKS
# ====================================================================

func _on_assign_field() -> void:
	if controller == null:
		return
	
	var farmer_idx = farmer_select.selected
	var field_idx = field_select.selected
	
	if controller.event_bus:
		controller.event_bus.log("UI DEBUG: Assign clicked - farmer_idx=%d field_idx=%d" % [farmer_idx, field_idx])
	
	if farmer_idx < 0 or farmer_idx >= controller.farmers.size():
		if controller.event_bus:
			controller.event_bus.log("UI ERROR: Invalid farmer index %d (have %d farmers)" % [farmer_idx, controller.farmers.size()])
		return
	if field_idx < 0 or field_idx >= controller.fields.size():
		if controller.event_bus:
			controller.event_bus.log("UI ERROR: Invalid field index %d (have %d fields)" % [field_idx, controller.fields.size()])
		return
	
	var farmer = controller.farmers[farmer_idx]
	var field = controller.fields[field_idx]
	
	if controller.event_bus:
		controller.event_bus.log("UI: Attempting to assign %s to %s" % [field.name, farmer.name])
	
	controller.assign_field_to_farmer(field, farmer)
	refresh()


func _on_unassign_field() -> void:
	if controller == null:
		return
	
	var field_idx = field_select.selected
	if field_idx < 0 or field_idx >= controller.fields.size():
		return
	
	var field = controller.fields[field_idx]
	controller.unassign_field(field)
	refresh()


func _on_assign_all() -> void:
	if controller == null:
		return
	
	var farmer_idx = farmer_select.selected
	if farmer_idx < 0 or farmer_idx >= controller.farmers.size():
		return
	
	var farmer = controller.farmers[farmer_idx]
	controller.assign_all_unassigned_to_farmer(farmer)
	refresh()


func _on_unassign_all() -> void:
	if controller == null:
		return
	
	var farmer_idx = farmer_select.selected
	if farmer_idx < 0 or farmer_idx >= controller.farmers.size():
		return
	
	var farmer = controller.farmers[farmer_idx]
	controller.unassign_all_from_farmer(farmer)
	refresh()


func _on_farmer_selected(_idx: int) -> void:
	_update_info()


func _on_field_selected(_idx: int) -> void:
	_update_info()


func _on_close_pressed() -> void:
	toggle_visibility()
