class_name InspectorController
extends Node

## Controls the PopInspectorDock: agent selection, display refresh, and dismiss handling.
## Extracted from main.gd (Phase 5 refactor). main.gd delegates all inspector logic here.

const POP_PICK_RADIUS_WORLD: float = 16.0

var _inspector_dock: PopInspectorDock = null
var _village_ref: Node = null
## World node: its `villages` list is used to find a person's home village by id.
var _world_ref: Node = null
## Village the dock's economy numbers and land counts are set up for right now.
var _configured_village: Node = null
var selected_pop: Node = null


## Wire the controller to the PopInspectorDock node and the active village.
## Call once from main after the UI tree is ready.
func setup(inspector_dock: PopInspectorDock, village: Node) -> void:
	_inspector_dock = inspector_dock
	_village_ref = village
	if _inspector_dock == null:
		push_warning("InspectorController.setup: inspector_dock is null — inspector disabled")
		return
	_configure_for(village)
	if not _inspector_dock.dismiss_requested.is_connected(_on_dismiss):
		_inspector_dock.dismiss_requested.connect(_on_dismiss)


## Update the village reference when the selected village changes.
func set_village(village: Node) -> void:
	_village_ref = village


## Give the controller the World node so a person's home village can be found by id.
func set_world(world: Node) -> void:
	_world_ref = world


## The village a person belongs to: their home_village_ref when it is set, otherwise the
## village in World.villages whose village_id matches their home_village_id. Null if neither
## is known.
func home_village_of(pop: Node) -> Node:
	if pop == null or not is_instance_valid(pop):
		return null
	var hv = pop.get("home_village_ref")
	if hv != null and is_instance_valid(hv):
		return hv as Node
	var hid = pop.get("home_village_id")
	if not (hid is int) or _world_ref == null or not is_instance_valid(_world_ref):
		return null
	var all_villages = _world_ref.get("villages")
	if not (all_villages is Array):
		return null
	for v in all_villages:
		if v != null and is_instance_valid(v) and v.get("village_id") == hid:
			return v as Node
	return null


## Called when the player clicks on an agent in the world.
func handle_pop_clicked(agent: Node) -> void:
	if not is_instance_valid(agent):
		return
	selected_pop = agent
	refresh()


## Refresh the inspector display for the currently selected pop.
## Safe to call when nothing is selected — dock will clear itself.
func refresh() -> void:
	if _inspector_dock == null:
		return
	if selected_pop == null or not is_instance_valid(selected_pop):
		selected_pop = null
	else:
		# Economy numbers and land counts come from the selected person's own village, not
		# from whichever village the dock was first set up with.
		var home: Node = home_village_of(selected_pop)
		var stats_village: Node = home if home != null else _village_ref
		if stats_village != _configured_village:
			_configure_for(stats_village)
		_inspector_dock.set_home_village(home)
	_inspector_dock.refresh(selected_pop)


# ── Private ─────────────────────────────────────────────────────────────────────

func _on_dismiss() -> void:
	selected_pop = null


## Point the dock's economy stats, field cap and field count at one village.
func _configure_for(village: Node) -> void:
	if _inspector_dock == null:
		return
	var ok: bool = village != null and is_instance_valid(village)
	_configured_village = village if ok else null
	var econ_stats = village.get("econ_stats") if ok else null
	var field_mgr = village.get("field_mgr") if ok else null
	var max_f: int = 10
	if field_mgr != null and is_instance_valid(field_mgr):
		max_f = int(field_mgr.MAX_FIELDS)
	_inspector_dock.configure(econ_stats, max_f, Callable(self, "_get_field_count"))


func _get_field_count() -> int:
	var v: Node = _configured_village
	if v == null or not is_instance_valid(v):
		v = _village_ref
	if v == null or not is_instance_valid(v) or not v.has_method("get_population_summary"):
		return 0
	return int(v.get_population_summary().get("fields", 0))
