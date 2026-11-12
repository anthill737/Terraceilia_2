class_name DevMenu
extends CanvasLayer
## Dev mode menu (F1, or the Dev button). Every input and the starting town on one panel
## (docs/DEV_MODE.md). "Apply now" changes the inputs in the running town; "Restart town"
## starts a new town with the starting-town values as well. Scenarios can be saved and loaded.

var _button: Button = null
var _panel: PanelContainer = null
var _readout: Label = null
var _status: Label = null
var _scenario_pick: OptionButton = null
var _name_edit: LineEdit = null
var _fields: Dictionary = {}      # "in:key" / "st:key" -> SpinBox or CheckBox
var _readout_left: float = 0.0
var _main: Node = null


func _ready() -> void:
	layer = 50
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


func setup(main_node: Node) -> void:
	_main = main_node


func is_open() -> bool:
	return _panel != null and _panel.visible


func toggle() -> void:
	if _panel == null:
		return
	_panel.visible = not _panel.visible
	if _panel.visible:
		_fill_from_tuning()
		_refresh_scenarios()
		_update_readout()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			toggle()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and is_open():
			toggle()
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not is_open():
		return
	_readout_left -= delta
	if _readout_left <= 0.0:
		_readout_left = 0.5
		_update_readout()


# ── Building the panel ────────────────────────────────────────────────────────

func _build() -> void:
	_button = Button.new()
	_button.name = "DevButton"
	_button.text = "Dev (F1)"
	_button.focus_mode = Control.FOCUS_NONE
	_button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_button.offset_left = -112.0
	_button.offset_top = -44.0
	_button.offset_right = -12.0
	_button.offset_bottom = -12.0
	_button.pressed.connect(toggle)
	add_child(_button)

	_panel = PanelContainer.new()
	_panel.name = "DevPanel"
	_panel.visible = false
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.offset_left = 30.0
	_panel.offset_top = 30.0
	_panel.offset_right = -30.0
	_panel.offset_bottom = -30.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.10, 0.13, 1.0)
	style.border_color = Color(0.75, 0.65, 0.35, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(16)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	_panel.add_child(root)

	var title := Label.new()
	title.text = "Dev mode: start any town, change any input"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.95, 0.85, 0.55))
	root.add_child(title)

	_readout = Label.new()
	_readout.name = "Readout"
	_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_readout.add_theme_font_size_override("font_size", 15)
	root.add_child(_readout)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var columns := HBoxContainer.new()
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 28)
	scroll.add_child(columns)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(left)
	var middle := VBoxContainer.new()
	middle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(middle)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(right)

	_heading(left, "Starting town (both towns; needs Restart)")
	for row in Tuning.START:
		_add_row(left, "st:" + str(row.k), row)
	var group: String = ""
	for row in Tuning.INPUTS:
		# Three columns: the starting town; time, production and money; everything else.
		var target: VBoxContainer = middle if str(row.g) in ["Time", "Production", "Money"] else right
		if str(row.g) != group:
			group = str(row.g)
			_heading(target, group)
		_add_row(target, "in:" + str(row.k), row)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	root.add_child(bar)

	_scenario_pick = OptionButton.new()
	_scenario_pick.name = "ScenarioPick"
	_scenario_pick.custom_minimum_size = Vector2(200, 0)
	bar.add_child(_scenario_pick)
	bar.add_child(_make_button("Load", _on_load))
	_name_edit = LineEdit.new()
	_name_edit.name = "ScenarioName"
	_name_edit.placeholder_text = "name to save as"
	_name_edit.custom_minimum_size = Vector2(180, 0)
	bar.add_child(_name_edit)
	bar.add_child(_make_button("Save", _on_save))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(gap)
	bar.add_child(_make_button("Back to normal", _on_reset))
	bar.add_child(_make_button("Apply now", _on_apply))
	bar.add_child(_make_button("Restart town", _on_restart))
	bar.add_child(_make_button("Close", toggle))

	_status = Label.new()
	_status.name = "Status"
	_status.add_theme_font_size_override("font_size", 14)
	_status.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	root.add_child(_status)
	_fill_from_tuning()


