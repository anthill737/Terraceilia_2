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

## Groups scanned for people away from their home village (merchants live in "households").
const ROUTE_GROUPS: Array[String] = ["farmers", "bakers", "woodworkers", "households"]

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
	profit_title.text = "Merchants"
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
	_refresh_merchants(world)


# ── Section refreshers ────────────────────────────────────────────────────────

func _refresh_routes() -> void:
	var lines: Array[String] = []
	for group in ROUTE_GROUPS:
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
			var role: String      = _role_label(agent, group)
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
		var wheat_away: int = 0  # agents from this village carrying wheat elsewhere
		var bread_away: int = 0  # agents from this village carrying bread elsewhere
		var wheat_stock: int = 0
		var bread_stock: int = 0

		# Market stock levels from Village.get_trade_snapshot() (T1 API)
		if v.has_method("get_trade_snapshot"):
			var snap: Dictionary = v.get_trade_snapshot()
			wheat_stock = snap.get("wheat_qty", 0)
			bread_stock = snap.get("bread_qty", 0)

		# Scan agents to count goods currently carried away from this village
		for group in ROUTE_GROUPS:
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
					var inv = agent.get("inv")
					if inv != null and inv.has_method("get_qty"):
						var merchant: bool = _is_merchant(agent)
						if group == "farmers" or merchant:
							wheat_away += inv.get_qty("wheat")
						if group == "bakers" or merchant:
							bread_away += inv.get_qty("bread")

		lines.append("[b]%s[/b]  stock wheat %d bread %d  away wheat %d bread %d" % [
			vname, wheat_stock, bread_stock, wheat_away, bread_away
		])

	if lines.is_empty():
		_set_rtl(_flows_label, "[color=#888888](no data)[/color]")
	else:
		_set_rtl(_flows_label, "\n".join(lines))


## Travelling merchants: every person in any village's households carrying the "merchant"
## meta. Name, home village, trips made, total profit and the last deal come from the metas
## the trade code keeps on the merchant ("trade_trips", "trade_profit_total", "trade_last").
func _refresh_merchants(world: Node) -> void:
	var lines: Array[String] = []
	var seen: Dictionary = {}
	var villages_arr: Array = _villages_of(world)
	for v in villages_arr:
		if not (v and is_instance_valid(v)):
			continue
		var people = v.get("households")
		if not (people is Array):
			continue
		for agent in people:
			if agent == null or not is_instance_valid(agent) or not _is_merchant(agent):
				continue
			var key: int = agent.get_instance_id()
			if seen.has(key):
				continue
			seen[key] = true
			var home: Node = _home_village_of(agent, villages_arr, v)
			var trips: int = int(_meta_number(agent, "trade_trips"))
			var profit: float = _meta_number(agent, "trade_profit_total")
			var last_deal: String = str(agent.get_meta("trade_last", ""))
			var col: String = "#aaffaa" if profit >= 0.0 else "#ff8888"
			lines.append("[b]%s[/b] (%s): %d %s, [color=%s]$%.1f[/color] profit" % [
				_person_name(agent), _village_name(home), trips,
				"trip" if trips == 1 else "trips", col, profit
			])
			lines.append("  [color=#aaaaaa]Last deal: %s[/color]" % [
				last_deal if last_deal != "" else "none yet"
			])

	if lines.is_empty():
		_set_rtl(_profit_label, "[color=#888888](no merchants yet)[/color]")
	else:
		_set_rtl(_profit_label, "\n".join(lines))


# ── Helpers ───────────────────────────────────────────────────────────────────

## All Village nodes of the world (empty when the world is not there yet).
func _villages_of(world: Node) -> Array:
	if world == null or not is_instance_valid(world):
		return []
	if world.has_method("get_all_villages"):
		return world.get_all_villages()
	var arr = world.get("villages")
	if arr is Array:
		return arr
	return []


func _is_merchant(agent: Node) -> bool:
	if agent == null or not is_instance_valid(agent) or not agent.has_meta("merchant"):
		return false
	return true if agent.get_meta("merchant", false) else false


## A number kept as a meta on a person (0 when it is missing or not a number).
func _meta_number(agent: Node, key: String) -> float:
	var val = agent.get_meta(key, 0.0)
	if val is int or val is float:
		return float(val)
	return 0.0


## A person's home village: home_village_ref, else the village whose village_id matches
## home_village_id, else `fallback` (the village whose household list they were found in).
func _home_village_of(agent: Node, villages_arr: Array, fallback: Node) -> Node:
	var home = agent.get("home_village_ref")
	if home != null and is_instance_valid(home):
		return home as Node
	var hid = agent.get("home_village_id")
	if hid is int:
		for v in villages_arr:
			if v != null and is_instance_valid(v) and v.get("village_id") == hid:
				return v as Node
	return fallback


func _person_name(agent: Node) -> String:
	var pn = agent.get("person_name")
	if pn != null and str(pn) != "":
		return str(pn)
	return str(agent.name)


func _role_label(agent: Node, group: String) -> String:
	if _is_merchant(agent):
		return "Merchant"
	match group:
		"farmers":
			return "Farmer"
		"bakers":
			return "Baker"
		"woodworkers":
			return "Woodworker"
	return "Household"


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
	var inv = agent.get("inv")
	if inv == null:
		return "(empty)"
	for good in ["wheat", "flour", "bread", "firewood"]:
		if not inv.has_method("get_qty"):
			break
		var qty: int = inv.get_qty(good)
		if qty > 0:
			parts.append("%s×%d" % [good, qty])
	if parts.is_empty():
		return "(empty)"
	return ", ".join(parts)
