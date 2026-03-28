extends Node
class_name World

## World manager — owns and ticks all Village instances.
## Villages do not interact yet; this sets up the structure for future inter-village systems.

var villages: Array = []


func _ready() -> void:
	spawn_initial_villages()


func spawn_initial_villages() -> void:
	var village_scene: PackedScene = preload("res://scenes/village/Village.tscn")

	var v1 = village_scene.instantiate()
	add_child(v1)
	v1.initialize(1, {})
	villages.append(v1)

	var v2 = village_scene.instantiate()
	add_child(v2)
	v2.initialize(2, {})
	villages.append(v2)


func _process(delta: float) -> void:
	for v in villages:
		v.tick(delta)
