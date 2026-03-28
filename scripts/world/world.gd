extends Node
class_name WorldManager

## World manager — owns and ticks all Village instances.
## Villages are positioned at fixed world-space offsets; navigation helpers let
## main.gd move the camera and rebind the HUD per-village.

## Horizontal distance between consecutive village origins (world units).
## Increase to add more visual breathing room between villages.
const VILLAGE_SPACING: float = 2000.0

## Approximate centroid offset from a village's local origin to its visual centre.
const VILLAGE_CENTROID_OFFSET: Vector2 = Vector2(400.0, 300.0)

var villages: Array = []

## Index of the village currently in focus (drives camera + HUD).
var _focused_village_idx: int = 0

## Whether inter-village trade is enabled. Agents check this before evaluating moves.
var trade_enabled: bool = false

## Emitted when the player navigates to a different village.
## main.gd connects this to move the camera and rebind the economy HUD.
signal village_focused(idx: int)

## Emitted when trade is toggled. UI connects this to update the button label.
signal trade_toggled(enabled: bool)


func _ready() -> void:
	spawn_initial_villages()


func spawn_initial_villages() -> void:
	var village_scene: PackedScene = load("res://scenes/village/Village.tscn")
	if village_scene == null:
		push_error("WorldManager: could not load Village.tscn — ensure T3 is complete")
		return

	_add_village(village_scene, 0, "Village 1", 12345)
	_add_village(village_scene, 1, "Village 2", 66666)


func _add_village(scene: PackedScene, idx: int, display_name: String, seed: int) -> void:
	var v = scene.instantiate()
	v.name         = "Village%d" % (idx + 1)
	v.position     = Vector2(idx * VILLAGE_SPACING, 0.0)
	v.village_id   = idx + 1
	v.village_name = display_name
	add_child(v)
	v.initialize(seed, {})
	if v.event_bus:
		v.event_bus.village_label = "[%s]" % display_name
	villages.append(v)


## Called by main.gd when SimulationClock emits ticked(tick).
## Forwards the integer tick to every village in fixed insertion order (deterministic).
func on_simulation_tick(tick: int) -> void:
	for v in villages:
		if v and is_instance_valid(v):
			v.receive_tick(tick)


## Navigate focus to village at index idx.
## Emits village_focused(idx) so main.gd can move the camera and rebind the HUD.
func focus_village(idx: int) -> void:
	if idx < 0 or idx >= villages.size():
		return
	_focused_village_idx = idx
	village_focused.emit(idx)


## Returns the currently-focused Village node, or null.
func get_focused_village() -> Node:
	if _focused_village_idx >= 0 and _focused_village_idx < villages.size():
		var v = villages[_focused_village_idx]
		if v and is_instance_valid(v):
			return v
	return null


## Returns the world-space camera target for village at idx.
## Uses a fixed centroid offset so the camera lands on the village's activity area.
func get_village_center_by_idx(idx: int) -> Vector2:
	if idx < 0 or idx >= villages.size():
		return Vector2.ZERO
	var v = villages[idx]
	if v and is_instance_valid(v) and v is Node2D:
		return (v as Node2D).global_position + VILLAGE_CENTROID_OFFSET
	return Vector2(float(idx) * VILLAGE_SPACING, 0.0) + VILLAGE_CENTROID_OFFSET


## Returns the world-space centre of a village node (legacy overload for direct node ref).
## Used by the camera navigation buttons.
func get_village_center(v: Node) -> Vector2:
	if v == null or not is_instance_valid(v):
		return Vector2.ZERO
	return (v as Node2D).global_position + VILLAGE_CENTROID_OFFSET


## Returns the world-space centre across all villages — useful for a zoom-out view.
func get_world_center() -> Vector2:
	if villages.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for i in range(villages.size()):
		sum += get_village_center_by_idx(i)
	return sum / float(villages.size())


