extends Node
class_name Inventory

var items: Dictionary = {}  # String -> int


func get_qty(item: String) -> int:
	if items.has(item):
		return items[item]
	return 0


func add(item: String, qty: int) -> void:
	if qty <= 0:
		return
	
	if items.has(item):
		items[item] += qty
	else:
		items[item] = qty


func remove(item: String, qty: int) -> bool:
	if qty <= 0:
		return true
	
	var current: int = get_qty(item)
	if current < qty:
		return false
	
	items[item] = current - qty
	return true


func set_qty(item: String, qty: int) -> void:
	items[item] = max(0, qty)
