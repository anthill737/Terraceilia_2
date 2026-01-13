extends Node
class_name ProductionBatch

## Reusable production batch processor
## Computes safe batch sizes under inventory/capacity limits
## Executes conversions without material loss

var inv: Inventory = null
var cap: InventoryCapacity = null


func bind(inventory: Inventory, capacity: InventoryCapacity) -> void:
	inv = inventory
	cap = capacity


func available_space() -> int:
	if cap == null:
		return 999999
	return cap.remaining_space()


func compute_batch(max_batch: int, input_item: String, output_item: String, output_per_input: int) -> int:
	"""
	Compute how many input units can be processed this cycle.
	Limited by:
	- Input available
	- Remaining inventory space for outputs
	- Max batch size
	"""
	if inv == null or cap == null:
		return 0
	
	var input_avail: int = inv.get_qty(input_item)
	if input_avail <= 0:
		return 0
	
	var space: int = cap.remaining_space()
	if space <= 0:
		return 0
	
	var max_by_space: int = int(floor(float(space) / float(output_per_input)))
	return max(0, min(max_batch, input_avail, max_by_space))


func convert(input_item: String, output_item: String, units: int, output_per_input: int) -> bool:
	"""
	Remove exactly 'units' of input and add exactly units*output_per_input output.
	Returns false if any step fails; does not destroy materials.
	"""
	if inv == null or cap == null:
		return false
	
	if units <= 0:
		return false
	
	var out_qty: int = units * output_per_input
	
	# Capacity safety check
	if cap.remaining_space() < out_qty:
		return false
	
	# Remove input
	if not inv.remove(input_item, units):
		return false
	
	# Add output with verification
	var before: int = inv.get_qty(output_item)
	inv.add(output_item, out_qty)
	var added: int = inv.get_qty(output_item) - before
	
	if added != out_qty:
		# Rollback: restore input
		inv.add(input_item, units)
		# Try to restore output (best effort)
		inv.set_qty(output_item, before)
		return false
	
	return true
