extends Node2D
class_name VillageArt
## Draws a village: ground, roads, market, bakery, farmhouse, lumber yard, the shelter and
## every house from Housing. Drawn under the people and fields. Pure drawing, no economy.

var village = null
var _t := 0.0

const GRASS := Color(0.30, 0.42, 0.24)
const GRASS_EDGE := Color(0.26, 0.36, 0.21)
const ROAD := Color(0.55, 0.45, 0.32)
const WOOD := Color(0.55, 0.36, 0.20)
const WOOD_DARK := Color(0.36, 0.23, 0.12)
const STONE := Color(0.62, 0.60, 0.56)
const PLASTER := Color(0.86, 0.80, 0.66)
const ROOF_OWNED := Color(0.62, 0.22, 0.16)
const ROOF_RENTED := Color(0.25, 0.40, 0.66)
const ROOF_EMPTY := Color(0.45, 0.45, 0.45)
const TEXT := Color(0.96, 0.94, 0.86)
const TEXT_DIM := Color(0.85, 0.85, 0.80, 0.85)


func _process(delta: float) -> void:
	_t += delta
	if _t >= 0.25:
		_t = 0.0
		_hide_markers()
		queue_redraw()


func _hide_markers() -> void:
	if village == null:
		return
	for n in village.get_children():
		if n is Node2D and not (n is CharacterBody2D) and n.name != "AgentContainer":
			for c in n.get_children():
				if c is ColorRect and c.visible:
					c.visible = false


func _pos(path: String) -> Variant:
	if village == null:
		return null
	var n = village.get_node_or_null(path)
	return n.position if n is Node2D else null


