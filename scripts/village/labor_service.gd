class_name LaborService
extends Node

## Handles labor market signal responses: migration removal and role-switch training queues.
## Extracted from village.gd (Phase 6 refactor). Village delegates signal handlers here.
##
## _perform_role_conversion() is intentionally kept in village.gd because it requires
## scene-tree access (add_child) and spawn helpers that are tightly coupled to Village.
## This service calls it via a Callable passed into tick_day() to avoid circular deps.

# ── State ───────────────────────────────────────────────────────────────────────
## Training queue: Array of {household: Node, role: String, days_remaining: int}
var pending_conversions: Array = []

# ── Injected references ─────────────────────────────────────────────────────────
var _pop_mgr:   PopulationManager = null
var _field_mgr: FieldManager      = null
var _event_bus: EventBus          = null


## Wire the service to the village's managers and event bus.
## Call once from village.initialize() after all managers are created.
func bind(pop_mgr: PopulationManager, field_mgr: FieldManager, event_bus: EventBus) -> void:
	_pop_mgr = pop_mgr
	_field_mgr = field_mgr
	_event_bus = event_bus


## Signal handler for labor_market.migrate_requested.
## Removes the departing agent from all village arrays and frees it.
func handle_migrate_requested(agent: Node, reason: String) -> void:
	if not is_instance_valid(agent):
		return
	var died: bool = reason == "starved"
	if _event_bus and not died:
		_event_bus.emit_log("[MIGRATION] %s leaving (reason: %s)" % [agent.name, reason])

	if _pop_mgr:
		var h_idx: int = _pop_mgr.households.find(agent)
		if h_idx != -1:
			_pop_mgr.households.remove_at(h_idx)
			agent.remove_from_group("households")
			agent.remove_from_group("agents")

		var f_idx: int = _pop_mgr.all_farmers.find(agent)
		if f_idx != -1:
			_pop_mgr.all_farmers.remove_at(f_idx)
			if _field_mgr:
				for fn in _field_mgr.all_field_nodes:
					if is_instance_valid(fn) and _field_mgr.field_assignment_map.get(fn, null) == agent:
						_field_mgr.field_assignment_map[fn] = null
			if agent.has_method("clear_fields_for_removal"):
				agent.clear_fields_for_removal()

		var b_idx: int = _pop_mgr.all_bakers.find(agent)
		if b_idx != -1:
			_pop_mgr.all_bakers.remove_at(b_idx)
		_pop_mgr.all_woodworkers.erase(agent)
		_pop_mgr.all_smiths.erase(agent)
		_pop_mgr.all_tailors.erase(agent)

	pending_conversions = pending_conversions.filter(
		func(e): return is_instance_valid(e["household"]) and e["household"] != agent
	)

	if agent.has_method("log_event") and not died:
		agent.log_event("Left town — %s." % reason)
	var _migrated_name: String = agent.name
	agent.queue_free()
	if _event_bus:
		_event_bus.emit_log("[MIGRATE CONFIRM] %s removed (reason: %s)" % [_migrated_name, reason])


## Signal handler for labor_market.role_switch_requested.
## Queues a training period; conversion fires when days_remaining reaches zero.
func handle_role_switch_requested(household: Node, new_role: String) -> void:
	if not is_instance_valid(household):
		return

	for entry in pending_conversions:
		if entry["household"] == household:
			return

	var training_days: int = LaborMarket.BAKER_TRAINING_DAYS if new_role == "baker" else LaborMarket.FARMER_TRAINING_DAYS
	if _event_bus:
		_event_bus.emit_log("[MOBILITY] %s: training to become %s (%d days)" % [household.name, new_role, training_days])
	if household.has_method("log_event"):
		household.log_event("Started training to become a %s (%d days to go)." % [new_role.capitalize(), training_days])

	pending_conversions.append({"household": household, "role": new_role, "days_remaining": training_days})


## Process the training queue for one day. Each ready entry triggers perform_conversion.
## perform_conversion: Callable(household: Node, role: String) — village._perform_role_conversion
func tick_day(perform_conversion: Callable) -> void:
	var still_pending: Array = []
	for entry in pending_conversions:
		var h = entry["household"]
		var role: String = entry["role"]
		var days_left: int = entry["days_remaining"] - 1
		if not is_instance_valid(h):
			continue
		if days_left <= 0:
			perform_conversion.call(h, role)
		else:
			entry["days_remaining"] = days_left
			still_pending.append(entry)
	pending_conversions = still_pending
