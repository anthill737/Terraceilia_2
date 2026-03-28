extends Node

# ── Village references ────────────────────────────────────────────────────────
## Currently-selected village — HUD, placement, and camera focus target.
var village: Village = null
## WorldManager node — exposes .villages array and helper methods.
var _world_node: Node = null
## 0-based index into _world_node.villages for the currently-selected village.
var _selected_village_idx: int = 0
# ── Simulation clock (world-level — controls Engine.time_scale) ───────────────
var clock: SimulationClock = null

# ── Camera ────────────────────────────────────────────────────────────────────
var _camera: Camera2D = null

# ── Placement mode ────────────────────────────────────────────────────────────
enum PlaceMode { NONE, FIELD, FARMER, BAKER, HOUSEHOLD }
var place_mode: PlaceMode = PlaceMode.NONE
var placement_cursor: ColorRect = null
var place_mode_label: Label = null
var spawn_info_label: Label = null

# ── Simulation failure state ──────────────────────────────────────────────────
var sim_failed: bool = false
var _sim_fail_banner: PanelContainer = null

# ── Economy HUD bar labels ────────────────────────────────────────────────────
var eco_sim_label: Label        = null
var eco_village_label: Label    = null
var eco_market_label: Label     = null
var eco_prosperity_label: Label = null
var eco_farmer_label: Label     = null
var eco_baker_label: Label      = null
## World-summary line shown below the per-village rows.
var eco_world_label: Label      = null
var _current_speed: float = 1.0

# ── Pause control ─────────────────────────────────────────────────────────────
var _is_paused: bool = false
var _pause_btn: Button = null
## Village navigation buttons in the toolbar (one per village).
var _village_nav_btns: Array[Button] = []

# ── Pop Inspector ─────────────────────────────────────────────────────────────
var selected_pop: Node = null
var pop_inspector: PopInspectorDock = null
const POP_PICK_RADIUS_WORLD: float = 16.0

# ── Event log ─────────────────────────────────────────────────────────────────
var event_log: RichTextLabel = null
var export_log_button: Button = null
var jump_to_bottom_button: Button = null
var sim_speed_label: Label = null
var log_lines: Array[String] = []
var log_buffer: Array[String] = []
var user_at_bottom: bool = true
const MAX_LOG_LINES: int = 200
const SCROLL_THRESHOLD: int = 50


func _ready() -> void:
	# Keep main node + UI always alive (responsive while paused)
	process_mode = Node.PROCESS_MODE_ALWAYS
	var ui_node := get_node_or_null("UI")
	if ui_node != null:
		ui_node.process_mode = Node.PROCESS_MODE_ALWAYS

	# ── Simulation clock (world-level) ──
	clock = SimulationClock.new()
	clock.name = "SimulationClock"
	add_child(clock)
	clock.process_mode = Node.PROCESS_MODE_PAUSABLE
	clock.speed_changed.connect(_on_speed_changed)

	# Wire clock ticks to World → forwarded to all villages
	_world_node = get_node_or_null("World")
	if _world_node and _world_node.has_method("on_simulation_tick"):
		clock.ticked.connect(_world_node.on_simulation_tick)
	else:
		push_error("Main: Could not connect clock to World.on_simulation_tick")

	# ── Camera ──
	var cam := Camera2D.new()
	cam.name = "WorldCamera"
	cam.set_script(preload("res://scripts/camera_controller.gd"))
	cam.position = Vector2(300, 400)
	cam.zoom = Vector2(1.5, 1.5)
	add_child(cam)
	cam.make_current()
	_camera = cam

	# ── Resolve village references (World._ready() has already run) ──
	# World node spawns all villages in its own _ready() via spawn_initial_villages().
	village = get_node_or_null("World/Village1") as Village
	if village == null:
		push_error("Main: Could not find World/Village1 — World.gd must spawn it in _ready()")

	# Wire every village's event_bus to the shared log panel.
	if _world_node and _world_node.get("villages") != null:
		for v in _world_node.villages:
			if v and is_instance_valid(v) and v.get("event_bus") != null and v.event_bus != null:
				if not v.event_bus.event_logged.is_connected(_on_event_logged):
					v.event_bus.event_logged.connect(_on_event_logged)

	# ── Build UI ──
	get_ui_labels()
	update_ui()
	_build_spawn_toolbar()
	_build_economy_bar()

	if village != null:
		var eb = village.event_bus
		if eb:
			eb.log("Tick 0: START")