func _make_button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	return b


func _heading(parent: VBoxContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", Color(0.95, 0.85, 0.55))
	parent.add_child(l)


func _add_row(parent: VBoxContainer, id: String, row: Dictionary) -> void:
	var line := HBoxContainer.new()
	var label := Label.new()
	label.text = str(row.t)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 15)
	label.clip_text = true
	line.add_child(label)
	var d: Variant = row.d
	if typeof(d) == TYPE_BOOL:
		var box := CheckBox.new()
		box.button_pressed = bool(d)
		line.add_child(box)
		_fields[id] = box
	else:
		var spin := SpinBox.new()
		spin.min_value = float(row.get("lo", 0.0))
		spin.max_value = float(row.get("hi", 1000000.0))
		spin.step = float(row.get("st", 1.0)) if typeof(d) == TYPE_FLOAT else 1.0
		if typeof(d) == TYPE_FLOAT:
			spin.step = minf(spin.step, 0.01)
		spin.value = float(d)
		spin.custom_minimum_size = Vector2(118, 0)
		spin.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		line.add_child(spin)
		_fields[id] = spin
	parent.add_child(line)


# ── Values in and out ─────────────────────────────────────────────────────────

func _field_value(id: String) -> Variant:
	var c = _fields.get(id, null)
	if c is CheckBox:
		return (c as CheckBox).button_pressed
	if c is SpinBox:
		return (c as SpinBox).value
	return null


func _set_field(id: String, value: Variant) -> void:
	var c = _fields.get(id, null)
	if c is CheckBox:
		(c as CheckBox).button_pressed = bool(value)
	elif c is SpinBox:
		(c as SpinBox).value = float(value)


## Show what is set now (or the built-in value where nothing is set).
func _fill_from_tuning() -> void:
	for row in Tuning.INPUTS:
		var k: String = str(row.k)
		_set_field("in:" + k, Tuning.values.get(k, row.d))
	for row in Tuning.START:
		var k2: String = str(row.k)
		_set_field("st:" + k2, Tuning.start.get(k2, row.d))


static func _same(a: Variant, b: Variant) -> bool:
	if typeof(a) == TYPE_BOOL or typeof(b) == TYPE_BOOL:
		return bool(a) == bool(b)
	return absf(float(a) - float(b)) < 0.0005


## What the panel holds, keeping only what differs from the built-in values, so a town
## restarted with nothing changed is the normal game.
func collect() -> Dictionary:
	var inputs: Dictionary = {}
	for row in Tuning.INPUTS:
		var k: String = str(row.k)
		var v: Variant = _field_value("in:" + k)
		if v != null and not _same(v, row.d):
			inputs[k] = v
	var start: Dictionary = {}
	for row in Tuning.START:
		var k2: String = str(row.k)
		var v2: Variant = _field_value("st:" + k2)
		if v2 != null and not _same(v2, row.d):
			start[k2] = v2
	return {"inputs": inputs, "start": start}


func _store(with_start: bool) -> void:
	var got: Dictionary = collect()
	var per_village: Dictionary = Tuning.start_by_village.duplicate(true)
	var old_start: Dictionary = Tuning.start.duplicate()
	Tuning.clear()
	Tuning.load_dict({"inputs": got.inputs, "start": got.start if with_start else old_start})
	Tuning.start_by_village = per_village
	Tuning.source = "dev menu"


func _on_apply() -> void:
	_store(false)
	_say("Inputs applied to the running town. Starting-town values need Restart.")


func _on_restart() -> void:
	_store(true)
	restart()


## Start a new town with whatever Tuning holds now.
func restart() -> void:
	Tuning.keep_on_restart = true
	get_tree().paused = false
	get_tree().reload_current_scene()


func _on_reset() -> void:
	for row in Tuning.INPUTS:
		_set_field("in:" + str(row.k), row.d)
	for row in Tuning.START:
		_set_field("st:" + str(row.k), row.d)
	_say("Everything is back to the built-in values. Press Restart town to play the normal game.")


