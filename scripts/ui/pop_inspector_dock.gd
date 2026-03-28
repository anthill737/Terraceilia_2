extends PanelContainer
class_name PopInspectorDock
## Character inspector: one dock (record + tab bar). Owns layout, drag, scroll sync, and tab content.
## Main passes economy/field callables; simulation data comes from the selected pop's `get_inspector_data()`.

signal dismiss_requested

const DOCK_SIZE_FULL := Vector2(560, 392)
const DOCK_SIZE_BAR := Vector2(560, 108)
const STAT_BASE := "DockStack/RecordBlock/StatCol"
const CHAR_LOG_SCROLL_THRESHOLD_PX := 50

var _econ_stats: EconomyStatsManager = null
var _max_fields: int = 10
var _field_count_getter: Callable = Callable()

var _record_block: Control = null
var _dock_divider: Control = null
var _bar_row: Control = null
var _inspector_tabs: TabContainer = null
var _tab_buttons: Array[Button] = []

var _title: Label = null
var _role: Label = null
var _teaser: Label = null
var _general: RichTextLabel = null
var _skills: RichTextLabel = null
var _career: RichTextLabel = null
var _log: RichTextLabel = null

var _scroll_sync_queued: bool = false
var _char_log_user_at_bottom: bool = true
var _life_log_sig: String = ""
var _log_scroll_wired: bool = false
var _log_pending_restore_ratio: float = -1.0

var _pop_dragging: bool = false
var _pop_drag_start_mouse: Vector2 = Vector2.ZERO
var _pop_drag_start_panel: Vector2 = Vector2.ZERO
var _drag_handle_wired: bool = false
var _tab_buttons_wired: bool = false

var _last_refreshed_pop: WeakRef = null


func configure(econ: EconomyStatsManager, max_fields: int, field_count_getter: Callable) -> void:
	_econ_stats = econ
	_max_fields = max_fields
	_field_count_getter = field_count_getter


func _ready() -> void:
	set_process_input(true)
	custom_minimum_size = DOCK_SIZE_FULL
	_record_block = get_node_or_null("DockStack/RecordBlock") as Control
	_dock_divider = get_node_or_null("DockStack/DockDivider") as Control
	_bar_row = get_node_or_null("DockStack/BarRow") as Control

	var drag_h := get_node_or_null("DockStack/RecordBlock/FloatHeader/FloatDragHandle") as Control
	if drag_h:
		drag_h.mouse_default_cursor_shape = Control.CURSOR_MOVE
		drag_h.tooltip_text = "Drag to move"
		if not _drag_handle_wired:
			drag_h.gui_input.connect(_on_drag_handle_gui_input)
			_drag_handle_wired = true

	var float_close := get_node_or_null("DockStack/RecordBlock/FloatHeader/PopInspectorFloatClose")
	if float_close and float_close is Button:
		(float_close as Button).pressed.connect(_on_float_close_pressed)

	var stat_pfx := STAT_BASE + "/InspectorTabs"
	_general = get_node_or_null(stat_pfx + "/General/GeneralBody") as RichTextLabel
	_skills = get_node_or_null(stat_pfx + "/Skills/SkillsBody") as RichTextLabel
	_career = get_node_or_null(stat_pfx + "/Career/CareerBody") as RichTextLabel
	_log = get_node_or_null(stat_pfx + "/Log/LogBody") as RichTextLabel
	_inspector_tabs = get_node_or_null(STAT_BASE + "/InspectorTabs") as TabContainer

	var stat_col: Control = get_node_or_null(STAT_BASE) as Control
	if stat_col and not stat_col.resized.is_connected(_on_stat_col_resized):
		stat_col.resized.connect(_on_stat_col_resized)

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.065, 0.065, 0.095, 0.96)
	panel_style.border_color = Color(0.28, 0.28, 0.42, 0.8)
	panel_style.set_border_width_all(1)
	panel_style.content_margin_left = 12
	panel_style.content_margin_right = 12
	panel_style.content_margin_top = 10
	panel_style.content_margin_bottom = 10
	add_theme_stylebox_override("panel", panel_style)

	if _inspector_tabs:
		_inspector_tabs.custom_minimum_size = Vector2(0, 220)

	if _bar_row:
		_title = _bar_row.get_node_or_null("NameBlock/PopInspectorTitle") as Label
		_role = _bar_row.get_node_or_null("NameBlock/PopInspectorRole") as Label
		_teaser = _bar_row.get_node_or_null("NameBlock/PopStatusTeaser") as Label
		var bar_close := _bar_row.get_node_or_null("PopInspectorBarClose")
		if bar_close and bar_close is Button:
			(bar_close as Button).pressed.connect(func(): dismiss_requested.emit())

		if not _tab_buttons_wired:
			var tab_ids := ["TabGeneral", "TabSkills", "TabCareer", "TabLog"]
			_tab_buttons.clear()
			for i: int in range(tab_ids.size()):
				var b := _bar_row.get_node_or_null("TabButtons/" + tab_ids[i]) as Button
				if b:
					_tab_buttons.append(b)
					b.pressed.connect(_on_bar_tab_pressed.bind(i))
			_tab_buttons_wired = true

	_wire_life_log_scroll()


