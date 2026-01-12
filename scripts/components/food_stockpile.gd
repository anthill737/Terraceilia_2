extends Node
class_name FoodStockpile

# Configuration
var food_item: String = "bread"
var target_buffer: int = 3
var max_buffer: int = 6

# Dependencies (set by owner)
var inv: Inventory = null


func bind(inventory: Inventory) -> void:
	inv = inventory


func needed_to_reach_target() -> int:
	if not inv:
		return 0
	return max(0, target_buffer - inv.get_qty(food_item))
