extends Node
class_name RouteRunner

## Reusable movement component for agents.
## Handles walking toward targets, arrival detection, waiting, and timeout recovery.

signal arrived(target: Node2D)
signal wait_finished()
signal travel_timeout(target: Node2D)

var actor: CharacterBody2D = null
var speed: float = 100.0
var arrival_distance: float = 5.0
var target: Node2D = null
var is_waiting: bool = false
var wait_left: float = 0.0

# Timeout handling to prevent stuck agents
var max_travel_time: float = 30.0  # seconds before timeout
var travel_start_time: float = 0.0
var is_traveling: bool = false

# One-shot arrival guards
var travel_id: int = 0  # Unique ID for each travel
var active_travel_id: int = 0  # ID of current active travel
var arrival_handled: bool = false  # Prevents re-entrant arrival callbacks

# Logging support
var event_bus: EventBus = null
var current_tick: int = 0
var agent_name: String = ""


func bind(_actor: CharacterBody2D) -> void:
	actor = _actor


func bind_logging(_event_bus: EventBus, _agent_name: String) -> void:
	event_bus = _event_bus
	agent_name = _agent_name


func set_tick(tick: int) -> void:
	current_tick = tick


func set_target(t: Node2D) -> void:
	if t == null:
		return
	
	target = t
	is_waiting = false
	wait_left = 0.0
	is_traveling = true
	travel_start_time = Time.get_ticks_msec() / 1000.0
	
	# Assign new travel ID and reset arrival guard
	travel_id += 1
	active_travel_id = travel_id
	arrival_handled = false
	
	if event_bus:
		var from_pos = actor.global_position if actor else Vector2.ZERO
		var to_pos = t.global_position
		var distance = from_pos.distance_to(to_pos)
		event_bus.log("Tick %d: %s started travel to %s (distance: %.1f, travel_id=%d)" % [current_tick, agent_name, t.name, distance, active_travel_id])


func wait(seconds: float) -> void:
	is_waiting = true
	wait_left = max(0.0, seconds)
	if actor:
		actor.velocity = Vector2.ZERO


func stop() -> void:
	target = null
	is_waiting = false
	wait_left = 0.0
	is_traveling = false
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
	
	# Check for travel timeout
	if is_traveling:
		var elapsed = (Time.get_ticks_msec() / 1000.0) - travel_start_time
		if elapsed > max_travel_time:
			if event_bus:
				event_bus.log("Tick %d: %s travel TIMEOUT to %s (%.1fs elapsed, max %.1fs, travel_id=%d)" % [current_tick, agent_name, target.name, elapsed, max_travel_time, active_travel_id])
			var timed_out_target = target
			is_traveling = false
			arrival_handled = true  # Prevent arrival after timeout
			target = null
			actor.velocity = Vector2.ZERO
			actor.move_and_slide()
			emit_signal("travel_timeout", timed_out_target)
			return
	
	var to_target = target.global_position - actor.global_position
	if to_target.length() <= arrival_distance:
		# One-shot guard: prevent re-entrant arrival callbacks
		if arrival_handled:
			return  # Already handled this travel's arrival
		
		# Verify this is still the active travel
		if not is_traveling:
			return  # Travel already completed or cancelled
		
		actor.velocity = Vector2.ZERO
		actor.move_and_slide()
		
		# Log arrival
		if event_bus:
			var elapsed = (Time.get_ticks_msec() / 1000.0) - travel_start_time
			event_bus.log("Tick %d: %s arrived at %s (travel time: %.1fs, travel_id=%d)" % [current_tick, agent_name, target.name, elapsed, active_travel_id])
		
		# Clear travel state BEFORE emitting signal (prevents re-entry)
		var arrived_target = target
		is_traveling = false
		arrival_handled = true
		target = null  # Critical: clear target before signal emission
		
		# Now emit signal (handlers cannot trigger another arrival)
		emit_signal("arrived", arrived_target)
		return
	
	actor.velocity = to_target.normalized() * speed
	actor.move_and_slide()
