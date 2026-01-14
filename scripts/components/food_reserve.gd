extends Node
class_name FoodReserve

## Universal survival mechanic for all actors.
## Prevents starvation traps by prioritizing food acquisition over work/production.
## Works alongside profit-aware production - production can pause, survival continues.
##
## IMPORTANT: Producers (e.g., Baker) can buy their own output (e.g., bread) when:
## 1. In survival mode (food reserve critically low), OR
## 2. Production is profit-paused (cannot produce their own food)
## This override is handled by the Market guard rail.

# Configuration (data-driven, no hard-coding in actor scripts)
var food_good: String = "bread"  # Which good is edible
var min_reserve_units: int = 3  # Minimum food buffer to maintain
var critical_hunger_ratio: float = 0.5  # Enter survival if hunger <= (max * this ratio)
var survival_purchase_cap: int = 5  # Max units to buy per survival attempt

# State tracking (prevents log spam)
var is_survival_mode: bool = false
var survival_override_active: bool = false  # True when survival mode AND market has no food
var last_survival_check_tick: int = -1
var last_override_state: bool = false  # For state-change-only logging

# Dependencies
var inv: Inventory = null
var hunger: HungerNeed = null
var market: Market = null
var wallet: Wallet = null
var event_bus: EventBus = null
var agent_name: String = ""
var current_tick: int = 0
var actor: Node = null  # Reference to the owning actor (for market API calls)


func bind(_inv: Inventory, _hunger: HungerNeed, _market: Market, _wallet: Wallet, _event_bus: EventBus, _agent_name: String) -> void:
	inv = _inv
	hunger = _hunger
	market = _market
	wallet = _wallet
	event_bus = _event_bus
	agent_name = _agent_name
	actor = get_parent()  # Get reference to owning actor


func set_tick(tick: int) -> void:
	current_tick = tick


## Check if actor should enter survival mode.
## Returns true if food reserve is critically low OR hunger is critical.
## Logs only on state change.
func check_survival_mode() -> bool:
	if inv == null or hunger == null:
		return false
	
	var current_food: int = inv.get_qty(food_good)
	var hunger_critical: bool = false
	
	# Check hunger criticality
	if hunger.hunger_max_days > 0:
		var hunger_ratio: float = float(hunger.hunger_days) / float(hunger.hunger_max_days)
		hunger_critical = hunger_ratio <= critical_hunger_ratio
	
	# Determine survival mode
	var needs_survival: bool = (current_food < min_reserve_units) or hunger_critical
	
	# Log state change only
	if needs_survival != is_survival_mode:
		is_survival_mode = needs_survival
		
		if event_bus:
			if is_survival_mode:
				var reason: String = ""
				if current_food < min_reserve_units and hunger_critical:
					reason = "food reserve low (%d/%d) AND hunger critical (%d/%d)" % [current_food, min_reserve_units, hunger.hunger_days, hunger.hunger_max_days]
				elif current_food < min_reserve_units:
					reason = "food reserve low (%d/%d)" % [current_food, min_reserve_units]
				else:
					reason = "hunger critical (%d/%d)" % [hunger.hunger_days, hunger.hunger_max_days]
				event_bus.log("Tick %d: %s SURVIVAL MODE ON (%s)" % [current_tick, agent_name, reason])
			else:
				event_bus.log("Tick %d: %s SURVIVAL MODE OFF (reserve restored: %d/%d, hunger: %d/%d)" % [current_tick, agent_name, current_food, min_reserve_units, hunger.hunger_days, hunger.hunger_max_days])
	
	last_survival_check_tick = current_tick
	return is_survival_mode


## Check if market has food available for purchase.
## Used to determine if survival override should activate.
func check_market_availability() -> bool:
	if market == null:
		return false
	# Check if market has any bread in stock
	return market.bread > 0


## Update survival override state.
## Survival override activates when:
## 1. Actor is in survival mode (food critically low)
## 2. Market has no food available
## This allows food producers to produce for subsistence even if profit-paused.
func update_survival_override() -> void:
	var market_has_food: bool = check_market_availability()
	var should_override: bool = is_survival_mode and not market_has_food
	
	# Log only on state change
	if should_override != last_override_state:
		survival_override_active = should_override
		last_override_state = should_override
		
		if event_bus:
			if survival_override_active:
				event_bus.log("Tick %d: %s SURVIVAL OVERRIDE ON (market food unavailable)" % [current_tick, agent_name])
			else:
				var reason: String = "food reserve restored" if not is_survival_mode else "market supply available"
				event_bus.log("Tick %d: %s SURVIVAL OVERRIDE OFF (%s)" % [current_tick, agent_name, reason])
	else:
		survival_override_active = should_override


## Get how many units of food are needed to reach minimum reserve.
func get_food_deficit() -> int:
	if inv == null:
		return 0
	var current_food: int = inv.get_qty(food_good)
	return max(0, min_reserve_units - current_food)


## Attempt to buy food from market to restore reserve.
## Returns units actually purchased.
## Respects survival_purchase_cap and affordability.
## Returns 0 immediately if market has no food (prevents infinite buy-loop).
func attempt_survival_purchase() -> int:
	if market == null or wallet == null or inv == null:
		return 0
	
	if not is_survival_mode:
		return 0
	
	# CRITICAL: Check if market actually has food before attempting purchase
	# If market has 0 food, return immediately - don't trap actor in buy-loop
	if not check_market_availability():
		return 0
	
	# Calculate how much to buy
	var deficit: int = get_food_deficit()
	if deficit <= 0:
		return 0
	
	var target_buy: int = min(deficit, survival_purchase_cap)
	
	# Use market API to buy food (pass actor, not component)
	if actor == null:
		actor = get_parent()
	
	var bought: int = market.sell_bread_to_agent(actor, target_buy)
	
	if bought > 0:
		inv.add(food_good, bought)
		if event_bus:
			event_bus.log("Tick %d: %s survival purchase: bought %d %s (reserve now %d/%d)" % [current_tick, agent_name, bought, food_good, inv.get_qty(food_good), min_reserve_units])
	
	return bought


## Check if actor has adequate food reserve (not in survival mode).
func has_adequate_reserve() -> bool:
	return not is_survival_mode


## Get current reserve status for debugging/UI.
func get_reserve_status() -> Dictionary:
	var current_food: int = inv.get_qty(food_good) if inv else 0
	return {
		"current": current_food,
		"minimum": min_reserve_units,
		"deficit": get_food_deficit(),
		"survival_mode": is_survival_mode,
		"hunger_days": hunger.hunger_days if hunger else 0,
		"hunger_max": hunger.hunger_max_days if hunger else 0
	}
