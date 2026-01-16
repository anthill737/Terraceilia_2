extends Node
class_name HungerNeed

signal starved(agent_name: String)

# Configuration
var food_item: String = "bread"
var hunger_max_days: int = 5
var eat_restore_days: int = 1
var deplete_per_day: int = 1
var auto_eat_enabled: bool = true
var auto_eat_threshold_ratio: float = 0.5  # 50%
var auto_eat_max_per_day: int = 1

# State
var hunger_days: int = 5
var is_starving: bool = false
var last_auto_eat_day: int = -999999
var ate_today: bool = false

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
	
	# Reset daily eating flag
	ate_today = false
	
	# Deplete hunger
	hunger_days = max(0, hunger_days - deplete_per_day)
	
	if bus:
		bus.log("Day %d: %s hunger %d/%d" % [day, agent_name, hunger_days, hunger_max_days])
	
	# Try auto-eat if hunger is at or below threshold
	if auto_eat_enabled and hunger_days <= int(ceil(float(hunger_max_days) * auto_eat_threshold_ratio)):
		if calendar != null:
			try_auto_eat(calendar.tick)
	
	# Check for starvation AFTER auto-eat attempt
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


func try_auto_eat(current_tick: int) -> bool:
	if not auto_eat_enabled:
		return false
	
	if is_starving:
		return false
	
	if ate_today:
		return false  # Already ate today
	
	if calendar == null:
		return false
	
	var day = calendar.day_index
	if day == last_auto_eat_day:
		return false  # max once per day
	
	var threshold = int(ceil(float(hunger_max_days) * auto_eat_threshold_ratio))
	if hunger_days > threshold:
		return false
	
	# Attempt to eat 1 bread
	var bread_before: int = inv.get_qty(food_item) if inv != null else 0
	if inv != null and inv.remove(food_item, 1):
		var bread_after: int = inv.get_qty(food_item)
		var hunger_before: int = hunger_days
		hunger_days = min(hunger_max_days, hunger_days + eat_restore_days)
		last_auto_eat_day = day
		ate_today = true
		if bus:
			bus.log("Tick %d: %s ate 1 bread (bread %d→%d), hunger %d/%d→%d/%d" % [current_tick, agent_name, bread_before, bread_after, hunger_before, hunger_max_days, hunger_days, hunger_max_days])
		return true
	
	return false
