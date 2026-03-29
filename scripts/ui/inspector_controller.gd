class_name InspectorController
extends Node

## Controls the PopInspectorDock: agent selection, display refresh, and dismiss handling.
## Extracted from main.gd (Phase 5 refactor). main.gd delegates all inspector logic here.

const POP_PICK_RADIUS_WORLD: float = 16.0

var _inspector_dock: PopInspectorDock = null
var _village_ref: Node = null
var selected_pop: Node = null


## Wire the controller to the PopInspectorDock node and the active village.
## Call once from main after the UI tree is ready.
func setup(inspector_dock: PopInspectorDock, village: Node) -> void:
	_inspector_dock = inspector_dock
	_village_ref = village
	if _inspector_dock == null:
		push_warning("InspectorController.setup: inspector_dock is null — inspector disabled")
		return
	var econ_stats = village.econ_stats if (village != null and village.get("econ_stats") != null) else null
	var max_f: int = village.field_mgr.MAX_FIELDS if (village != null and village.field_mgr != null) else 10
	_inspector_dock.configure(econ_stats, max_f, Callable(self, "_get_field_count"))
	if not _inspector_dock.dismiss_requested.is_connected(_on_dismiss):
		_inspector_dock.dismiss_requested.connect(_on_dismiss)


## Update the village reference when the selected village changes.
func set_village(village: Node) -> void:
	_village_ref = village


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
	_inspector_dock.refresh(selected_pop)


# ── Private ─────────────────────────────────────────────────────────────────────

func _on_dismiss() -> void:
	selected_pop = null


func _get_field_count() -> int:
	if _village_ref == null or not is_instance_valid(_village_ref):
		return 0
	return _village_ref.get_population_summary().get("fields", 0)
