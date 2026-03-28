extends PanelContainer
class_name TradePanel
## Trade telemetry panel — shows live inter-village trade routes, flows, and profit.
## Created by main.gd via TradePanel.tscn instantiation.
## Depends on: World.gd trade_enabled flag (T1), FarmerJob/BakerJob trade state (T2/T3).
## Uses has_method() guards for all T1 APIs so it gracefully degrades before T1 is complete.

# ── Layout references (assigned in _build_layout) ─────────────────────────────
var _routes_label: RichTextLabel = null
var _flows_label: RichTextLabel  = null
var _profit_label: RichTextLabel = null
var _header_label: Label         = null

# ── External references (set by main.gd) ──────────────────────────────────────
## WorldManager node — provides trade_enabled, get_all_villages(), toggle_trade().
var world_node: Node = null

# ── Refresh throttle ──────────────────────────────────────────────────────────
const UPDATE_INTERVAL_SEC: float = 0.5
var _time_since_update: float    = 0.0

const PANEL_WIDTH:  float = 320.0
const PANEL_HEIGHT: float = 340.0


func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_layout()


func _build_layout() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color     = Color(0.07, 0.07, 0.12, 0.94)
	panel_style.border_color = Color(0.20, 0.55, 0.80, 0.85)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(6)
	panel_style.set_content_margin_all(10)
	add_theme_stylebox_override("panel", panel_style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	# ── Header row ──
	var header_row := HBoxContainer.new()
	vbox.add_child(header_row)

	_header_label = Label.new()
	_header_label.text = "TRADE  ●  OFF"
	_header_label.add_theme_font_size_override("font_size", 16)
	_header_label.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
	_header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(_header_label)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(26, 26)
	close_btn.tooltip_text = "Close trade panel"
	close_btn.pressed.connect(hide)
	header_row.add_child(close_btn)

	vbox.add_child(HSeparator.new())

	# ── Active Routes section ──
	var routes_title := Label.new()
	routes_title.text = "Active Routes"
	routes_title.add_theme_font_size_override("font_size", 13)
	routes_title.add_theme_color_override("font_color", Color(0.85, 0.85, 0.45))
	vbox.add_child(routes_title)

	_routes_label = _make_rtl()
	_routes_label.custom_minimum_size = Vector2(0, 72)
	vbox.add_child(_routes_label)

	vbox.add_child(HSeparator.new())

	# ── Village Flows section ──
	var flows_title := Label.new()
	flows_title.text = "Village Flows"
	flows_title.add_theme_font_size_override("font_size", 13)
	flows_title.add_theme_color_override("font_color", Color(0.45, 0.85, 0.65))
	vbox.add_child(flows_title)

	_flows_label = _make_rtl()
	_flows_label.custom_minimum_size = Vector2(0, 64)
	vbox.add_child(_flows_label)

	vbox.add_child(HSeparator.new())

	# ── Trade Profit section ──
	var profit_title := Label.new()
	profit_title.text = "Trade Profit"
	profit_title.add_theme_font_size_override("font_size", 13)
	profit_title.add_theme_color_override("font_color", Color(0.65, 1.0, 0.45))
	vbox.add_child(profit_title)

	_profit_label = _make_rtl()
	_profit_label.custom_minimum_size = Vector2(0, 52)
	vbox.add_child(_profit_label)


func _make_rtl() -> RichTextLabel:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.scroll_active  = false
	rtl.fit_content    = true
	rtl.add_theme_font_size_override("normal_font_size", 13)
	rtl.add_theme_color_override("default_color", Color(0.88, 0.88, 0.88))
	return rtl


# ── Update loop ───────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not visible:
		return
	_time_since_update += delta
	if _time_since_update < UPDATE_INTERVAL_SEC:
		return
	_time_since_update = 0.0
	update_display(world_node)


## Public entry point — called by _process or externally (e.g. on_simulation_tick).
## world can be null; all access is guarded.
func update_display(world: Node) -> void:
	var trade_on: bool = false
	if world != null and world.get("trade_enabled") != null:
		trade_on = world.trade_enabled

	if _header_label:
		if trade_on:
			_header_label.text = "TRADE  ●  ON"
			_header_label.add_theme_color_override("font_color", Color(0.30, 1.00, 0.45))
		else:
			_header_label.text = "TRADE  ●  OFF"
			_header_label.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))

	if not trade_on:
		_set_rtl(_routes_label, "[color=#888888](trade disabled)[/color]")
		_set_rtl(_flows_label,  "[color=#888888](trade disabled)[/color]")
		_set_rtl(_profit_label, "[color=#888888](trade disabled)[/color]")
		return

	_refresh_routes()
	_refresh_flows(world)
	_refresh_profit()


# ── Section refreshers ────────────────────────────────────────────────────────