func _refresh_scenarios() -> void:
	if _scenario_pick == null:
		return
	_scenario_pick.clear()
	for s in Tuning.list_scenarios():
		_scenario_pick.add_item(str(s))


func _on_load() -> void:
	if _scenario_pick == null or _scenario_pick.item_count == 0 or _scenario_pick.selected < 0:
		_say("No scenario picked.")
		return
	var scenario: String = _scenario_pick.get_item_text(_scenario_pick.selected)
	Tuning.clear()
	if Tuning.load_file(scenario):
		_fill_from_tuning()
		_say("Loaded \"%s\". Press Restart town to start it.%s" % [scenario, "" if Tuning.errors.is_empty() else "  Problems: " + "; ".join(Tuning.errors)])
	else:
		_say("Could not load \"%s\": %s" % [scenario, "; ".join(Tuning.errors)])


func _on_save() -> void:
	var scenario: String = _name_edit.text.strip_edges() if _name_edit else ""
	if scenario == "":
		_say("Type a name first.")
		return
	_store(true)
	var path: String = Tuning.save_file(scenario)
	_refresh_scenarios()
	_say("Saved as \"%s\"." % scenario if path != "" else "Could not save.")


func _say(text: String) -> void:
	if _status:
		_status.text = text


# ── Readout ───────────────────────────────────────────────────────────────────

## One line per town: the levels and metrics a test wants to see at a glance.
static func town_line(v) -> String:
	if v == null or not is_instance_valid(v) or v.market == null:
		return ""
	var m = v.market
	var paid: int = 0
	var garden: int = 0
	var pockets: float = 0.0
	var others: int = 0
	var groups: Array = [v.all_farmers, v.all_bakers, v.all_woodworkers, v.households]
	for gi in groups.size():
		for a in groups[gi]:
			if a == null or not is_instance_valid(a):
				continue
			pockets += a.get_cash()
			if gi == 3:
				others += 1
				if a.has_meta("employer") and is_instance_valid(a.get_meta("employer")):
					paid += 1
				if a.has_meta("garden"):
					garden += 1
	var shops: int = v.all_farmers.size() + v.all_bakers.size() + v.all_woodworkers.size()
	var day: int = v.calendar.day_index if v.calendar else 0
	var pros: float = v.prosperity_meter.prosperity_score if v.prosperity_meter else 0.0
	return "%s, day %d: %d people (%d farmers, %d bakers, %d woodworkers, %d others; %d hired, %d providing for themselves). Market: %.0f coins, wheat %d at %.2f, bread %d at %.2f, wood %d at %.2f. Pockets: %.0f coins. Prosperity %.2f." % [
		str(v.village_name), day, shops + others, v.all_farmers.size(), v.all_bakers.size(), v.all_woodworkers.size(), others, paid, garden,
		m.money, m.wheat, m.wheat_price, m.bread, m.bread_price, m.firewood, m.firewood_price, pockets, pros]


## What is set, in plain words: "people 30, baker_loaves_per_day 10, village 2 people 12".
static func describe_set() -> String:
	var parts: Array = []
	for k in Tuning.start:
		parts.append("%s %s" % [str(k), str(Tuning.start[k])])
	for vid in Tuning.start_by_village:
		for k in Tuning.start_by_village[vid]:
			parts.append("village %d %s %s" % [int(vid), str(k), str(Tuning.start_by_village[vid][k])])
	for k in Tuning.values:
		parts.append("%s %s" % [str(k), str(Tuning.values[k])])
	return ", ".join(parts)


func _update_readout() -> void:
	if _readout == null:
		return
	var lines: Array = []
	var world: Node = _main.get_node_or_null("World") if _main else null
	if world != null and world.get("villages") != null:
		for v in world.villages:
			var line: String = town_line(v)
			if line != "":
				lines.append(line)
	var set_now: String = "Running on the built-in values." if Tuning.values.is_empty() and not Tuning.has_start() else "Set now (%s): %s" % [Tuning.source, describe_set()]
	lines.append(set_now)
	if not Tuning.errors.is_empty():
		lines.append("Problems: " + "; ".join(Tuning.errors))
	_readout.text = "\n".join(lines)
