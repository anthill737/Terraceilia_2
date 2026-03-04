extends Node
class_name PopulationManager

## Owns population tracking arrays, cap enforcement, and identity assignment.
## Spawn wiring stays in main.gd; this manager tracks who exists.

const MAX_TOTAL_POP: int = 50

var households: Array = []
var all_farmers: Array = []
var all_bakers: Array = []

var next_farmer_id: int = 2
var next_baker_id: int = 2
var next_household_id: int = 2
var _next_person_id: int = 1


func get_total_population() -> int:
	return households.size() + all_farmers.size() + all_bakers.size()


func count() -> int:
	return get_total_population()


func is_at_pop_cap() -> bool:
	return count() >= MAX_TOTAL_POP


func new_person_id() -> int:
	var id: int = _next_person_id
	_next_person_id += 1
	return id


func assign_identity(pop: Node) -> void:
	if not is_instance_valid(pop) or not pop.has_method("log_event"):
		return
	pop.person_id = new_person_id()
	pop.person_name = "Pop %d" % pop.person_id
	var role_str: String = ""
	if pop.get("current_role") != null and pop.current_role != "":
		role_str = pop.current_role
	else:
		role_str = pop.get_class()
	pop.log_event("Born: role=%s" % role_str)


func transfer_identity_data(to_pop: Node, pid: int, pname: String,
		events: Array, new_role: String,
		skill_f: float = 0.25, skill_b: float = 0.25) -> void:
	if not is_instance_valid(to_pop) or not to_pop.has_method("log_event"):
		return
	to_pop.person_id   = pid
	to_pop.person_name = pname
	to_pop.life_events = events.duplicate()
	if to_pop.get("skill_farmer") != null:
		to_pop.skill_farmer = skill_f
	if to_pop.get("skill_baker") != null:
		to_pop.skill_baker = skill_b
	if to_pop.get("days_in_role") != null:
		to_pop.days_in_role = 0
	to_pop.log_event("Role changed → %s" % new_role)


func register_household(h: Node) -> void:
	households.append(h)


func unregister_household(h: Node) -> void:
	var idx := households.find(h)
	if idx != -1:
		households.remove_at(idx)


func register_farmer(f: Node) -> void:
	all_farmers.append(f)


func unregister_farmer(f: Node) -> void:
	var idx := all_farmers.find(f)
	if idx != -1:
		all_farmers.remove_at(idx)


func register_baker(b: Node) -> void:
	all_bakers.append(b)


func unregister_baker(b: Node) -> void:
	var idx := all_bakers.find(b)
	if idx != -1:
		all_bakers.remove_at(idx)


func get_status_text() -> String:
	return "total=%d/%d (households=%d farmers=%d bakers=%d)" % [
		get_total_population(), MAX_TOTAL_POP,
		households.size(), all_farmers.size(), all_bakers.size()]
