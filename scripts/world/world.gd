extends Node
class_name WorldManager

## World manager — owns and ticks all Village instances.
## Villages are positioned at fixed world-space offsets; navigation helpers let
## main.gd move the camera and rebind the HUD per-village.

## Horizontal distance between consecutive village origins (world units).
## Increase to add more visual breathing room between villages.
const VILLAGE_SPACING: float = 2000.0

## Approximate centroid offset from a village's local origin to its visual centre.
const VILLAGE_CENTROID_OFFSET: Vector2 = Vector2(400.0, 300.0)

var villages: Array = []

## Index of the village currently in focus (drives camera + HUD).
var _focused_village_idx: int = 0

## Emitted when the player navigates to a different village.
## main.gd connects this to move the camera and rebind the economy HUD.
signal village_focused(idx: int)


func _ready() -> void:
	spawn_initial_villages()


func spawn_initial_villages() -> void:
	var village_scene: PackedScene = load("res://scenes/village/Village.tscn")
	if village_scene == null:
		push_error("WorldManager: could not load Village.tscn — ensure T3 is complete")
		return

	# Village1 — seed 12345, positioned at world origin
	var v1 = village_scene.instantiate()
	v1.name = "Village1"
	v1.position = Vector2(0.0, 0.0)
	add_child(v1)
	v1.initialize(12345, {})
	villages.append(v1)

	# Village2 — seed 67890, offset by VILLAGE_SPACING so it never overlaps Village1
	var v2 = village_scene.instantiate()
	v2.name = "Village2"
	v2.position = Vector2(VILLAGE_SPACING, 0.0)
	add_child(v2)
	v2.initialize(67890, {})
	villages.append(v2)


## Called by main.gd when SimulationClock emits ticked(tick).
## Forwards the integer tick to every village in fixed insertion order (deterministic).
func on_simulation_tick(tick: int) -> void:
	for v in villages:
		if v and is_instance_valid(v):
			v.receive_tick(tick)


## Navigate focus to village at index idx.
## Emits village_focused(idx) so main.gd can move the camera and rebind the HUD.
func focus_village(idx: int) -> void:
	if idx < 0 or idx >= villages.size():
		return
	_focused_village_idx = idx
	village_focused.emit(idx)


## Returns the currently-focused Village node, or null.
func get_focused_village() -> Node:
	if _focused_village_idx >= 0 and _focused_village_idx < villages.size():
		var v = villages[_focused_village_idx]
		if v and is_instance_valid(v):
			return v
	return null


## Returns the world-space camera target for village at idx.
## Uses a fixed centroid offset so the camera lands on the village's activity area.
func get_village_center_by_idx(idx: int) -> Vector2:
	if idx < 0 or idx >= villages.size():
		return Vector2.ZERO
	var v = villages[idx]
	if v and is_instance_valid(v) and v is Node2D:
		return (v as Node2D).global_position + VILLAGE_CENTROID_OFFSET
	return Vector2(float(idx) * VILLAGE_SPACING, 0.0) + VILLAGE_CENTROID_OFFSET


## Returns the world-space centre of a village node (legacy overload for direct node ref).
## Used by the camera navigation buttons.
func get_village_center(v: Node) -> Vector2:
	if v == null or not is_instance_valid(v):
		return Vector2.ZERO
	return (v as Node2D).global_position + VILLAGE_CENTROID_OFFSET


## Returns the world-space centre across all villages — useful for a zoom-out view.
func get_world_center() -> Vector2:
	if villages.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for i in range(villages.size()):
		sum += get_village_center_by_idx(i)
	return sum / float(villages.size())


## Returns the total world width spanned by all villages.
## main.gd uses this to pick a zoom level for the zoom-out view.
func get_world_span() -> float:
	if villages.size() <= 1:
		return VILLAGE_SPACING
	return float(villages.size() - 1) * VILLAGE_SPACING + VILLAGE_CENTROID_OFFSET.x * 2.0


## Returns a Dictionary summing population and field counts across all villages.
## Used by the HUD world-summary line.
func get_world_summary() -> Dictionary:
	var out := {
		"village_count":    villages.size(),
		"total_pop":        0,
		"total_farmers":    0,
		"total_bakers":     0,
		"total_households": 0,
		"total_fields":     0,
	}
	for v in villages:
		if not (v and is_instance_valid(v)):
			continue
		var pop: Dictionary = v.get_population_summary()
		out["total_pop"]        += pop.get("total",      0)
		out["total_farmers"]    += pop.get("farmers",    0)
		out["total_bakers"]     += pop.get("bakers",     0)
		out["total_households"] += pop.get("households", 0)
		out["total_fields"]     += pop.get("fields",     0)
	return out


## Returns the combined population across all villages (convenience shorthand).
func get_world_population() -> int:
	var total: int = 0
	for v in villages:
		if v and is_instance_valid(v) and v.has_method("get_population_summary"):
			total += v.get_population_summary().get("total", 0)
	return total
