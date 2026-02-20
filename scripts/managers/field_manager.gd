extends Node
class_name FieldManager

## Owns all field tracking, cap enforcement, and assignment bookkeeping.
## Actual scene-tree node creation stays in main.gd; this manager tracks data.

const MAX_FIELDS: int = 10

var all_fields: Array = []
var all_field_nodes: Array = []
var field_assignment_map: Dictionary = {}
var next_field_id: int = 3

var event_bus: EventBus = null


func bind(bus: EventBus) -> void:
	event_bus = bus


func is_at_cap() -> bool:
	return all_field_nodes.size() >= MAX_FIELDS


func get_count() -> int:
	return all_field_nodes.size()


func tick_all() -> void:
	for fp in all_fields:
		if fp and is_instance_valid(fp):
			fp.tick()


func register_field(field_node: Node2D, field_plot) -> void:
	all_fields.append(field_plot)
	all_field_nodes.append(field_node)
	field_assignment_map[field_node] = null


func unregister_field(field_node: Node2D) -> void:
	var fi := all_field_nodes.find(field_node)
	if fi != -1:
		all_field_nodes.remove_at(fi)
	var fai := all_fields.find(field_node)
	if fai != -1:
		all_fields.remove_at(fai)
	field_assignment_map.erase(field_node)


func assign_field(field_node: Node2D, new_farmer) -> void:
	var old_farmer = field_assignment_map.get(field_node, null)
	if old_farmer and is_instance_valid(old_farmer) and old_farmer != new_farmer:
		old_farmer.remove_field(field_node)
	field_assignment_map[field_node] = new_farmer
	if new_farmer and is_instance_valid(new_farmer):
		new_farmer.add_field(field_node, field_node)
	if event_bus:
		var fname: String = new_farmer.name if new_farmer else "(none)"
		event_bus.log("ASSIGNED: %s → %s" % [field_node.name, fname])


func release_fields_for_agent(agent: Node) -> void:
	for fn in all_field_nodes:
		if is_instance_valid(fn) and field_assignment_map.get(fn, null) == agent:
			field_assignment_map[fn] = null
			agent.remove_field(fn)


func get_status_text() -> String:
	return "fields=%d/%d" % [all_field_nodes.size(), MAX_FIELDS]
