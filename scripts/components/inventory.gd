extends Node
class_name Inventory

var items: Dictionary = {}  # String -> int
var capacity: InventoryCapacity = null  # Optional capacity limiter


func bind_capacity(cap: InventoryCapacity) -> void:
	capacity = cap


func get_qty(item: String) -> int:
	if items.has(item):
		return items[item]
	return 0


func add(item: String, qty: int) -> int:
	"""Add items to inventory. Returns actual amount added (may be less if capacity limited)."""
	if qty <= 0:
		return 0
	
	var actual_qty: int = qty
	
	# Clamp to available capacity if capacity is bound
	if capacity != null:
		actual_qty = capacity.clamp_add_qty(qty)
		if actual_qty <= 0:
			return 0
	
	if items.has(item):
		items[item] += actual_qty
	else:
		items[item] = actual_qty
	
	return actual_qty


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
