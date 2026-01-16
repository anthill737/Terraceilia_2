extends Node
class_name FoodNeed

signal ate_meal(qty: int)

# Configuration
var food_item: String = "bread"
var meals_per_day: int = 1
var days_without_food_to_starve: int = 3
var ticks_per_day: int = 10

# State
var days_without_food: int = 0
var last_day_tick: int = -999999
var is_starving: bool = false

# Dependencies (set by owner)
var inv: Inventory = null
var bus: EventBus = null


func bind(inventory: Inventory, event_bus: EventBus) -> void:
	inv = inventory
	bus = event_bus


func on_home_arrival(current_tick: int, agent_name: String) -> void:
	if is_starving:
		return
	
	# Only eat once per day
	if current_tick - last_day_tick < ticks_per_day:
		return
	
	last_day_tick = current_tick
	
	# Attempt to consume meals_per_day of food_item
	if inv.remove(food_item, meals_per_day):
		days_without_food = 0
		if bus:
			bus.log("Tick %d: %s ate %d %s (days_without_food reset to 0)" % [current_tick, agent_name, meals_per_day, food_item])
		emit_signal("ate_meal", meals_per_day)
	else:
		days_without_food += 1
		if bus:
			bus.log("Tick %d: %s had no food to eat (days_without_food=%d/%d)" % [current_tick, agent_name, days_without_food, days_without_food_to_starve])
		
		if days_without_food >= days_without_food_to_starve:
			is_starving = true
			if bus:
				bus.log("Tick %d: %s STARVED and stopped working" % [current_tick, agent_name])
