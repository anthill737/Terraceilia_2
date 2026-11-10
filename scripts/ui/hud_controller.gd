class_name HudController
extends Node
## Economy bar and HUD display controller.
## Builds the economy bar widget into a container node and owns all
## per-tick display updates for sim/day, village population, market,
## prosperity, and agent baseline sections.
## Created by main.gd; setup() must be called before update_display().

# ── Economy bar label refs ─────────────────────────────────────────────────
var eco_sim_label:        Label = null
var eco_village_label:    Label = null
var eco_market_label:     Label = null
var eco_prosperity_label: Label = null
var eco_farmer_label:     Label = null
var eco_baker_label:      Label = null
var eco_woodworker_label: Label = null
var eco_world_label:      Label = null

# ── Runtime state ──────────────────────────────────────────────────────────
var _world_node: Node     = null
var _current_speed: float = 1.0


# ── Entry point ────────────────────────────────────────────────────────────
## Build the economy bar widget into container and store world reference.
## container is typically the LeftColumn VBoxContainer from the HUD layout.
## Call once from main._ready() after the scene tree is available.
func setup(container: Node, world: Node) -> void:
	_world_node = world
	_build_economy_bar(container)


## Notify controller of a simulation speed change so eco_sim_label stays accurate.
func set_speed(speed: float) -> void:
	_current_speed = speed


# ── Public update API ──────────────────────────────────────────────────────
## Full economy bar refresh — call each simulation tick or per-frame.
## village may be null; all label access is guarded.
func update_display(village: Node) -> void:
	_update_eco_bar(village)


## Partial update: refresh only the VILLAGE population section.
## counts should be the result of Village.get_population_summary(),
## optionally extended with a "village_name" key for the header prefix.
func update_population_display(counts: Dictionary) -> void:
	if eco_village_label == null:
		return
	var vname: String = counts.get("village_name", "")
	eco_village_label.text = (
		"[%s]  Pop %d — households %d, farmers %d, bakers %d\nFields %d of %d"
		% [vname, counts.get("total", 0), counts.get("households", 0),
		   counts.get("farmers", 0), counts.get("bakers", 0),
		   counts.get("fields", 0), counts.get("max_fields", 10)]
	)


## Partial update: refresh only the SIM section with current day, tick, and speed.
func update_day_display(day: int, tick: int) -> void:
	if eco_sim_label == null:
		return
	eco_sim_label.text = "Day %d  T%d\n%.1f×" % [day, tick, _current_speed]


## Hook for day-change signals — entry point for callers that only have a day number.
## Override or connect as needed; default implementation is intentionally empty.
func on_day_changed(_day: int) -> void:
	pass


# ── Internal update ────────────────────────────────────────────────────────

