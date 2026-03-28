extends Node
class_name WorldManager

## World manager — owns and ticks all Village instances.
## Villages do not interact yet; this sets up the structure for future inter-village systems.

var villages: Array = []


func _ready() -> void:
	spawn_initial_villages()


func spawn_initial_villages() -> void:
	var village_scene: PackedScene = load("res://scenes/village/Village.tscn")
	if village_scene == null:
		push_error("WorldManager: could not load Village.tscn — ensure T3 is complete")
		return

	var v1 = village_scene.instantiate()
	v1.name = "Village1"
	add_child(v1)
	v1.initialize(12345, {})
	villages.append(v1)


func _process(delta: float) -> void:
	for v in villages:
		if v and is_instance_valid(v):
			v.tick(delta)
