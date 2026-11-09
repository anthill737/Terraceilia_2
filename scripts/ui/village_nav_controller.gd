class_name VillageNavController
extends Node
## Village navigation controller.
## Owns the village selection state (current village, index, nav button highlights)
## and exposes navigate_next/prev for keyboard/shortcut cycling.
## Emits village_selected(village) whenever the active village changes;
## main.gd listens to this signal to update its own village var, inspector, and camera.

signal village_selected(village: Node)

# ── State ──────────────────────────────────────────────────────────────────────
var _world_node: Node    = null
var _villages: Array     = []
var _current_idx: int    = 0
var _nav_btns: Array[Button] = []


# ── Entry point ────────────────────────────────────────────────────────────────
## Initialise with the WorldManager node and load its village list.
## Call once from main._ready() after the World node is available.
func setup(world: Node) -> void:
	_world_node = world
	if world != null and world.get("villages") != null:
		set_village_list(world.villages)


# ── Village list ───────────────────────────────────────────────────────────────
## Replace the managed village list (e.g. after a world reload).
## Resets the current index to 0.
func set_village_list(villages: Array) -> void:
	_villages = villages
	_current_idx = 0


## Return the currently-selected village node, or null if the list is empty.
func get_current_village() -> Node:
	if _villages.is_empty() or _current_idx < 0 or _current_idx >= _villages.size():
		return null
	return _villages[_current_idx]


# ── Navigation ─────────────────────────────────────────────────────────────────
## Advance to the next village (wraps around). Emits village_selected.
func navigate_next() -> void:
	if _villages.is_empty():
		return
	_current_idx = (_current_idx + 1) % _villages.size()
	_refresh_highlights(_current_idx)
	village_selected.emit(get_current_village())


## Go back to the previous village (wraps around). Emits village_selected.
func navigate_prev() -> void:
	if _villages.is_empty():
		return
	_current_idx = (_current_idx - 1 + _villages.size()) % _villages.size()
	_refresh_highlights(_current_idx)
	village_selected.emit(get_current_village())


## Select a specific village by reference. Updates index and highlights.
## Emits village_selected regardless of whether the village changed.
func select_village(v: Node) -> void:
	if v == null or not is_instance_valid(v):
		return
	var idx: int = _villages.find(v)
	if idx >= 0:
		_current_idx = idx
		_refresh_highlights(idx)
	village_selected.emit(v)


# ── Toolbar button builder ─────────────────────────────────────────────────────
## Create one button per village and append them to hbox.
## Buttons call select_village(), which emits village_selected so callers
## (e.g. main.gd) can move the camera via the signal handler.
## Also appends the "World" zoom-out button using zoom_world_callable.
func build_nav_buttons(hbox: HBoxContainer, zoom_world_callable: Callable) -> void:
	_nav_btns.clear()
	for i in range(_villages.size()):
		var v: Node = _villages[i]
		if v == null:
			continue
		var vbtn := Button.new()
		var vdisplay: String = v.village_name if v.get("village_name") and v.village_name != "" else v.name
		vbtn.text = vdisplay
		vbtn.tooltip_text = "Center camera on %s" % vdisplay
		vbtn.custom_minimum_size = Vector2(80, 34)
		var captured_v: Node = v
		vbtn.pressed.connect(func(): select_village(captured_v))
		hbox.add_child(vbtn)
		_nav_btns.append(vbtn)

	var zoom_btn := Button.new()
	zoom_btn.text = "World"
	zoom_btn.tooltip_text = "Zoom out to see all villages"
	zoom_btn.custom_minimum_size = Vector2(70, 34)
	zoom_btn.pressed.connect(zoom_world_callable)
	hbox.add_child(zoom_btn)

	_refresh_highlights(_current_idx)


# ── Internal ───────────────────────────────────────────────────────────────────
func _refresh_highlights(active_idx: int) -> void:
	for i in range(_nav_btns.size()):
		var btn: Button = _nav_btns[i]
		if not is_instance_valid(btn):
			continue
		var s := StyleBoxFlat.new()
		if i == active_idx:
			s.bg_color     = Color(0.20, 0.35, 0.20, 0.95)
			s.border_color = Color(0.40, 1.00, 0.40, 1.00)
		else:
			s.bg_color     = Color(0.20, 0.20, 0.25, 0.90)
			s.border_color = Color(0.50, 0.50, 0.60, 0.80)
		s.set_border_width_all(2)
		s.set_corner_radius_all(4)
		s.set_content_margin_all(4)
		btn.add_theme_stylebox_override("normal", s)