func _process(_delta: float) -> void:
	update_ui()
	_update_spawn_info()
	_update_placement_cursor()
	_update_camera()


func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_pos


func _world_to_screen(world_pos: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform() * world_pos


func _update_camera() -> void:
	if _camera == null:
		return
	# Centroid tracks selected village only; bounds include all entities so the
	# camera can scroll to any village without restriction.
	var selected_positions: Array[Vector2] = []
	var all_entities: Array = []
	for group_name: String in ["farmers", "bakers", "households"]:
		for pop: Node in get_tree().get_nodes_in_group(group_name):
			if not is_instance_valid(pop):
				continue
			var pop2d := pop as Node2D
			if pop2d:
				all_entities.append(pop)
				if village != null and village.is_ancestor_of(pop):
					selected_positions.append(pop2d.global_position)
	for fn: Node in get_tree().get_nodes_in_group("fields"):
		if is_instance_valid(fn):
			all_entities.append(fn)
	if not selected_positions.is_empty():
		var centroid := Vector2.ZERO
		for p in selected_positions:
			centroid += p
		centroid /= float(selected_positions.size())
		_camera.update_centroid(centroid)
	if not all_entities.is_empty():
		_camera.update_bounds(all_entities)


func _input(event: InputEvent) -> void:
	if clock != null and not sim_failed:
		if event.is_action_pressed("speed_up"):
			clock.increase_speed()
			get_viewport().set_input_as_handled()
			return
		elif event.is_action_pressed("speed_down"):
			clock.decrease_speed()
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		if place_mode != PlaceMode.NONE:
			_cancel_placement()
			get_viewport().set_input_as_handled()
			return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_P and not event.ctrl_pressed and not event.alt_pressed:
			_toggle_pause()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_SPACE and not event.ctrl_pressed and not event.alt_pressed:
			_recenter_camera()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_ESCAPE and place_mode != PlaceMode.NONE:
			_cancel_placement()
			get_viewport().set_input_as_handled()
			return


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var screen_pos: Vector2 = event.position
		var world_pos: Vector2 = _screen_to_world(screen_pos)
		var r2: float = POP_PICK_RADIUS_WORLD * POP_PICK_RADIUS_WORLD

		var best_pop: Node = null
		var best_d2: float = INF
		for group_name: String in ["farmers", "bakers", "households"]:
			for pop: Node in get_tree().get_nodes_in_group(group_name):
				if not is_instance_valid(pop):
					continue
				var pop2d := pop as Node2D
				if pop2d == null:
					continue
				var d2: float = pop2d.global_position.distance_squared_to(world_pos)
				if d2 <= r2 and d2 < best_d2:
					best_d2 = d2
					best_pop = pop

		if best_pop != null:
			select_pop(best_pop)
			get_viewport().set_input_as_handled()
			return

		if place_mode != PlaceMode.NONE:
			_place_entity_at(world_pos)
			get_viewport().set_input_as_handled()


func _on_world_click(_event: InputEvent) -> void:
	pass  # Superseded by _input(); kept so old signal connections don't crash


func _on_speed_changed(new_speed: float) -> void:
	_current_speed = new_speed
	if sim_speed_label and not _is_paused:
		sim_speed_label.text = "Speed: %.1fx" % new_speed


func _recenter_camera() -> void:
	"""Recenter on the currently-selected village (Space shortcut)."""
	_center_on_village(village)


## Move the camera to the nominal centre of a specific village.
## Uses fly_to() so auto-follow is disabled — camera stays on the target village.
func _center_on_village(v: Village) -> void:
	if _camera == null:
		return
	if v == null or not is_instance_valid(v):
		_camera.fly_to(Vector2(400, 300), _camera.zoom.x)
		return
	# Use WorldManager helper when available; fall back to village global_position + offset.
	var center: Vector2
	if _world_node and _world_node.has_method("get_village_center"):
		center = _world_node.get_village_center(v)
	else:
		center = (v as Node2D).global_position + Vector2(400.0, 300.0)
	_camera.fly_to(center, _camera.zoom.x)
	# Switch the selected village so HUD + placement follow the camera destination.
	_select_village(v)


## Update button highlight so the active village button has a distinct border.
func _refresh_village_nav_highlights(active_idx: int) -> void:
	for i in range(_village_nav_btns.size()):
		var btn: Button = _village_nav_btns[i]
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


## Select a village as the active HUD + placement target.
func _select_village(v: Village) -> void:
	if v == null or not is_instance_valid(v):
		return
	village = v
	if _world_node and _world_node.get("villages") != null:
		var idx: int = _world_node.villages.find(v)
		if idx >= 0:
			_selected_village_idx = idx
			_refresh_village_nav_highlights(idx)


## Zoom camera out so both villages are visible simultaneously.
func _zoom_to_world_overview() -> void:
	if _camera == null or _world_node == null:
		return
	var villages_arr = _world_node.get("villages")
	if villages_arr == null or villages_arr.is_empty():
		return
	# Compute bounding rect across all village areas and zoom to fit it.
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)
	for v in villages_arr:
		if v and is_instance_valid(v):
			var origin: Vector2 = (v as Node2D).global_position
			min_pos = min_pos.min(origin)
			max_pos = max_pos.max(origin + Vector2(800.0, 600.0))
	# fly_to disables auto-follow so the camera holds the world overview position cleanly.
	_camera.fly_to((min_pos + max_pos) * 0.5, _camera.ZOOM_MIN)