func _update_eco_bar(village: Node) -> void:
	if village == null or not is_instance_valid(village):
		return

	var snap: Dictionary = village.get_econ_snapshot()
	var pop: Dictionary  = village.get_population_summary()

	# SIM
	if eco_sim_label:
		eco_sim_label.text = "Day %d\n%.1f×" % [snap.get("day", 0), _current_speed]

	# VILLAGE — prefix with selected village name so player always knows which village
	if eco_village_label:
		var vname: String = village.village_name if (village.get("village_name") as String) != "" else village.name
		var hs: Dictionary = village.housing.summary() if village.get("housing") != null else {}
		var village_text: String = (
			"[%s]  Pop %d: households %d, farmers %d, bakers %d, woodworkers %d\nFields %d of %d · Houses %d (%d empty, %d rented, %d being built)"
			% [vname, pop.get("total", 0), pop.get("households", 0), pop.get("farmers", 0),
			   pop.get("bakers", 0), village.all_woodworkers.size(), pop.get("fields", 0), pop.get("max_fields", 10),
			   hs.get("houses", 0), hs.get("empty", 0), hs.get("renters", 0), hs.get("building", 0)]
		)
		# People without work, and employers who found nobody free (LaborMarket).
		var lm = village.get("labor_market")
		if lm != null and is_instance_valid(lm) and lm.get("idle_count") != null:
			var idle_line: String = "Idle: %d" % int(lm.get("idle_count"))
			if lm.get("open_jobs") != null:
				idle_line += " · Open jobs: %d" % int(lm.get("open_jobs"))
			village_text += "\n" + idle_line
		# Troubles such as a bad harvest, when the village has any.
		var trouble: String = _village_trouble(village)
		if trouble != "":
			village_text += "\nTrouble: " + trouble
		eco_village_label.text = village_text

	# MARKET
	if eco_market_label:
		var wc: String = _eco_cap_display(snap.get("wheat_cap", 999999999))
		var bc: String = _eco_cap_display(snap.get("bread_cap", 999999999))
		eco_market_label.text = (
			"Wheat %d / %s @ $%.2f\nBread %d / %s @ $%.2f\nFirewood %d @ $%.2f · Town purse $%.0f" % [
				snap.get("wheat", 0), wc, snap.get("wheat_price", 0.0),
				snap.get("bread", 0), bc, snap.get("bread_price", 0.0),
				village.market.firewood, village.market.firewood_price, village.market.money
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

	# FARMER: the first living farmer in the village. (It used to follow one fixed person
	# even after they changed trade or died.)
	if eco_farmer_label:
		var fa: Node = _first_live(village.all_farmers)
		if fa == null:
			eco_farmer_label.text = "(none)"
		else:
			var fd: Dictionary = _agent_facts(fa)
			eco_farmer_label.text = (
				"Cash $%.0f · Seeds %d · Wheat %d · Bread %d · Hunger %d/%d\n%s: %s · Inventory %d/%d"
				% [fd.get("cash", 0.0), _qty_of(fa, "seeds"), _qty_of(fa, "wheat"), _qty_of(fa, "bread"),
				   fd.get("hunger_days", 0), fd.get("hunger_max", 5),
				   fd.get("name", "?"), fd.get("status", ""), fd.get("inv_total", 0), fd.get("inv_max", 0)]
			)

	# WORLD summary — aggregated across all villages
	if eco_world_label and _world_node and _world_node.has_method("get_world_summary"):
		var ws: Dictionary = _world_node.get_world_summary()
		eco_world_label.text = (
			"World: %d villages · total pop %d (H %d · F %d · B %d · W %d) · fields %d"
			% [ws.get("village_count", 0), ws.get("total_pop", 0),
			   ws.get("total_households", 0), ws.get("total_farmers", 0),
			   ws.get("total_bakers", 0), ws.get("total_woodworkers", 0), ws.get("total_fields", 0)]
		)

	# BAKER: the first living baker in the village.
	if eco_baker_label:
		var ba: Node = _first_live(village.all_bakers)
		if ba == null:
			eco_baker_label.text = "(none)"
		else:
			var bd: Dictionary = _agent_facts(ba)
			eco_baker_label.text = (
				"Cash $%.0f · Wheat %d · Flour %d · Bread %d · Hunger %d/%d\n%s: %s · Inventory %d/%d"
				% [bd.get("cash", 0.0), _qty_of(ba, "wheat"), _qty_of(ba, "flour"), _qty_of(ba, "bread"),
				   bd.get("hunger_days", 0), bd.get("hunger_max", 5),
				   bd.get("name", "?"), bd.get("status", ""), bd.get("inv_total", 0), bd.get("inv_max", 0)]
			)

	# WOODWORKER: the first living woodworker in the village.
	if eco_woodworker_label:
		var wa: Node = _first_live(village.all_woodworkers)
		if wa == null:
			eco_woodworker_label.text = "(none)"
		else:
			var wd: Dictionary = _agent_facts(wa)
			var made_today: int = 0
			var wjob = wa.get("current_job")
			if wjob != null and is_instance_valid(wjob) and wjob.get("firewood_made_today") != null:
				made_today = int(wjob.get("firewood_made_today"))
			eco_woodworker_label.text = (
				"Cash $%.0f · Firewood %d (made today %d) · Bread %d · Hunger %d/%d\n%s: %s"
				% [wd.get("cash", 0.0), _qty_of(wa, "firewood"), made_today, _qty_of(wa, "bread"),
				   wd.get("hunger_days", 0), wd.get("hunger_max", 5),
				   wd.get("name", "?"), wd.get("status", "")]
			)


## First living person in a list: skips freed nodes and anyone who has already died.
func _first_live(people) -> Node:
	if not (people is Array):
		return null
	for a in people:
		if a == null or not is_instance_valid(a) or a.is_queued_for_deletion():
			continue
		var h = a.get("hunger")
		if h != null and is_instance_valid(h) and h.get("is_starving"):
			continue
		return a as Node
	return null


## Name, cash, hunger, what they are doing and how loaded they are, read from the person.
func _agent_facts(a: Node) -> Dictionary:
	var out: Dictionary = {
		"name": "?", "cash": 0.0, "hunger_days": 0, "hunger_max": 5,
		"status": "", "inv_total": 0, "inv_max": 0,
	}
	if a == null or not is_instance_valid(a):
		return out
	var pn = a.get("person_name")
	out["name"] = str(pn) if (pn != null and str(pn) != "") else str(a.name)
	var w = a.get("wallet")
	if w != null and is_instance_valid(w) and w.get("money") != null:
		out["cash"] = float(w.get("money"))
	var h = a.get("hunger")
	if h != null and is_instance_valid(h):
		if h.get("hunger_days") != null:
			out["hunger_days"] = int(h.get("hunger_days"))
		if h.get("hunger_max_days") != null:
			out["hunger_max"] = int(h.get("hunger_max_days"))
	# Status text is asked for only once the person's job is fully set up (it reads the
	# job's route and hunger).
	var job = a.get("current_job")
	if job != null and is_instance_valid(job) and job.get("route") != null and job.get("hunger") != null \
			and a.has_method("get_status_text"):
		out["status"] = str(a.get_status_text())
	var cap = a.get_node_or_null("InventoryCapacity")
	if cap != null and cap.has_method("current_total"):
		out["inv_total"] = int(cap.current_total())
		if cap.get("max_items") != null:
			out["inv_max"] = int(cap.get("max_items"))
	return out


## How many of one good a person is carrying.
func _qty_of(a: Node, good: String) -> int:
	if a == null or not is_instance_valid(a):
		return 0
	var inv = a.get("inv")
	if inv == null or not is_instance_valid(inv) or not inv.has_method("get_qty"):
		return 0
	return int(inv.get_qty(good))


## Troubles the village is under (a bad harvest and the like), in words. Empty when all is
## well or the village keeps no such record.
func _village_trouble(village: Node) -> String:
	var shocks = village.get("shocks")
	if typeof(shocks) != TYPE_OBJECT or not is_instance_valid(shocks) or not shocks.has_method("describe"):
		return ""
	return str(shocks.describe())


func _eco_cap_display(cap: int) -> String:
	if cap >= 1_000_000_000:
		return "∞"
	if cap >= 1_000_000:
		var m: float = float(cap) / 1_000_000.0
		return ("%.0fM" % m) if m < 100.0 else "∞"
	if cap >= 10_000:
		return "%dk" % int(round(float(cap) / 1000.0))
	return str(cap)


# ── Economy bar widget builder ─────────────────────────────────────────────

func _build_economy_bar(container: Node) -> void:
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
	eco_woodworker_label = _add_eco_section(row2, "WOODWORKER", Color(0.78, 0.55, 0.30), true)

	# Row 3 — world-level summary (totals across all villages)
	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 0)
	row3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_child(row3)
	eco_world_label = _add_eco_section(row3, "WORLD", Color(0.55, 0.80, 1.00), true)

	container.add_child(bar)
	container.move_child(bar, 1)


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
