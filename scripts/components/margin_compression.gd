extends Node
class_name MarginCompression

## Generic margin compression detector for production throttling.
## Compares input costs vs output prices to detect margin squeeze BEFORE profit goes negative.
## This is a leading indicator that prevents catastrophic oversupply.
##
## Uses recipe-driven logic - works for any producer with any recipe structure.

# Configuration
var compression_threshold: float = 0.90  # Throttle when input_cost >= output_price * threshold
var enabled: bool = true

# State tracking (for state-change-only logging)
var is_compressed: bool = false
var last_check_tick: int = -1

# Dependencies
var market: Market = null
var event_bus: EventBus = null
var agent_name: String = ""
var current_tick: int = 0


func bind(_market: Market, _event_bus: EventBus, _agent_name: String) -> void:
	market = _market
	event_bus = _event_bus
	agent_name = _agent_name


func set_tick(tick: int) -> void:
	current_tick = tick


## Check if margin compression is occurring for a given recipe.
## Recipe format: { "output_good": String, "output_quantity": int, "inputs": { good_id: quantity } }
## Returns true if production should be throttled due to margin compression.
func check_margin_compression(recipe: Dictionary) -> bool:
	if not enabled or market == null:
		return false
	
	# Validate recipe structure
	if not recipe.has("output_good") or not recipe.has("output_quantity") or not recipe.has("inputs"):
		if event_bus:
			event_bus.log("ERROR: MarginCompression - invalid recipe structure for %s" % agent_name)
		return false
	
	var output_good: String = recipe["output_good"]
	var output_quantity: int = recipe["output_quantity"]
	var inputs: Dictionary = recipe["inputs"]
	
	# Get market prices - use BID prices for realistic calculation
	var output_price: float = 0.0
	if market.has_method("get_bid_price"):
		output_price = market.get_bid_price(output_good)
	elif output_good == "bread":
		output_price = market.bread_price
	elif output_good == "wheat":
		output_price = market.wheat_price
	
	if output_price <= 0.0:
		# Output not tradeable or has no price - no compression check
		return false
	
	# Calculate weighted average input cost per unit of output
	var total_input_cost: float = 0.0
	var has_valid_input_prices: bool = false
	
	for input_good in inputs.keys():
		var input_qty: int = inputs[input_good]
		var input_price: float = 0.0
		# Use reference prices for inputs (what we'd pay to restock)
		if input_good == "bread":
			input_price = market.bread_price
		elif input_good == "wheat":
			input_price = market.wheat_price
		
		if input_price > 0.0:
			has_valid_input_prices = true
			total_input_cost += input_price * input_qty
	
	if not has_valid_input_prices:
		# No valid input prices - cannot calculate compression
		return false
	
	# Calculate cost per unit of output
	var cost_per_output: float = total_input_cost / float(output_quantity)
	
	# Check compression: if input cost >= output price * threshold
	var compression_price_point: float = output_price * compression_threshold
	var compressed: bool = cost_per_output >= compression_price_point
	
	# Log only on state change
	if compressed != is_compressed:
		is_compressed = compressed
		if event_bus:
			if is_compressed:
				var margin_percent: float = ((output_price - cost_per_output) / output_price) * 100.0
				event_bus.log("Tick %d: %s margin compression ON (margin: %.1f%%, input_cost: $%.2f, output: $%.2f)" % [
					current_tick, agent_name, margin_percent, cost_per_output, output_price
				])
			else:
				event_bus.log("Tick %d: %s margin compression OFF (margins recovered)" % [current_tick, agent_name])
	
	last_check_tick = current_tick
	return is_compressed


## Get current margin percentage for diagnostics/UI.
## Returns negative values if losing money, positive if profitable.
func get_margin_percentage(recipe: Dictionary) -> float:
	if market == null:
		return 0.0
	
	if not recipe.has("output_good") or not recipe.has("output_quantity") or not recipe.has("inputs"):
		return 0.0
	
	var output_good: String = recipe["output_good"]
	var output_quantity: int = recipe["output_quantity"]
	var inputs: Dictionary = recipe["inputs"]
	
	var output_price: float = 0.0
	if output_good == "bread":
		output_price = market.bread_price
	elif output_good == "wheat":
		output_price = market.wheat_price
	
	if output_price <= 0.0:
		return 0.0
	
	var total_input_cost: float = 0.0
	for input_good in inputs.keys():
		var input_qty: int = inputs[input_good]
		var input_price: float = 0.0
		if input_good == "bread":
			input_price = market.bread_price
		elif input_good == "wheat":
			input_price = market.wheat_price
		
		if input_price > 0.0:
			total_input_cost += input_price * input_qty
	
	var cost_per_output: float = total_input_cost / float(output_quantity)
	var margin: float = output_price - cost_per_output
	return (margin / output_price) * 100.0


## Check if actor should throttle selling to market (not production, just selling).
## This allows inventory to build up, which signals to price system to adjust.
func should_throttle_selling(recipe: Dictionary) -> bool:
	return check_margin_compression(recipe)


## Check if actor should throttle production entirely.
## More aggressive than just throttling sales.
func should_throttle_production(recipe: Dictionary) -> bool:
	# For now, same as selling throttle
	# Could be made more conservative (e.g., compression_threshold * 0.95)
	return check_margin_compression(recipe)