func _toggle_pause() -> void:
	if sim_failed:
		return
	_is_paused = !_is_paused
	get_tree().paused = _is_paused

	if _pause_btn != null:
		if _is_paused:
			_pause_btn.text = "▶ Resume"
			var s := StyleBoxFlat.new()
			s.bg_color        = Color(0.28, 0.14, 0.02, 0.95)
			s.border_color    = Color(1.00, 0.60, 0.10, 0.95)
			s.set_border_width_all(2)
			s.set_corner_radius_all(4)
			s.set_content_margin_all(5)
			_pause_btn.add_theme_stylebox_override("normal", s)
			var sh := s.duplicate() as StyleBoxFlat
			sh.bg_color = Color(0.36, 0.20, 0.04, 1.0)
			_pause_btn.add_theme_stylebox_override("hover", sh)
		else:
			_pause_btn.text = "⏸ Pause"
			var s := StyleBoxFlat.new()
			s.bg_color        = Color(0.18, 0.18, 0.23, 0.92)
			s.border_color    = Color(0.82, 0.72, 0.28, 0.85)
			s.set_border_width_all(2)
			s.set_corner_radius_all(4)
			s.set_content_margin_all(5)
			_pause_btn.add_theme_stylebox_override("normal", s)
			var sh := s.duplicate() as StyleBoxFlat
			sh.bg_color = Color(0.26, 0.26, 0.32, 0.95)
			_pause_btn.add_theme_stylebox_override("hover", sh)

	if sim_speed_label != null:
		sim_speed_label.text = "PAUSED" if _is_paused else "Speed: %.1fx" % _current_speed


func _show_sim_fail_banner(day: int) -> void:
	if _sim_fail_banner != null:
		return
	var ui_node := get_node_or_null("UI")
	if ui_node == null:
		return

	_sim_fail_banner = PanelContainer.new()
	_sim_fail_banner.name = "SimStatusBanner"

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.55, 0.05, 0.05, 0.95)
	style.border_color = Color(1.0, 0.2, 0.2, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	_sim_fail_banner.add_theme_stylebox_override("panel", style)

	var label := Label.new()
	label.text = "TOWN EXTINCT — Simulation paused  (day %d)" % day
	label.add_theme_font_size_override("font_size", 28)
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.85))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sim_fail_banner.add_child(label)

	_sim_fail_banner.layout_mode = 1
	_sim_fail_banner.anchors_preset = Control.PRESET_CENTER_TOP
	_sim_fail_banner.anchor_left = 0.5
	_sim_fail_banner.anchor_right = 0.5
	_sim_fail_banner.anchor_top = 0.0
	_sim_fail_banner.offset_top = 60
	_sim_fail_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	ui_node.add_child(_sim_fail_banner)


func _on_event_logged(msg: String) -> void:
	log_lines.append(msg)
	log_buffer.append(msg)

	while log_lines.size() > MAX_LOG_LINES:
		log_lines.pop_front()

	if event_log:
		event_log.clear()
		for line in log_lines:
			event_log.append_text(line + "\n")
		if user_at_bottom:
			event_log.scroll_to_line(event_log.get_line_count())


