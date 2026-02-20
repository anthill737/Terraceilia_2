extends Camera2D

const ZOOM_MIN: float = 0.5
const ZOOM_MAX: float = 2.5
const ZOOM_STEP: float = 0.1
const SMOOTH_SPEED: float = 8.0
const BOUNDS_PADDING: float = 400.0

var _target_zoom: float = 1.0
var _dragging: bool = false
var _auto_follow: bool = true
var _target_position: Vector2 = Vector2.ZERO
var _world_min: Vector2 = Vector2(-500, -500)
var _world_max: Vector2 = Vector2(2500, 1500)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_target_zoom = zoom.x
	_target_position = global_position


func _process(delta: float) -> void:
	zoom = Vector2.ONE * lerpf(zoom.x, _target_zoom, SMOOTH_SPEED * delta)
	if _auto_follow:
		global_position = global_position.lerp(_target_position, SMOOTH_SPEED * delta)
	global_position = global_position.clamp(_world_min, _world_max)
	_target_position = _target_position.clamp(_world_min, _world_max)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_target_zoom = clampf(_target_zoom + ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_target_zoom = clampf(_target_zoom - ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_MIDDLE or event.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = event.pressed
			if event.pressed:
				_auto_follow = false
			get_viewport().set_input_as_handled()

	if event is InputEventMouseMotion and _dragging:
		global_position -= event.relative / zoom.x
		_target_position = global_position
		get_viewport().set_input_as_handled()


func recenter(centroid: Vector2) -> void:
	_auto_follow = true
	_target_position = centroid


func update_centroid(centroid: Vector2) -> void:
	if _auto_follow:
		_target_position = centroid


func update_bounds(all_entities: Array) -> void:
	if all_entities.is_empty():
		return
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)
	for e in all_entities:
		if e and is_instance_valid(e) and e is Node2D:
			var pos: Vector2 = (e as Node2D).global_position
			min_pos = min_pos.min(pos)
			max_pos = max_pos.max(pos)
	_world_min = min_pos - Vector2(BOUNDS_PADDING, BOUNDS_PADDING)
	_world_max = max_pos + Vector2(BOUNDS_PADDING, BOUNDS_PADDING)