func _process(_delta: float) -> void:
	if _pop_dragging and visible:
		var m: Vector2 = get_global_mouse_position()
		global_position = _clamp_dock_position(_pop_drag_start_panel + (m - _pop_drag_start_mouse))


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_pop_dragging = false


func refresh(selected_pop: Node) -> void:
	if selected_pop == null or not is_instance_valid(selected_pop):
		_pop_dragging = false
		visible = false
		_last_refreshed_pop = null
		return

	var prev_wr: WeakRef = _last_refreshed_pop
	var prev: Node = prev_wr.get_ref() as Node if prev_wr else null
	var pop_changed: bool = prev != selected_pop
	if pop_changed:
		_life_log_sig = ""
		_char_log_user_at_bottom = true
		_log_pending_restore_ratio = -1.0
	_last_refreshed_pop = weakref(selected_pop)

	var dock_was_hidden: bool = not visible
	visible = true
	if dock_was_hidden or pop_changed:
		_apply_record_visible(true)
		call_deferred("_place_dock_default")
		_sync_tab_buttons()

	if not selected_pop.has_method("get_inspector_data"):
		_set_tab_texts("(no inspector data available)", "", "", "")
		return

	var d: Dictionary = selected_pop.get_inspector_data()

	if _title:
		_title.text = str(d.get("person_name", d.get("name", "?")))
	if _role:
		_role.text = str(d.get("role", "?"))
	if _teaser:
		var tier: String = str(d.get("wealth_tier", ""))
		var cash_t: float = d.get("cash", 0.0)
		var state_s: String = str(d.get("state", ""))
		if tier != "":
			_teaser.text = "%s  ·  $%.0f  ·  %s" % [tier, cash_t, state_s]
		else:
			_teaser.text = "$%.0f  ·  %s" % [cash_t, state_s]

	_resolve_tab_labels()
	if _general == null:
		return

	const INSPECTOR_SEC := "[color=#8ab4e8][b]%s[/b][/color]"

	var cash: float = d.get("cash", 0.0)
	var bread: int = d.get("bread", 0)
	var hunger_str: String = str(d.get("hunger", "?"))
	var starving: bool = d.get("starving", false)
	var surv: bool = d.get("survival", false)
	var state: String = str(d.get("state", "?"))

	var starve_tag: String = "  [color=red]☠ STARVING[/color]" if starving else ""
	var surv_tag: String = "  [color=orange][SURVIVAL][/color]" if surv else ""

	var wealth: String = str(d.get("wealth_tier", ""))
	var wealth_col: String
	var wealth_icon: String
	match wealth:
		"Poor":
			wealth_col = "#aaaaaa"
			wealth_icon = "▪"
		"Working":
			wealth_col = "#e8b800"
			wealth_icon = "◆"
		"Wealthy":
			wealth_col = "#33dd33"
			wealth_icon = "★"
		_:
			wealth_col = "#888888"
			wealth_icon = "·"
	var wealth_line: String = "[color=%s][b]%s %s[/b][/color]%s" % [
		wealth_col, wealth_icon, wealth, surv_tag
	] if wealth != "" else ""

	var line1: String = "[b]$%.0f[/b]    Bread: [b]%d[/b]    Hunger: [b]%s[/b]%s" % [
		cash, bread, hunger_str, starve_tag
	]
	var line2: String = wealth_line
	var line3: String = "[color=#aaaaaa]%s[/color]" % state

	var extras: Array[String] = []
	if d.has("seeds"):
		extras.append("Carrying %d seeds." % d.get("seeds"))
	if d.has("wheat"):
		extras.append("Carrying %d wheat." % d.get("wheat"))
	if d.has("flour"):
		extras.append("Carrying %d flour." % d.get("flour"))
	if d.has("fields"):
		extras.append("Working %d field(s)." % d.get("fields"))
	if d.has("bread_consumed") and int(d.get("bread_consumed", 0)) > 0:
		extras.append("Ate %d bread today." % d.get("bread_consumed"))
	if int(d.get("neg_cashflow_days", 0)) > 0:
		extras.append("[color=#ff8844]Losing money for %d day(s) in a row.[/color]" % d.get("neg_cashflow_days"))
	if int(d.get("failed_food_days", 0)) > 0:
		extras.append("[color=#ff8844]Could not buy food for %d day(s) in a row.[/color]" % d.get("failed_food_days"))
	if d.has("training_days"):
		extras.append("[color=#88ccff]Training for a new job — %d day(s) left.[/color]" % d.get("training_days"))

	var general_lines: Array[String] = []
	general_lines.append(INSPECTOR_SEC % "Vitals")
	general_lines.append(line1)
	if wealth_line != "":
		general_lines.append(line2)
	general_lines.append(line3)
	if extras.size() > 0:
		general_lines.append("")
		general_lines.append(INSPECTOR_SEC % "Belongings & pressure")
		for ex: String in extras:
			general_lines.append("[color=#d0d8e8]• %s[/color]" % ex)

	var skills_lines: Array[String] = []
	var sk_f: float = d.get("skill_farmer", -1.0)
	if sk_f >= 0.0:
		skills_lines.append(INSPECTOR_SEC % "Skills & productivity")
		var sk_b: float = d.get("skill_baker", 0.0)
		var dir: int = int(d.get("days_in_role", 0))
		var prod_m: float = d.get("prod_mult", 1.0)
		var pm_col: String = "#88cc88" if prod_m >= 1.0 else "#cc8888"
		var f_fill: int = roundi(sk_f * 5.0)
		var b_fill: int = roundi(sk_b * 5.0)
		var f_bar: String = "█".repeat(f_fill) + "░".repeat(5 - f_fill)
		var b_bar: String = "█".repeat(b_fill) + "░".repeat(5 - b_fill)
		skills_lines.append(
			"[color=#6688aa]Farmer skill [%s] %.2f · Baker skill [%s] %.2f · %d days in this role[/color]" %
			[f_bar, sk_f, b_bar, sk_b, dir])
		skills_lines.append(
			"[color=#6688aa]Productivity today: [color=%s]×%.2f[/color][/color]" %
			[pm_col, prod_m])
	else:
		skills_lines.append(
			"[color=#9aa8bc](No skill breakdown for this person — data appears once roles are tracked.)[/color]")

	var career_lines: Array[String] = []
	var rec_role: String = str(d.get("recommended_role", ""))
	if rec_role != "":
		career_lines.append(INSPECTOR_SEC % "Career utilities")
		var u_f: float = d.get("utility_farmer", 0.0)
		var u_b: float = d.get("utility_baker", 0.0)
		var u_c: float = d.get("utility_current", 0.0)
		var uf_col: String = "#88ccaa" if u_f >= u_c else "#888888"
		var ub_col: String = "#88ccaa" if u_b >= u_c else "#888888"
		var uc_col: String = "#aaaacc"
		career_lines.append(
			"[color=#6688aa]Utility — [color=%s]farmer %.1f[/color] · [color=%s]baker %.1f[/color] · [color=%s]stay put %.1f[/color][/color]" %
			[uf_col, u_f, ub_col, u_b, uc_col, u_c])
		var rec_col: String = "#55cc88" if rec_role != str(d.get("role", "")) else "#888888"
		career_lines.append(
			"[color=#556688]Best-looking job right now: [color=%s]%s[/color][/color]" %
			[rec_col, rec_role])
		career_lines.append("")

	var lce: Dictionary = d.get("last_career_eval", {})
	if lce is Dictionary and not lce.is_empty():
		career_lines.append(INSPECTOR_SEC % "Last career evaluation")
		var rpf: float = lce.get("role_profit_7d_avg_farmer", 0.0)
		var rpb: float = lce.get("role_profit_7d_avg_baker", 0.0)
		career_lines.append(
			"[color=#556688]Role 7d avg: Farmer=$%.2f  Baker=$%.2f[/color]" % [rpf, rpb])
		var ei_f: float = lce.get("income_farmer", 0.0) * lce.get("sf_farmer", 1.0)
		var ei_b: float = lce.get("income_baker", 0.0) * lce.get("sf_baker", 1.0)
		career_lines.append(
			"[color=#556688]Expected income: F=$%.2f  B=$%.2f  (pop avg=$%.2f)[/color]" % [
				ei_f, ei_b, lce.get("pop_cashflow_7d_avg", 0.0)])
		career_lines.append(
			"[color=#556688]Skill factors: F=×%.2f  B=×%.2f  Risk=%.2f[/color]" % [
				lce.get("sf_farmer", 1.0), lce.get("sf_baker", 1.0), lce.get("risk", 0.0)])
		career_lines.append(
			"[color=#556688]Switch cost: F=%.1f  B=%.1f[/color]" % [
				lce.get("switch_cost_farmer", 0.0), lce.get("switch_cost_baker", 0.0)])
		var du_f: float = lce.get("diag_U_farmer", 0.0)
		var du_b: float = lce.get("diag_U_baker", 0.0)
		career_lines.append(
			"[color=#556688]Diag U (simple): F=%.2f  B=%.2f[/color]" % [du_f, du_b])
		var scar_b: float = lce.get("scarcity_bread", 0.0)
		var scar_w: float = lce.get("scarcity_wheat", 0.0)
		var scar_col: String = "#cc5555" if scar_b > 0.0 or scar_w > 0.0 else "#556688"
		career_lines.append(
			"[color=%s]Scarcity: bread=%.2f wheat=%.2f[/color]" % [scar_col, scar_b, scar_w])
		var sbf: float = lce.get("scarcity_bonus_farmer", 0.0)
		var sbb: float = lce.get("scarcity_bonus_baker", 0.0)
		if sbf > 0.0 or sbb > 0.0:
			career_lines.append(
				"[color=#aa7744]Scarcity bonus: F=+%.2f  B=+%.2f[/color]" % [sbf, sbb])
		career_lines.append("")

	var eval_day_val: int = int(d.get("last_eval_day", -1))
	if eval_day_val >= 0:
		var g_tenure: int = int(d.get("gate_tenure", 0))
		var g_cooldown: int = int(d.get("gate_cooldown", 0))
		var g_cash: float = d.get("gate_savings_cash", 0.0)
		var g_bread: int = int(d.get("gate_food_bread", 0))
		var g_ftarget: int = int(d.get("gate_food_target", 3))
		var g_freq: int = int(ceil(g_ftarget * (2.0 / 3.0)))
		var tenure_col: String = "#55cc88" if g_tenure >= 14 else "#cc5555"
		var cd_col: String = "#55cc88" if g_cooldown == 0 else "#cc5555"
		var sav_col: String = "#55cc88" if g_cash >= 200.0 else "#cc5555"
		var food_col: String = "#55cc88" if g_bread >= g_freq else "#cc5555"
		var fields_now: int = _get_field_count()
		var lc_col: String = "#55cc88" if fields_now < _max_fields else "#cc5555"
		career_lines.append(INSPECTOR_SEC % "Switch gates")
		career_lines.append(
			"[color=%s]Tenure: %d/14d[/color]  [color=%s]Cooldown: %dd[/color]  [color=%s]Savings: $%.0f/$200[/color]" %
			[tenure_col, g_tenure, cd_col, g_cooldown, sav_col, g_cash])
		career_lines.append(
			"[color=%s]Food: %d/%d[/color]  [color=%s]Land: %d/%d[/color]  [color=#556688]Eval day: %d[/color]" %
			[food_col, g_bread, g_freq, lc_col, fields_now, _max_fields, eval_day_val])
		career_lines.append("")

	var lcd: String = str(d.get("last_career_decision", ""))
	if lcd != "":
		var lcd_col: String = "#ccaa55" if "blocked" in lcd else "#55cc88"
		career_lines.append("[color=%s]Last decision: %s[/color]" % [lcd_col, lcd])
		career_lines.append("")

	var cf_income: float = d.get("cashflow_income", -1.0)
	if cf_income >= 0.0:
		career_lines.append(INSPECTOR_SEC % "Cashflow")
		var cf_expense: float = d.get("cashflow_expense", 0.0)
		var cf_net: float = cf_income - cf_expense
		var cf_avg: float = d.get("cashflow_7d_avg", 0.0)
		var cf_len: int = int(d.get("cashflow_7d_len", 0))
		var pop_role: String = str(d.get("role", ""))
		var r_avg: float = _role_rolling_7d_avg(pop_role)
		var delta: float = cf_avg - r_avg
		var net_col: String = "#55cc88" if cf_net >= 0.0 else "#cc5555"
		var avg_col: String = "#55cc88" if cf_avg >= 0.0 else "#cc5555"
		var d_col: String = "#55cc88" if delta >= 0.0 else "#cc5555"
		var has_7d: bool = cf_len >= 2
		var d_days: String = "%d" % cf_len if has_7d else "n/a"
		var avg_str: String = "[color=%s]$%.2f/d[/color]" % [avg_col, cf_avg] if has_7d else "n/a"
		career_lines.append(
			"[color=#6688bb]₢ Today: +$%.2f  -$%.2f  = [color=%s]$%.2f[/color]   7d(%s): avg %s[/color]" %
			[cf_income, cf_expense, net_col, cf_net, d_days, avg_str])
		if has_7d:
			career_lines.append(
				"[color=#445577]%s role 7d avg: $%.2f/d   Δ vs role: [color=%s]%+.2f[/color][/color]" %
				[pop_role, r_avg, d_col, delta])

	while career_lines.size() > 0 and career_lines[career_lines.size() - 1] == "":
		career_lines.remove_at(career_lines.size() - 1)
	if career_lines.is_empty():
		career_lines = ["[color=#9aa8bc](Career details fill in after evaluations and job checks.)[/color]"]

	_general.text = "\n".join(general_lines)
	_skills.text = "\n".join(skills_lines)
	_career.text = "\n".join(career_lines)

	var log_text: String = ""
	var events: Array = []
	var raw_ev: Variant = selected_pop.get("life_events")
	if raw_ev is Array:
		events = raw_ev
	if events.is_empty():
		log_text = "[color=#9aa8bc](Nothing written yet — day-end diary entries show up here.)[/color]"
	else:
		var start: int = max(0, events.size() - 200)
		var hist_lines: Array[String] = []
		for i: int in range(start, events.size()):
			hist_lines.append("[color=#b8c4d8]" + str(events[i]) + "[/color]")
		log_text = "\n".join(hist_lines)

	var sig: String = "%d:%s" % [events.size(), str(events[-1]) if events.size() > 0 else ""]
	if sig != _life_log_sig:
		var sc_log: ScrollContainer = get_node_or_null(STAT_BASE + "/InspectorTabs/Log") as ScrollContainer
		var vs_log: ScrollBar = sc_log.get_v_scroll_bar() if sc_log else null
		if not _char_log_user_at_bottom and vs_log != null:
			var denom_before: float = vs_log.max_value - vs_log.page
			if denom_before > 0.0:
				_log_pending_restore_ratio = vs_log.value / denom_before
			else:
				_log_pending_restore_ratio = -1.0
		else:
			_log_pending_restore_ratio = -1.0
		_log.text = log_text
		_life_log_sig = sig
		call_deferred("_deferred_life_log_after_text_change")

	if not _log_scroll_wired:
		_wire_life_log_scroll()

	_queue_scroll_sync()