func _on_log_scroll(_value: float) -> void:
	if event_log:
		var vscroll = event_log.get_v_scroll_bar()
		if vscroll:
			var max_scroll = vscroll.max_value - vscroll.page
			user_at_bottom = (max_scroll - vscroll.value) <= SCROLL_THRESHOLD


func _on_jump_to_bottom() -> void:
	user_at_bottom = true
	if event_log:
		event_log.scroll_to_line(event_log.get_line_count())


func export_log() -> void:
	print("export_log() called - buffer size: ", log_buffer.size())

	var log_snapshot = log_buffer.duplicate()

	var dir = DirAccess.open("user://")
	if not dir:
		print("ERROR: Could not open user:// directory")
		if event_log:
			event_log.append_text("[ERROR] Could not access user directory\n")
		return

	if not dir.dir_exists("logs"):
		var err = dir.make_dir("logs")
		if err != OK:
			if event_log:
				event_log.append_text("[ERROR] Failed to create logs directory\n")
			return

	var datetime = Time.get_datetime_dict_from_system()
	var filename = "economy_log_%04d-%02d-%02d_%02d-%02d-%02d.txt" % [
		datetime.year, datetime.month, datetime.day,
		datetime.hour, datetime.minute, datetime.second
	]
	var path = "user://logs/" + filename

	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		for line in log_snapshot:
			file.store_line(line)
		file.close()
		var abs_path = ProjectSettings.globalize_path(path)
		if event_log:
			event_log.append_text("[EXPORT] Log saved to: %s\n" % abs_path)
			event_log.append_text("[EXPORT] (%d lines written)\n" % log_snapshot.size())
	else:
		var err = FileAccess.get_open_error()
		if event_log:
			event_log.append_text("[ERROR] Failed to export log (Error: %d)\n" % err)


func get_ui_labels() -> void:
	var log_vbox = get_node_or_null("UI/HUDRoot/Layout/Sidebar/SidebarVBox/LogPanel/LogVBox")
	if log_vbox:
		event_log = log_vbox.get_node_or_null("EventLog")
		export_log_button = log_vbox.get_node_or_null("ExportLogButton")
		if export_log_button:
			export_log_button.pressed.connect(export_log)
		if log_vbox.has_node("JumpToBottomButton"):
			jump_to_bottom_button = log_vbox.get_node("JumpToBottomButton")
			jump_to_bottom_button.pressed.connect(_on_jump_to_bottom)

	if event_log:
		var vscroll = event_log.get_v_scroll_bar()
		if vscroll:
			vscroll.value_changed.connect(_on_log_scroll)

	pop_inspector = get_node_or_null("UI/PopInspectorDock") as PopInspectorDock
	if pop_inspector:
		# Pass village.econ_stats and field-count getter; both may be null until T4 fills initialize()
		var econ_stats = village.econ_stats if (village != null and village.get("econ_stats") != null) else null
		var max_f: int = village.field_mgr.MAX_FIELDS if (village != null and village.field_mgr != null) else 10
		pop_inspector.configure(econ_stats, max_f, Callable(self, "_inspector_field_count_for_dock"))
		if not pop_inspector.dismiss_requested.is_connected(_on_pop_inspector_dismiss):
			pop_inspector.dismiss_requested.connect(_on_pop_inspector_dismiss)


func update_ui() -> void:
	_update_eco_bar()
	update_inspector()


func _eco_cap_display(cap: int) -> String:
	if cap >= 1_000_000_000:
		return "∞"
	if cap >= 1_000_000:
		var m: float = float(cap) / 1_000_000.0
		return ("%.0fM" % m) if m < 100.0 else "∞"
	if cap >= 10_000:
		return "%dk" % int(round(float(cap) / 1000.0))
	return str(cap)


