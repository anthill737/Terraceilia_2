extends Node
class_name Calendar

var tick: int = 0
var ticks_per_day: int = 10
var day_index: int = 0

signal tick_changed(tick: int)
signal day_changed(day: int)


func set_tick(t: int) -> void:
	tick = t
	emit_signal("tick_changed", tick)
	
	var new_day: int = int(floor(float(tick) / float(ticks_per_day)))
	if new_day != day_index:
		day_index = new_day
		emit_signal("day_changed", day_index)