func _get_field_count() -> int:
	if _field_count_getter.is_valid():
		var v: Variant = _field_count_getter.call()
		if v is int:
			return v as int
		if v is float:
			return int(v)
	return 0


func _role_rolling_7d_avg(role: String) -> float:
	if _econ_stats:
		return _econ_stats.role_rolling_7d_avg(role)
	return 0.0


func _set_tab_texts(gen: String, sk: String, car: String, log_t: String) -> void:
	_resolve_tab_labels()
	if _general:
		_general.text = gen
	if _skills:
		_skills.text = sk
	if _career:
		_career.text = car
	if _log:
		_log.text = log_t


func _resolve_tab_labels() -> void:
	var p := STAT_BASE + "/InspectorTabs"
	if _general == null:
		_general = get_node_or_null(p + "/General/GeneralBody") as RichTextLabel
	if _skills == null:
		_skills = get_node_or_null(p + "/Skills/SkillsBody") as RichTextLabel
	if _career == null:
		_career = get_node_or_null(p + "/Career/CareerBody") as RichTextLabel
	if _log == null:
		_log = get_node_or_null(p + "/Log/LogBody") as RichTextLabel


func _apply_record_visible(full_record: bool) -> void:
	if _record_block:
		_record_block.visible = full_record
	if _dock_divider:
		_dock_divider.visible = full_record
	var sz: Vector2 = DOCK_SIZE_FULL if full_record else DOCK_SIZE_BAR
	custom_minimum_size = sz
	size = sz