func _update_eco_bar() -> void:
	"""Refresh all six economy-bar section labels from village snapshot data."""
	if village == null or not is_instance_valid(village):
		return

	var snap: Dictionary = village.get_econ_snapshot()
	var pop: Dictionary  = village.get_population_summary()

	# SIM
	if eco_sim_label:
		eco_sim_label.text = "Day %d\n%.1f×" % [snap.get("day", 0), _current_speed]

	# VILLAGE — prefix with the selected village's display name so the player always
	# knows which village the HUD row describes.
	if eco_village_label:
		var vname: String = village.village_name if (village.get("village_name") as String) != "" else village.name
		eco_village_label.text = (
			"[%s]  Pop %d — households %d, farmers %d, bakers %d\nFields %d of %d"
			% [vname, pop.get("total", 0), pop.get("households", 0), pop.get("farmers", 0),
			   pop.get("bakers", 0), pop.get("fields", 0), pop.get("max_fields", 10)]
		)

	# MARKET
	if eco_market_label:
		var wc: String = _eco_cap_display(snap.get("wheat_cap", 999999999))
		var bc: String = _eco_cap_display(snap.get("bread_cap", 999999999))
		eco_market_label.text = (
			"Wheat %d / %s @ $%.2f\nBread %d / %s @ $%.2f" % [
				snap.get("wheat", 0), wc, snap.get("wheat_price", 0.0),
				snap.get("bread", 0), bc, snap.get("bread_price", 0.0)
			]
		)

	# PROSPERITY
	if eco_prosperity_label:
		eco_prosperity_label.text = (
			"Score %.2f\nWealth %.2f · Food %.2f · Hunger pressure %.2f" % [
				snap.get("prosperity_score", 0.0),
				snap.get("prosperity_wealth", 0.0),
				snap.get("prosperity_food", 0.0),
				snap.get("prosperity_starvation", 0.0)
			]
		)

	# FARMER baseline
	if eco_farmer_label:
		var fd: Dictionary = snap.get("baseline_farmer", {})
		if fd.is_empty():
			eco_farmer_label.text = "(none)"
		else:
			eco_farmer_label.text = (
				"Cash $%.0f · Seeds %d · Wheat %d · Bread %d · Hunger %d/%d\n%s · Inventory %d/%d"
				% [fd.get("cash", 0.0), fd.get("seeds", 0), fd.get("wheat", 0), fd.get("bread", 0),
				   fd.get("hunger_days", 0), fd.get("hunger_max", 5),
				   fd.get("status", ""), fd.get("inv_total", 0), fd.get("inv_max", 0)]
			)

	# WORLD summary — aggregated across all villages
	if eco_world_label and _world_node and _world_node.has_method("get_world_summary"):
		var ws: Dictionary = _world_node.get_world_summary()
		eco_world_label.text = (
			"World: %d villages · total pop %d (H %d · F %d · B %d) · fields %d"
			% [ws.get("village_count", 0), ws.get("total_pop", 0),
			   ws.get("total_households", 0), ws.get("total_farmers", 0),
			   ws.get("total_bakers", 0), ws.get("total_fields", 0)]
		)

	# BAKER baseline
	if eco_baker_label:
		var bd: Dictionary = snap.get("baseline_baker", {})
		if bd.is_empty():
			eco_baker_label.text = "(none)"
		else:
			eco_baker_label.text = (
				"Cash $%.0f · Wheat %d · Flour %d · Bread %d · Hunger %d/%d\n%s · Inventory %d/%d"
				% [bd.get("cash", 0.0), bd.get("wheat", 0), bd.get("flour", 0), bd.get("bread", 0),
				   bd.get("hunger_days", 0), bd.get("hunger_max", 5),
				   bd.get("status", ""), bd.get("inv_total", 0), bd.get("inv_max", 0)]
			)


# ── Pop Inspector ──────────────────────────────────────────────────────────────

func _inspector_field_count_for_dock() -> int:
	if village == null or not is_instance_valid(village):
		return 0
	return village.get_population_summary().get("fields", 0)


func _on_pop_inspector_dismiss() -> void:
	selected_pop = null


func select_pop(pop: Node) -> void:
	if not is_instance_valid(pop):
		return
	selected_pop = pop
	update_inspector()


func update_inspector() -> void:
	if pop_inspector == null:
		return
	if selected_pop == null or not is_instance_valid(selected_pop):
		selected_pop = null
	pop_inspector.refresh(selected_pop)


# ── Spawn info bar ─────────────────────────────────────────────────────────────

func _update_spawn_info() -> void:
	if spawn_info_label == null or village == null:
		return
	var pop: Dictionary = village.get_population_summary()
	spawn_info_label.text = "Fields: %d | Farmers: %d | Bakers: %d | Pop: %d" % [
		pop.get("fields", 0),
		pop.get("farmers", 0),
		pop.get("bakers", 0),
		pop.get("households", 0)
	]


# ── Toolbar ────────────────────────────────────────────────────────────────────

