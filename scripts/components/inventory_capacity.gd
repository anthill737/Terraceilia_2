extends Node
class_name InventoryCapacity

## Limits the total number of non-money items an agent can hold.
## Bind to an Inventory component to enforce capacity limits.

var max_items: int = 50  # Total item units allowed (universal for all agents)
var inv: Inventory = null


func bind(inventory: Inventory) -> void:
	inv = inventory


func current_total() -> int:
	if inv == null:
		return 0
	var total: int = 0
	for qty in inv.items.values():
		total += int(qty)
	return total


func remaining_space() -> int:
	return max(0, max_items - current_total())


func can_add(qty: int) -> bool:
	return remaining_space() >= qty


func clamp_add_qty(requested: int) -> int:
	return min(requested, remaining_space())


func is_full() -> bool:
	return remaining_space() <= 0
