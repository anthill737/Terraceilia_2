extends Node
class_name FoodStockpile

# Configuration
var food_item: String = "bread"
var target_buffer: int = 3
var max_buffer: int = 6

# Dependencies (set by owner)
var inv: Inventory = null
var market_shocks = null  # Optional shock system reference (MarketShocks instance)


func bind(inventory: Inventory) -> void:
	inv = inventory


func bind_shocks(shocks) -> void:
	market_shocks = shocks


func needed_to_reach_target() -> int:
	if not inv:
		return 0
	
	# Calculate effective target with demand shock bonus
	var effective_target: int = target_buffer
	if market_shocks and market_shocks.should_apply_demand_shock():
		effective_target += market_shocks.get_demand_shock_extra_food()
	
	return max(0, effective_target - inv.get_qty(food_item))
