extends Node
class_name SimulationClock

signal ticked(tick: int)
signal speed_changed(new_speed: float)

var tick: int = 0
var tick_rate: float = 1.0
var speed_multiplier: float = 1.0
const MIN_SPEED: float = 0.1
const MAX_SPEED: float = 10.0

var timer: Timer


func _ready() -> void:
	timer = Timer.new()
	timer.wait_time = tick_rate
	timer.autostart = true
	timer.timeout.connect(_on_timer_timeout)
	add_child(timer)
	
	# Initialize engine time scale
	Engine.time_scale = speed_multiplier


func _on_timer_timeout() -> void:
	tick += 1
	ticked.emit(tick)


func set_speed(multiplier: float) -> void:
	speed_multiplier = clamp(multiplier, MIN_SPEED, MAX_SPEED)
	# Use Engine.time_scale to scale the entire game (physics, timers, animations)
	Engine.time_scale = speed_multiplier
	# Run physics more often when sped up, so one step never covers more game time than at
	# 2.5x (1/24 s). At 10x that is 240 steps a second, the same as the survival test. With a
	# fixed 60, a sped-up game took 10x longer steps than normal and towns fell apart.
	Engine.physics_ticks_per_second = clampi(roundi(24.0 * speed_multiplier), 60, 240)
	Engine.max_physics_steps_per_frame = 64
	speed_changed.emit(speed_multiplier)


func increase_speed() -> void:
	var new_speed = speed_multiplier * 1.5
	set_speed(new_speed)


func decrease_speed() -> void:
	var new_speed = speed_multiplier / 1.5
	set_speed(new_speed)
