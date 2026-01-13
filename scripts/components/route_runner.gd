extends Node
class_name RouteRunner

## Reusable movement component for agents.
## Handles walking toward targets, arrival detection, and waiting.

signal arrived(target: Node2D)
signal wait_finished()

var actor: CharacterBody2D = null
var speed: float = 100.0
var arrival_distance: float = 5.0
var target: Node2D = null
var is_waiting: bool = false
var wait_left: float = 0.0


func bind(_actor: CharacterBody2D) -> void:
	actor = _actor


func set_target(t: Node2D) -> void:
	target = t
	is_waiting = false
	wait_left = 0.0


func wait(seconds: float) -> void:
	is_waiting = true
	wait_left = max(0.0, seconds)
	if actor:
		actor.velocity = Vector2.ZERO


func stop() -> void:
	target = null
	is_waiting = false
	wait_left = 0.0
	if actor:
		actor.velocity = Vector2.ZERO


func get_status_text() -> String:
	if target == null and not is_waiting:
		return "Idle"
	if is_waiting:
		return "Waiting"
	return "Walking to %s" % target.name


func _physics_process(delta: float) -> void:
	if actor == null:
		return
	
	if is_waiting:
		wait_left -= delta
		actor.velocity = Vector2.ZERO
		actor.move_and_slide()
		if wait_left <= 0.0:
			is_waiting = false
			emit_signal("wait_finished")
		return
	
	if target == null:
		actor.velocity = Vector2.ZERO
		actor.move_and_slide()
		return
	
	var to_target = target.global_position - actor.global_position
	if to_target.length() <= arrival_distance:
		actor.velocity = Vector2.ZERO
		actor.move_and_slide()
		emit_signal("arrived", target)
		return
	
	actor.velocity = to_target.normalized() * speed
	actor.move_and_slide()