func _build_spawn_toolbar() -> void:
	var toolbar = PanelContainer.new()
	toolbar.name = "SpawnToolbar"

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.15, 0.92)
	style.border_color = Color(0.4, 0.4, 0.5, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	toolbar.add_theme_stylebox_override("panel", style)

	var vbox_outer = VBoxContainer.new()
	vbox_outer.add_theme_constant_override("separation", 4)
	toolbar.add_child(vbox_outer)

	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	vbox_outer.add_child(hbox)

	var title = Label.new()
	title.text = "BUILD"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.85, 0.85, 0.65))
	hbox.add_child(title)

	hbox.add_child(VSeparator.new())

	var field_btn = _create_toolbar_button("Field", Color(0.4, 0.3, 0.1), "Click to place a farm field")
	field_btn.pressed.connect(func(): _enter_placement_mode(PlaceMode.FIELD))
	hbox.add_child(field_btn)

	var farmer_btn = _create_toolbar_button("Farmer", Color(0.2, 0.8, 0.2), "Click to place a new farmer")
	farmer_btn.pressed.connect(func(): _enter_placement_mode(PlaceMode.FARMER))
	hbox.add_child(farmer_btn)

	var baker_btn = _create_toolbar_button("Baker", Color(0.8, 0.6, 0.2), "Click to place a new baker")
	baker_btn.pressed.connect(func(): _enter_placement_mode(PlaceMode.BAKER))
	hbox.add_child(baker_btn)

	var household_btn = _create_toolbar_button("Household", Color(0.8, 0.2, 0.8), "Click to place a new household")
	household_btn.pressed.connect(func(): _enter_placement_mode(PlaceMode.HOUSEHOLD))
	hbox.add_child(household_btn)

	hbox.add_child(VSeparator.new())

	var speed_down = Button.new()
	speed_down.text = "<<"
	speed_down.tooltip_text = "Slow down simulation"
	speed_down.pressed.connect(func(): clock.decrease_speed())
	hbox.add_child(speed_down)

	var speed_label = Label.new()
	speed_label.text = "Speed: 1.0x"
	speed_label.name = "ToolbarSpeedLabel"
	speed_label.add_theme_font_size_override("font_size", 18)
	hbox.add_child(speed_label)
	sim_speed_label = speed_label

	var speed_up = Button.new()
	speed_up.text = ">>"
	speed_up.tooltip_text = "Speed up simulation"
	speed_up.pressed.connect(func(): clock.increase_speed())
	hbox.add_child(speed_up)

	hbox.add_child(VSeparator.new())

	spawn_info_label = Label.new()
	spawn_info_label.text = ""
	spawn_info_label.add_theme_font_size_override("font_size", 18)
	spawn_info_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	hbox.add_child(spawn_info_label)
	_update_spawn_info()

	hbox.add_child(VSeparator.new())

	_pause_btn = Button.new()
	_pause_btn.text = "⏸ Pause"
	_pause_btn.tooltip_text = "Pause / resume simulation  [P]"
	_pause_btn.custom_minimum_size = Vector2(100, 34)
	var pb_style := StyleBoxFlat.new()
	pb_style.bg_color = Color(0.18, 0.18, 0.23, 0.92)
	pb_style.border_color = Color(0.82, 0.72, 0.28, 0.85)
	pb_style.set_border_width_all(2)
	pb_style.set_corner_radius_all(4)
	pb_style.set_content_margin_all(5)
	_pause_btn.add_theme_stylebox_override("normal", pb_style)
	var pb_hover := pb_style.duplicate() as StyleBoxFlat
	pb_hover.bg_color = Color(0.26, 0.26, 0.32, 0.95)
	_pause_btn.add_theme_stylebox_override("hover", pb_hover)
	_pause_btn.pressed.connect(_toggle_pause)
	hbox.add_child(_pause_btn)

	var center_btn := Button.new()
	center_btn.text = "Center"
	center_btn.tooltip_text = "Recenter camera on selected village  [Space]"
	center_btn.custom_minimum_size = Vector2(80, 34)
	center_btn.pressed.connect(_recenter_camera)
	hbox.add_child(center_btn)

	# ── Village navigation ──
	hbox.add_child(VSeparator.new())

	_village_nav_btns = []
	if _world_node and _world_node.get("villages") != null:
		for i in range(_world_node.villages.size()):
			var v: Village = _world_node.villages[i]
			if v == null:
				continue
			var vbtn := Button.new()
			var vdisplay: String = v.name
			vbtn.text = vdisplay
			vbtn.tooltip_text = "Center camera on %s" % vdisplay
			vbtn.custom_minimum_size = Vector2(80, 34)
			var captured_v: Village = v
			vbtn.pressed.connect(func(): _center_on_village(captured_v))
			hbox.add_child(vbtn)
			_village_nav_btns.append(vbtn)

	var zoom_world_btn := Button.new()
	zoom_world_btn.text = "World"
	zoom_world_btn.tooltip_text = "Zoom out to see all villages"
	zoom_world_btn.custom_minimum_size = Vector2(70, 34)
	zoom_world_btn.pressed.connect(_zoom_to_world_overview)
	hbox.add_child(zoom_world_btn)

	# Highlight the initially-selected village button.
	_refresh_village_nav_highlights(0)

	place_mode_label = Label.new()
	place_mode_label.text = ""
	place_mode_label.add_theme_font_size_override("font_size", 18)
	place_mode_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.5))
	vbox_outer.add_child(place_mode_label)

	var left_column = get_node("UI/HUDRoot/Layout/LeftColumn")
	left_column.add_child(toolbar)
	left_column.move_child(toolbar, 0)

	var world_spacer = get_node("UI/HUDRoot/Layout/LeftColumn/WorldSpacer")

	var click_receiver := Control.new()
	click_receiver.name = "WorldClickReceiver"
	click_receiver.set_anchors_preset(Control.PRESET_FULL_RECT)
	click_receiver.mouse_filter = Control.MOUSE_FILTER_IGNORE
	world_spacer.add_child(click_receiver)

	placement_cursor = ColorRect.new()
	placement_cursor.name = "PlacementCursor"
	placement_cursor.size = Vector2(30, 30)
	placement_cursor.position = Vector2(-100, -100)
	placement_cursor.color = Color(1, 1, 1, 0.4)
	placement_cursor.visible = false
	placement_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	world_spacer.add_child(placement_cursor)