func _refresh_routes() -> void:
	var lines: Array[String] = []
	for group in ["farmers", "bakers"]:
		for agent in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(agent):
				continue
			var home = agent.get("home_village_ref")
			var cur  = agent.get("current_village_ref")
			if home == null or cur == null:
				continue
			if not is_instance_valid(home) or not is_instance_valid(cur):
				continue
			# Agent is away from home village — show as active route
			if home == cur:
				continue
			var home_name: String = _village_name(home)
			var cur_name:  String = _village_name(cur)
			var cargo: String     = _agent_cargo(agent)
			var role: String      = "Farmer" if group == "farmers" else "Baker"
			lines.append("%s [b]%s[/b]: %s → %s  [color=#aaffaa]%s[/color]" % [
				role, agent.name, home_name, cur_name, cargo
			])
	if lines.is_empty():
		_set_rtl(_routes_label, "[color=#888888](no active routes)[/color]")
	else:
		_set_rtl(_routes_label, "\n".join(lines))


func _refresh_flows(world: Node) -> void:
	var villages_arr: Array = []

	# Prefer T1 API get_all_villages() when available
	if world != null and world.has_method("get_all_villages"):
		villages_arr = world.get_all_villages()
	elif world != null and world.get("villages") != null:
		villages_arr = world.villages

	if villages_arr.is_empty():
		_set_rtl(_flows_label, "[color=#888888](no villages)[/color]")
		return

	var lines: Array[String] = []
	for v in villages_arr:
		if not (v and is_instance_valid(v)):
			continue
		var vname: String = _village_name(v)
		var wheat_out: int = 0
		var bread_out: int = 0
		var wheat_in:  int = 0
		var bread_in:  int = 0

		# Use Village.get_trade_snapshot() when available (T1)
		if v.has_method("get_trade_snapshot"):
			var snap: Dictionary = v.get_trade_snapshot()
			wheat_out = snap.get("wheat_exported", 0)
			wheat_in  = snap.get("wheat_imported", 0)
			bread_out = snap.get("bread_exported", 0)
			bread_in  = snap.get("bread_imported", 0)
		else:
			# Fallback: scan agents to approximate flows
			for group in ["farmers", "bakers"]:
				for agent in get_tree().get_nodes_in_group(group):
					if not is_instance_valid(agent):
						continue
					var home = agent.get("home_village_ref")
					var cur  = agent.get("current_village_ref")
					if home == null or cur == null:
						continue
					if not is_instance_valid(home) or not is_instance_valid(cur):
						continue
					if home == v and cur != v:
						if group == "farmers":
							wheat_out += int(agent.get("wheat") if agent.get("wheat") != null else 0)
						else:
							bread_out += int(agent.get("bread") if agent.get("bread") != null else 0)
					elif home != v and cur == v:
						if group == "farmers":
							wheat_in += int(agent.get("wheat") if agent.get("wheat") != null else 0)
						else:
							bread_in += int(agent.get("bread") if agent.get("bread") != null else 0)

		lines.append("[b]%s[/b]  wheat ↑%d ↓%d  bread ↑%d ↓%d" % [
			vname, wheat_out, wheat_in, bread_out, bread_in
		])

	if lines.is_empty():
		_set_rtl(_flows_label, "[color=#888888](no data)[/color]")
	else:
		_set_rtl(_flows_label, "\n".join(lines))


func _refresh_profit() -> void:
	var lines: Array[String] = []
	var route_agg: Dictionary = {}  # "V1→V2" → float

	for group in ["farmers", "bakers"]:
		for agent in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(agent):
				continue
			var profit = agent.get("trade_profit_total")
			if profit == null:
				continue
			var home = agent.get("home_village_ref")
			var cur  = agent.get("current_village_ref")
			var profit_f: float = float(profit)
			var col: String     = "#aaffaa" if profit_f >= 0.0 else "#ff8888"
			var role: String    = "Farmer" if group == "farmers" else "Baker"
			lines.append("%s [b]%s[/b]: [color=%s]$%.1f[/color]" % [
				role, agent.name, col, profit_f
			])
			# Aggregate profit by route key
			if home != null and cur != null and is_instance_valid(home) and is_instance_valid(cur) and home != cur:
				var key: String = "%s→%s" % [_village_name(home), _village_name(cur)]
				route_agg[key] = route_agg.get(key, 0.0) + profit_f

	for route_key in route_agg:
		var total: float = route_agg[route_key]
		var col: String  = "#aaffaa" if total >= 0.0 else "#ff8888"
		lines.append("  Route %s: [color=%s]$%.1f[/color]" % [route_key, col, total])

	if lines.is_empty():
		_set_rtl(_profit_label, "[color=#888888](no trade activity)[/color]")
	else:
		_set_rtl(_profit_label, "\n".join(lines))


# ── Helpers ───────────────────────────────────────────────────────────────────

func _set_rtl(rtl: RichTextLabel, text: String) -> void:
	if rtl:
		rtl.clear()
		rtl.append_text(text)


func _village_name(v: Node) -> String:
	if v == null or not is_instance_valid(v):
		return "?"
	if v.get("village_name") != null and (v.village_name as String) != "":
		return v.village_name
	return v.name


func _agent_cargo(agent: Node) -> String:
	var parts: Array[String] = []
	var wheat = agent.get("wheat")
	if wheat != null and int(wheat) > 0:
		parts.append("wheat×%d" % int(wheat))
	var flour = agent.get("flour")
	if flour != null and int(flour) > 0:
		parts.append("flour×%d" % int(flour))
	var bread = agent.get("bread")
	if bread != null and int(bread) > 0:
		parts.append("bread×%d" % int(bread))
	if parts.is_empty():
		return "(empty)"
	return ", ".join(parts)
