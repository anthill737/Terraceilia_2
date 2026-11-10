extends Node
class_name SimulationClock

signal ticked(tick: int)
signal speed_changed(new_speed: float)

var tick: int = 0
## Game seconds in one tick. Ten ticks make a day, so a day is about 27 seconds at 1x and
## about 3 seconds at 10x.
##
## Ticks are counted on the physics clock, so people walk the same distance per tick at every
## speed. Before, ticks came from a wall-clock timer. At 10x on a busy machine each frame ran
## the most physics it is allowed (64 steps, 2.67 game seconds of walking) and gave one tick,
## and the whole economy was tuned and tested in that state. At 1x to 3x, or recording in
## fixed steps, people got 1 game second of walking per tick: they could not finish their
## rounds and the town starved. Now every speed gives the 2.67 the economy was built on.
const TICK_SECONDS: float = 64.0 / 24.0
var tick_rate: float = TICK_SECONDS
var speed_multiplier: float = 1.0
const MIN_SPEED: float = 0.1
const MAX_SPEED: float = 10.0
## Tests that step the villages by hand switch the clock off.
var running: bool = true
var _acc: float = 0.0


func _ready() -> void:
	set_speed(speed_multiplier)


func _physics_process(delta: float) -> void:
	if not running:
		return
	_acc += delta   # game time: the physics step already includes Engine.time_scale
	while _acc >= TICK_SECONDS:
		_acc -= TICK_SECONDS
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