func _build_economy_bar() -> void:
	var bar := PanelContainer.new()
	bar.name = "EcoBar"

	var bar_style := StyleBoxFlat.new()
	bar_style.bg_color = Color(0.07, 0.07, 0.10, 0.93)
	bar_style.border_color = Color(0.28, 0.28, 0.42, 0.85)
	bar_style.set_border_width_all(1)
	bar_style.set_corner_radius_all(5)
	bar_style.content_margin_left   = 10
	bar_style.content_margin_right  = 10
	bar_style.content_margin_top    = 6
	bar_style.content_margin_bottom = 6
	bar.add_theme_stylebox_override("panel", bar_style)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(outer)

	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 0)
	row1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_child(row1)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 0)
	row2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_child(row2)

	eco_sim_label        = _add_eco_section(row1, "SIM",        Color(0.65, 0.75, 1.00), true)
	eco_village_label    = _add_eco_section(row1, "VILLAGE",    Color(0.40, 0.90, 0.50), true)
	eco_market_label     = _add_eco_section(row1, "MARKET",     Color(0.95, 0.65, 0.25), true)
	eco_prosperity_label = _add_eco_section(row1, "PROSPERITY", Color(1.00, 0.85, 0.25), true)
	eco_farmer_label     = _add_eco_section(row2, "FARMER",     Color(0.20, 1.00, 0.20), true)
	eco_baker_label      = _add_eco_section(row2, "BAKER",      Color(1.00, 0.75, 0.20), true)

	# Row 3 — world-level summary (totals across all villages)
	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 0)
	row3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_child(row3)
	eco_world_label = _add_eco_section(row3, "WORLD", Color(0.55, 0.80, 1.00), true)

	var left_column := get_node("UI/HUDRoot/Layout/LeftColumn")
	left_column.add_child(bar)
	left_column.move_child(bar, 1)


