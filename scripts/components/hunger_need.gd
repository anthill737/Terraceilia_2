extends Node
class_name HungerNeed

signal starved(agent_name: String)

# Configuration
var food_item: String = "bread"
var hunger_max_days: int = 3
var eat_restore_days: int = 1
var deplete_per_day: int = 1

# State
var hunger_days: int = 3
var is_starving: bool = false

# Dependencies (set by owner)
var inv: Inventory = null
var bus: EventBus = null
var calendar: Calendar = null
var agent_name: String = ""


func bind(_agent_name: String, inventory: Inventory, event_bus: EventBus, cal: Calendar) -> void:
	agent_name = _agent_name
	inv = inventory
	bus = event_bus
	calendar = cal
	hunger_days = hunger_max_days
	
	if calendar != null:
		calendar.day_changed.connect(_on_day_changed)


func _on_day_changed(day: int) -> void:
	if is_starving:
		return
	
	hunger_days = max(0, hunger_days - deplete_per_day)
	
	if bus:
		bus.log("Day %d: %s hunger %d/%d" % [day, agent_name, hunger_days, hunger_max_days])
	
	if hunger_days <= 0:
		is_starving = true
		if bus:
			bus.log("Day %d: %s STARVED" % [day, agent_name])
		emit_signal("starved", agent_name)


func try_eat(current_tick: int) -> bool:
	if is_starving:
		return false
	
	if inv == null:
		return false
	
	if inv.remove(food_item, 1):
		hunger_days = min(hunger_max_days, hunger_days + eat_restore_days)
		if bus:
			bus.log("Tick %d: %s ate 1 %s (hunger %d/%d)" % [current_tick, agent_name, food_item, hunger_days, hunger_max_days])
		return true
	
	return false
