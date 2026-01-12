extends Node
class_name SimulationClock

signal ticked(tick: int)

var tick: int = 0
var tick_rate: float = 1.0

var timer: Timer


func _ready() -> void:
	timer = Timer.new()
	timer.wait_time = tick_rate
	timer.autostart = true
	timer.timeout.connect(_on_timer_timeout)
	add_child(timer)


func _on_timer_timeout() -> void:
	tick += 1
	ticked.emit(tick)