func _add_eco_section(hbox: HBoxContainer, title_text: String, accent: Color, expand: bool) -> Label:
	if hbox.get_child_count() > 0:
		var sep := VSeparator.new()
		var sep_style := StyleBoxFlat.new()
		sep_style.bg_color = Color(0.30, 0.30, 0.45, 0.55)
		sep_style.content_margin_top    = 5
		sep_style.content_margin_bottom = 5
		sep.add_theme_stylebox_override("separator", sep_style)
		hbox.add_child(sep)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",  10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top",   3)
	margin.add_theme_constant_override("margin_bottom", 3)
	if expand:
		margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 1)
	margin.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = title_text
	title_lbl.add_theme_font_size_override("font_size", 14)
	title_lbl.add_theme_color_override("font_color", accent)
	title_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(title_lbl)

	var content_lbl := Label.new()
	content_lbl.text = "..."
	content_lbl.add_theme_font_size_override("font_size", 15)
	content_lbl.add_theme_color_override("font_color", Color(0.93, 0.93, 0.93))
	content_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content_lbl.custom_minimum_size = Vector2(32, 0)
	vbox.add_child(content_lbl)

	return content_lbl


func _create_toolbar_button(text: String, color: Color, tooltip: String) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.tooltip_text = tooltip
	btn.custom_minimum_size = Vector2(70, 30)

	var normal_style = StyleBoxFlat.new()
	normal_style.bg_color = Color(0.2, 0.2, 0.25, 0.9)
	normal_style.border_color = color
	normal_style.set_border_width_all(2)
	normal_style.set_corner_radius_all(4)
	normal_style.set_content_margin_all(4)
	btn.add_theme_stylebox_override("normal", normal_style)

	var hover_style = normal_style.duplicate()
	hover_style.bg_color = Color(0.3, 0.3, 0.35, 0.95)
	btn.add_theme_stylebox_override("hover", hover_style)

	var pressed_style = normal_style.duplicate()
	pressed_style.bg_color = color.lerp(Color.BLACK, 0.5)
	btn.add_theme_stylebox_override("pressed", pressed_style)

	return btn


# ── Placement mode ─────────────────────────────────────────────────────────────

func _enter_placement_mode(mode: PlaceMode) -> void:
	if place_mode == mode:
		_cancel_placement()
		return
	place_mode = mode
	if placement_cursor:
		placement_cursor.visible = true
		match mode:
			PlaceMode.FIELD:
				placement_cursor.color = Color(0.4, 0.3, 0.1, 0.5)
				placement_cursor.size = Vector2(30, 30)
			PlaceMode.FARMER:
				placement_cursor.color = Color(0.2, 1, 0.2, 0.5)
				placement_cursor.size = Vector2(20, 20)
			PlaceMode.BAKER:
				placement_cursor.color = Color(0.8, 0.6, 0.2, 0.5)
				placement_cursor.size = Vector2(20, 20)
			PlaceMode.HOUSEHOLD:
				placement_cursor.color = Color(0.8, 0.2, 0.8, 0.5)
				placement_cursor.size = Vector2(20, 20)
	_update_placement_label()


func _cancel_placement() -> void:
	place_mode = PlaceMode.NONE
	if placement_cursor:
		placement_cursor.visible = false
	_update_placement_label()


func _update_placement_cursor() -> void:
	if place_mode == PlaceMode.NONE or placement_cursor == null:
		return
	var mouse_pos = get_viewport().get_mouse_position()
	placement_cursor.position = mouse_pos - placement_cursor.size / 2.0


func _update_placement_label() -> void:
	if place_mode_label == null:
		return
	match place_mode:
		PlaceMode.NONE:
			place_mode_label.text = ""
		PlaceMode.FIELD:
			place_mode_label.text = "PLACING FIELD - Click world to place. Right-click or Esc to cancel."
		PlaceMode.FARMER:
			place_mode_label.text = "PLACING FARMER - Click world to place. Right-click or Esc to cancel."
		PlaceMode.BAKER:
			place_mode_label.text = "PLACING BAKER - Click world to place. Right-click or Esc to cancel."
		PlaceMode.HOUSEHOLD:
			place_mode_label.text = "PLACING HOUSEHOLD - Click world to place. Right-click or Esc to cancel."


func _place_entity_at(pos: Vector2) -> void:
	"""Delegate placement spawns to the active village."""
	if village == null:
		return
	match place_mode:
		PlaceMode.FIELD:
			village.spawn_field_at(pos)
		PlaceMode.FARMER:
			village.spawn_farmer_at(pos)
		PlaceMode.BAKER:
			village.spawn_baker_at(pos)
		PlaceMode.HOUSEHOLD:
			village.spawn_household_at(pos)
	# Stay in placement mode so the user can place multiple of the same type
