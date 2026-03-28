extends Camera2D

const ZOOM_MIN: float = 0.2   # Low enough to show two villages side-by-side
const ZOOM_MAX: float = 2.5
const ZOOM_STEP: float = 0.1
const SMOOTH_SPEED: float = 8.0
const BOUNDS_PADDING: float = 400.0

var _target_zoom: float = 1.0
var _dragging: bool = false
## False by default — camera moves only on explicit button press (fly_to / pan_to).
## Set to true only when legacy single-village follow is intentionally enabled.
var _auto_follow: bool = false
var _target_position: Vector2 = Vector2.ZERO
# Default bounds span two villages (Village2 ends at ~x=2800); updated at runtime.
var _world_min: Vector2 = Vector2(-500, -500)
var _world_max: Vector2 = Vector2(4500, 1500)


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
			if _is_mouse_over_world_view_for_wheel():
				_target_zoom = clampf(_target_zoom + ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
				get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			if _is_mouse_over_world_view_for_wheel():
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


func _is_mouse_over_world_view_for_wheel() -> bool:
	"""True when the wheel should zoom the world: over the main map area, not HUD text/menus."""
	var hc: Control = get_viewport().gui_get_hovered_control()
	if hc == null:
		return true
	var n: Node = hc
	while n != null:
		if n.name == "WorldSpacer":
			return true
		n = n.get_parent()
	return false


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


## Smoothly navigate to a specific world position at a given zoom level.
## Disables auto-follow so the camera stays put until the user or another call moves it.
func fly_to(target_pos: Vector2, target_zoom: float) -> void:
	_auto_follow = false
	_target_position = target_pos
	_target_zoom = clampf(target_zoom, ZOOM_MIN, ZOOM_MAX)


## Zoom out to a level that shows the full world (both villages).
## Called by _zoom_to_world_overview() in main.gd.
func set_overview_zoom() -> void:
	_target_zoom = ZOOM_MIN


## Zoom to fit a world-space rect in the viewport.
## Moves the camera to the rect centre and picks a zoom level that shows the full rect.
func zoom_to_fit_rect(world_min: Vector2, world_max: Vector2) -> void:
	var vp_size := get_viewport().get_visible_rect().size
	var rect_size := world_max - world_min
	if rect_size.x <= 0.0 or rect_size.y <= 0.0 or vp_size.x <= 0.0 or vp_size.y <= 0.0:
		return
	var pad := BOUNDS_PADDING
	var zoom_x := vp_size.x / (rect_size.x + pad * 2.0)
	var zoom_y := vp_size.y / (rect_size.y + pad * 2.0)
	fly_to((world_min + world_max) * 0.5, min(zoom_x, zoom_y))