func _label(p: Vector2, text: String, size: int = 13, col: Color = TEXT) -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(font, p + Vector2(-w * 0.5 + 1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.6))
	draw_string(font, p + Vector2(-w * 0.5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _house_shape(c: Vector2, wall: Color, roof: Color, s: float = 1.0) -> void:
	var w := 14.0 * s
	draw_rect(Rect2(c + Vector2(-w, -9 * s), Vector2(w * 2, 20 * s)), wall)
	draw_rect(Rect2(c + Vector2(-w, -9 * s), Vector2(w * 2, 20 * s)), WOOD_DARK, false, 1.0)
	draw_colored_polygon(PackedVector2Array([c + Vector2(-w - 4 * s, -9 * s), c + Vector2(0, -24 * s), c + Vector2(w + 4 * s, -9 * s)]), roof)
	draw_rect(Rect2(c + Vector2(-3 * s, 2 * s), Vector2(6 * s, 9 * s)), WOOD_DARK)


func _draw() -> void:
	if village == null:
		return
	var centre: Vector2 = village.to_local(village.village_center) if village.village_center != Vector2.ZERO else Vector2(400, 300)
	var r: float = village.spawn_radius + 70.0
	draw_circle(centre, r + 8.0, GRASS_EDGE)
	draw_circle(centre, r, GRASS)

	var market = _pos("MarketNode")
	var bakery = _pos("Bakery")
	var farm = _pos("House")
	var shelter = _pos("HouseholdHome")
	var yard = village.lumber_yard.position if village.get("lumber_yard") != null and is_instance_valid(village.lumber_yard) else null
	var housing = village.get("housing")
	var houses: Array = housing.houses if housing != null else []
	var homes_at: Vector2 = Housing.HOUSE_ORIGIN + Vector2(Housing.HOUSE_COLS * Housing.HOUSE_DX * 0.5 - Housing.HOUSE_DX * 0.5, 0)

	# Roads from the market square to everything.
	if market != null:
		for target in [bakery, farm, shelter, yard, homes_at]:
			if target != null:
				draw_line(market, target, ROAD, 9.0)
		for f in village.all_field_nodes:
			if f != null and is_instance_valid(f):
				draw_line(market, f.position, Color(ROAD, 0.55), 5.0)
		draw_circle(market, 34.0, ROAD)

	# Market stall.
	if market != null:
		draw_rect(Rect2(market + Vector2(-26, -10), Vector2(52, 24)), WOOD)
		for i in 6:
			var c := Color(0.80, 0.20, 0.18) if i % 2 == 0 else Color(0.95, 0.92, 0.84)
			draw_rect(Rect2(market + Vector2(-30 + i * 10, -24), Vector2(10, 14)), c)
		draw_rect(Rect2(market + Vector2(-22, -4), Vector2(10, 7)), Color(0.85, 0.65, 0.30))  # bread
		draw_rect(Rect2(market + Vector2(-6, -4), Vector2(10, 7)), Color(0.90, 0.80, 0.35))   # wheat
		draw_rect(Rect2(market + Vector2(10, -4), Vector2(10, 7)), WOOD_DARK)                  # wood
		_label(market + Vector2(0, 30), "Market", 14)
		var m = village.market
		if m:
			_label(market + Vector2(0, 45), "bread %d  wheat %d  wood %d" % [m.bread, m.wheat, m.firewood], 11, TEXT_DIM)

	# Bakery: stone house with a chimney and smoke.
	if bakery != null:
		draw_rect(Rect2(bakery + Vector2(12, -36), Vector2(8, 18)), STONE.darkened(0.2))
		_house_shape(bakery, STONE, Color(0.48, 0.30, 0.20), 1.6)
		var phase := fmod(Time.get_ticks_msec() / 900.0, 1.0)
		for i in 3:
			var k := fmod(phase + i / 3.0, 1.0)
			draw_circle(bakery + Vector2(16 + k * 10, -40 - k * 26), 4 + k * 5, Color(0.85, 0.85, 0.85, 0.45 * (1.0 - k)))
		_label(bakery + Vector2(0, 34), "Bakery", 14)

	# Farmhouse.
	if farm != null:
		_house_shape(farm, PLASTER, Color(0.70, 0.55, 0.25), 1.4)
		_label(farm + Vector2(0, 32), "Farmhouse", 13)

	# Farmhouses and bakeries opened later (spots named <Person>_Home / <Person>_Bakery),
	# only while that person still works there.
	var farmer_names := {}
	for f in village.all_farmers:
		if f != null and is_instance_valid(f):
			farmer_names[str(f.name)] = true
	var baker_names := {}
	for b in village.all_bakers:
		if b != null and is_instance_valid(b):
			baker_names[str(b.name)] = true
	for n in village.get_children():
		if not (n is Node2D):
			continue
		var nm: String = str(n.name)
		if nm.ends_with("_Home") and farmer_names.has(nm.trim_suffix("_Home")):
			_house_shape(n.position, PLASTER, Color(0.70, 0.55, 0.25), 1.2)
			_label(n.position + Vector2(0, 28), "Farmhouse", 11, TEXT_DIM)
		elif nm.ends_with("_Bakery") and baker_names.has(nm.trim_suffix("_Bakery")):
			_house_shape(n.position, STONE, Color(0.48, 0.30, 0.20), 1.3)
			_label(n.position + Vector2(0, 30), "Bakery", 11, TEXT_DIM)

	# Shelter where people with no house sleep.
	if shelter != null:
		draw_colored_polygon(PackedVector2Array([shelter + Vector2(-16, 10), shelter + Vector2(0, -14), shelter + Vector2(16, 10)]), Color(0.66, 0.60, 0.46))
		draw_line(shelter + Vector2(0, -14), shelter + Vector2(0, 10), WOOD_DARK, 2.0)
		_label(shelter + Vector2(0, 26), "Shelter", 12, TEXT_DIM)

	# Lumber yard: trees and a log pile.
	if yard != null:
		for o in [Vector2(-34, -18), Vector2(30, -24), Vector2(40, 8)]:
			draw_rect(Rect2(yard + o + Vector2(-2, 2), Vector2(4, 10)), WOOD_DARK)
			draw_colored_polygon(PackedVector2Array([yard + o + Vector2(-11, 4), yard + o + Vector2(0, -20), yard + o + Vector2(11, 4)]), Color(0.16, 0.38, 0.18))
		for row in 3:
			for i in 4 - row:
				var p: Vector2 = yard + Vector2(-15 + i * 9 + row * 4.5, 8 - row * 8)
				draw_circle(p, 4.6, WOOD)
				draw_circle(p, 2.0, Color(0.80, 0.62, 0.40))
		_label(yard + Vector2(0, 30), "Lumber Yard", 13)

	# Houses.
	for h in houses:
		var c: Vector2 = h.get("pos", Vector2.ZERO)
		if not h.done:
			draw_rect(Rect2(c + Vector2(-14, -9), Vector2(28, 20)), Color(0.75, 0.62, 0.42, 0.5), false, 2.0)
			draw_line(c + Vector2(-14, 11), c + Vector2(14, -9), WOOD, 2.0)
			draw_line(c + Vector2(-14, -9), c + Vector2(14, 11), WOOD, 2.0)
			var frac: float = 0.5 * float(h.wood) / Housing.HOUSE_WOOD + 0.5 * float(h.work) / Housing.BUILD_DAYS
			draw_rect(Rect2(c + Vector2(-14, 15), Vector2(28, 4)), Color(0, 0, 0, 0.5))
			draw_rect(Rect2(c + Vector2(-14, 15), Vector2(28 * frac, 4)), Color(0.95, 0.80, 0.30))
			_label(c + Vector2(0, 31), "building", 9, TEXT_DIM)
			continue
		var roof := ROOF_EMPTY
		var tag := ""
		if h.occupant == null:
			tag = "for sale" if h.owner == null else "to let"
		elif h.occupant == h.owner:
			roof = ROOF_OWNED
		else:
			roof = ROOF_RENTED
		_house_shape(c, PLASTER if h.occupant != null else PLASTER.darkened(0.3), roof)
		var who: String = tag if tag != "" else _short(h.occupant)
		_label(c + Vector2(0, 24), who, 9, TEXT_DIM if tag == "" else Color(1.0, 0.85, 0.45))

	# Legend.
	var lg := centre + Vector2(-r + 40, r - 30)
	var items := [["Farmer", Color(0.2, 1, 0.2)], ["Baker", Color(0.8, 0.6, 0.2)], ["Woodworker", Color(0.6, 0.4, 0.2)], ["Household", Color(1, 0.4, 1)]]
	for i in items.size():
		draw_rect(Rect2(lg + Vector2(0, i * 14), Vector2(9, 9)), items[i][1])
		draw_string(ThemeDB.fallback_font, lg + Vector2(14, i * 14 + 9), items[i][0], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, TEXT_DIM)
	var roofs := [["Owner lives here", ROOF_OWNED], ["Rented", ROOF_RENTED], ["Empty", ROOF_EMPTY]]
	for i in roofs.size():
		draw_colored_polygon(PackedVector2Array([lg + Vector2(100, i * 14 + 10), lg + Vector2(105, i * 14), lg + Vector2(110, i * 14 + 10)]), roofs[i][1])
		draw_string(ThemeDB.fallback_font, lg + Vector2(116, i * 14 + 9), roofs[i][0], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, TEXT_DIM)


func _short(a) -> String:
	if a == null or not is_instance_valid(a):
		return ""
	var s: String = str(a.name)
	for pre in ["Household", "Woodworker", "Farmer", "Baker"]:
		if s.begins_with(pre):
			var rest: String = s.substr(pre.length()).replace("_", "").replace("Agent", "")
			return {"Household": "H", "Woodworker": "Wood"}.get(pre, pre) + rest
	return s.substr(0, 7)
