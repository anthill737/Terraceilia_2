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
	timer.wait_time = tick_rate / speed_multiplier
	timer.autostart = true
	timer.timeout.connect(_on_timer_timeout)
	add_child(timer)


func _on_timer_timeout() -> void:
	tick += 1
	ticked.emit(tick)


func set_speed(multiplier: float) -> void:
	speed_multiplier = clamp(multiplier, MIN_SPEED, MAX_SPEED)
	timer.wait_time = tick_rate / speed_multiplier
	speed_changed.emit(speed_multiplier)


func increase_speed() -> void:
	var new_speed = speed_multiplier * 1.5
	set_speed(new_speed)


func decrease_speed() -> void:
	var new_speed = speed_multiplier / 1.5
	set_speed(new_speed)