## Returns the total world width spanned by all villages.
## main.gd uses this to pick a zoom level for the zoom-out view.
func get_world_span() -> float:
	if villages.size() <= 1:
		return VILLAGE_SPACING
	return float(villages.size() - 1) * VILLAGE_SPACING + VILLAGE_CENTROID_OFFSET.x * 2.0


## Returns a Dictionary summing population and field counts across all villages.
## Used by the HUD world-summary line.
func get_world_summary() -> Dictionary:
	var out := {
		"village_count":    villages.size(),
		"total_pop":        0,
		"total_farmers":    0,
		"total_bakers":     0,
		"total_households": 0,
		"total_fields":     0,
	}
	for v in villages:
		if not (v and is_instance_valid(v)):
			continue
		var pop: Dictionary = v.get_population_summary()
		out["total_pop"]        += pop.get("total",      0)
		out["total_farmers"]    += pop.get("farmers",    0)
		out["total_bakers"]     += pop.get("bakers",     0)
		out["total_households"] += pop.get("households", 0)
		out["total_fields"]     += pop.get("fields",     0)
	return out


## Returns the combined population across all villages (convenience shorthand).
func get_world_population() -> int:
	var total: int = 0
	for v in villages:
		if v and is_instance_valid(v) and v.has_method("get_population_summary"):
			total += v.get_population_summary().get("total", 0)
	return total


## Returns the Village at index idx, or null if out of range.
func get_village(idx: int) -> Village:
	if idx >= 0 and idx < villages.size():
		var v = villages[idx]
		if v and is_instance_valid(v):
			return v as Village
	return null


func get_village_count() -> int:
	return villages.size()


## Returns all Village nodes in deterministic insertion order.
## Agents use this to iterate all villages during trade evaluation.
func get_all_villages() -> Array:
	return villages


# ── Trade toggle ───────────────────────────────────────────────────────────────

## Toggles inter-village trade on/off and emits trade_toggled.
## Connected to the Trade button in the top bar (see main.gd / trade panel).
func toggle_trade() -> void:
	trade_enabled = !trade_enabled
	trade_toggled.emit(trade_enabled)
	print("[TRADE TOGGLE] trade_enabled=%s" % str(trade_enabled))


# ── Market query API (used by FarmerJob / BakerJob for trade evaluation) ───────

## Returns a snapshot of a single village's market state.
## Agents use this to compute expected_profit = sell_price - local_price - travel_cost.
##
## Keys:
##   village_ref   — Village node (use to switch current_village_ref on arrival)
##   village_id    — int  (stable identifier across ticks)
##   world_pos     — Vector2  (village global_position; used for travel cost)
##   wheat_price   — float
##   bread_price   — float
##   wheat_qty     — int   (current market inventory)
##   bread_qty     — int
##   wheat_buy_blocked — bool  (market won't accept wheat; selling is pointless)
##   bread_buy_blocked — bool  (market won't accept bread; selling is pointless)
func get_village_market_snapshot(village: Node) -> Dictionary:
	if village == null or not is_instance_valid(village):
		return {}
	var m = village.market
	if m == null or not is_instance_valid(m):
		return {}
	return {
		"village_ref":       village,
		"village_id":        village.village_id,
		"world_pos":         village.global_position,
		"wheat_price":       m.wheat_price,
		"bread_price":       m.bread_price,
		"wheat_qty":         m.wheat,
		"bread_qty":         m.bread,
		"wheat_buy_blocked": m.wheat_market_buy_blocked,
		"bread_buy_blocked": m.bread_market_buy_blocked,
	}


## Returns market snapshots for every village in deterministic insertion order.
## Agents iterate this array when scanning for the best trade destination.
func get_all_village_market_snapshots() -> Array:
	var out: Array = []
	for v in villages:
		if v and is_instance_valid(v):
			var snap := get_village_market_snapshot(v)
			if not snap.is_empty():
				out.append(snap)
	return out