func _on_float_close_pressed() -> void:
	_pop_dragging = false
	_apply_record_visible(false)
	call_deferred("_place_dock_default")


func _on_bar_tab_pressed(idx: int) -> void:
	if _inspector_tabs == null:
		return
	_inspector_tabs.current_tab = idx
	_sync_tab_buttons()
	if _record_block != null and not _record_block.visible:
		_apply_record_visible(true)
		call_deferred("_place_dock_default")


func _sync_tab_buttons() -> void:
	if _inspector_tabs == null or _tab_buttons.is_empty():
		return
	var cur: int = _inspector_tabs.current_tab
	for i: int in range(_tab_buttons.size()):
		_tab_buttons[i].set_pressed_no_signal(i == cur)


func _place_dock_default() -> void:
	var sz: Vector2 = size
	if sz.x < 1.0 or sz.y < 1.0:
		sz = custom_minimum_size
		if sz.x < 1.0 or sz.y < 1.0:
			sz = DOCK_SIZE_FULL
		size = sz
	var vp: Rect2 = get_viewport().get_visible_rect()
	var pos := Vector2(
		vp.position.x + (vp.size.x - sz.x) * 0.5,
		vp.position.y + vp.size.y - sz.y - 12.0
	)
	global_position = _clamp_dock_position(pos)


func _clamp_dock_position(pos: Vector2) -> Vector2:
	var sz: Vector2 = size
	if sz.x < 1.0 or sz.y < 1.0:
		sz = DOCK_SIZE_FULL
	var vp: Rect2 = get_viewport().get_visible_rect()
	var margin := 8.0
	var min_x: float = vp.position.x + margin
	var min_y: float = vp.position.y + margin
	var max_x: float = vp.position.x + vp.size.x - sz.x - margin
	var max_y: float = vp.position.y + vp.size.y - sz.y - margin
	if max_x < min_x:
		max_x = min_x
	if max_y < min_y:
		max_y = min_y
	return Vector2(clampf(pos.x, min_x, max_x), clampf(pos.y, min_y, max_y))


func _on_drag_handle_gui_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pop_dragging = true
			_pop_drag_start_mouse = get_global_mouse_position()
			_pop_drag_start_panel = global_position
		else:
			_pop_dragging = false


func _wire_life_log_scroll() -> void:
	if _log_scroll_wired:
		return
	var sc: ScrollContainer = get_node_or_null(STAT_BASE + "/InspectorTabs/Log") as ScrollContainer
	if sc == null:
		return
	var vs: ScrollBar = sc.get_v_scroll_bar()
	if vs == null:
		return
	if not vs.value_changed.is_connected(_on_life_log_scroll):
		vs.value_changed.connect(_on_life_log_scroll)
	_log_scroll_wired = true


func _on_life_log_scroll(_value: float) -> void:
	var sc: ScrollContainer = get_node_or_null(STAT_BASE + "/InspectorTabs/Log") as ScrollContainer
	if sc == null:
		return
	var vs: ScrollBar = sc.get_v_scroll_bar()
	if vs == null:
		return
	var max_scroll: float = vs.max_value - vs.page
	if max_scroll <= 0.0:
		_char_log_user_at_bottom = true
		return
	_char_log_user_at_bottom = (max_scroll - vs.value) <= float(CHAR_LOG_SCROLL_THRESHOLD_PX)


func _deferred_life_log_after_text_change() -> void:
	call_deferred("_deferred_life_log_after_text_change_b")


func _deferred_life_log_after_text_change_b() -> void:
	var sc: ScrollContainer = get_node_or_null(STAT_BASE + "/InspectorTabs/Log") as ScrollContainer
	if sc == null:
		return
	var vs: ScrollBar = sc.get_v_scroll_bar()
	if vs == null:
		return
	var denom: float = maxf(vs.max_value - vs.page, 0.0)
	if _char_log_user_at_bottom:
		if denom > 0.0:
			vs.value = denom
		return
	if _log_pending_restore_ratio >= 0.0 and denom > 0.0:
		vs.value = clampf(_log_pending_restore_ratio * denom, 0.0, denom)
	_log_pending_restore_ratio = -1.0


func _on_stat_col_resized() -> void:
	_queue_scroll_sync()


func _queue_scroll_sync() -> void:
	if _scroll_sync_queued:
		return
	if not visible:
		return
	if _record_block != null and not _record_block.visible:
		return
	_scroll_sync_queued = true
	call_deferred("_deferred_sync_scroll_layout")


func _deferred_sync_scroll_layout() -> void:
	_scroll_sync_queued = false
	if not visible:
		return
	if _record_block != null and not _record_block.visible:
		return
	var stat_col := get_node_or_null(STAT_BASE) as Control
	var vw: float = get_viewport().get_visible_rect().size.x
	if stat_col == null:
		return
	var w: float = stat_col.size.x - 36.0
	if w < 80.0:
		w = maxf(200.0, vw * 0.48)
	_resolve_tab_labels()
	for r in [_general, _skills, _career, _log]:
		var rtl: RichTextLabel = r as RichTextLabel
		if rtl == null:
			continue
		rtl.custom_minimum_size.x = w
