extends Node
class_name ProductionProfitability

## Reusable mechanic for checking if production is profitable.
## Prevents producers from operating at a loss.

# Configuration
var minimum_profit_margin: float = 0.10  # 10% minimum profit margin

# State tracking (prevents log spam)
var is_profitable: bool = true
var last_profitability_check_tick: int = -1
var profitability_changed_this_tick: bool = false

# Dependencies
var market: Market = null
var event_bus: EventBus = null
var current_tick: int = 0
var producer_name: String = ""


func bind(_market: Market, _event_bus: EventBus, _producer_name: String) -> void:
	market = _market
	event_bus = _event_bus
	producer_name = _producer_name


func set_tick(tick: int) -> void:
	current_tick = tick
	profitability_changed_this_tick = false


## Check if production is profitable for a given recipe.
## Returns true if should produce, false if should pause.
## NOW USES BID PRICE for output (what market will actually pay).
##
## recipe format: {
##   "output_good": "bread",
##   "output_quantity": 2,
##   "inputs": {"flour": 1}
## }
func is_production_profitable(recipe: Dictionary) -> bool:
	if market == null:
		return true  # Can't check, assume profitable
	
	# Calculate minimum profitable output price
	var min_price: float = calculate_minimum_profitable_price(recipe)
	
	# Get current market BID price for output (what market will actually pay)
	var output_good: String = recipe["output_good"]
	var current_output_price: float = get_market_bid_price(output_good)
	
	# Check profitability
	var profitable: bool = current_output_price >= min_price
	
	# Log only on state change
	if profitable != is_profitable:
		is_profitable = profitable
		profitability_changed_this_tick = true
		
		if event_bus:
			if profitable:
				event_bus.log("Tick %d: %s production RESUMED: profitable (bid $%.2f >= cost $%.2f)" % [current_tick, producer_name, current_output_price, min_price])
			else:
				event_bus.log("Tick %d: %s production PAUSED: unprofitable (bid $%.2f < cost $%.2f)" % [current_tick, producer_name, current_output_price, min_price])
	
	last_profitability_check_tick = current_tick
	return profitable


## Calculate minimum profitable price for recipe output.
## Formula: (sum of input costs / output quantity) * (1 + profit margin)
func calculate_minimum_profitable_price(recipe: Dictionary) -> float:
	if not recipe.has("inputs") or not recipe.has("output_quantity"):
		return 0.0
	
	var total_input_cost: float = 0.0
	var inputs: Dictionary = recipe["inputs"]
	
	# Sum up cost of all inputs
	for input_good in inputs.keys():
		var input_qty: int = inputs[input_good]
		var input_price: float = get_market_price(input_good)
		total_input_cost += float(input_qty) * input_price
	
	var output_qty: int = recipe["output_quantity"]
	if output_qty <= 0:
		return 0.0
	
	# Minimum price = cost per unit * (1 + profit margin)
	var cost_per_unit: float = total_input_cost / float(output_qty)
	return cost_per_unit * (1.0 + minimum_profit_margin)


## Get current market price for a good
func get_market_price(good: String) -> float:
	if market == null:
		return 0.0
	
	match good:
		"wheat":
			return market.wheat_price
		"bread":
			return market.bread_price
		"seeds":
			return market.SEED_PRICE
		_:
			if event_bus:
				event_bus.log("ERROR: ProductionProfitability attempted to look up price for non-market good '%s'" % good)
			return 0.0


## Get current market BID price for a good (what market will actually pay)
func get_market_bid_price(good: String) -> float:
	if market == null:
		return 0.0
	
	# Use bid price if available, fallback to reference price
	if market.has_method("get_bid_price"):
		return market.get_bid_price(good)
	else:
		return get_market_price(good)


## Check if profitability status changed this tick
func did_profitability_change() -> bool:
	return profitability_changed_this_tick


## Get minimum acceptable selling price for recipe output (walk-away price).
## This is the price below which the producer should refuse to sell.
## Uses the same calculation as minimum profitable price.
func get_min_acceptable_price(recipe: Dictionary) -> float:
	return calculate_minimum_profitable_price(recipe)


## Get minimum acceptable selling price using market BID price for inputs.
## This accounts for the actual price the producer would pay if restocking.
func get_min_acceptable_price_with_bid(recipe: Dictionary) -> float:
	if market == null or not recipe.has("inputs") or not recipe.has("output_quantity"):
		return 0.0
	
	var total_input_cost: float = 0.0
	var inputs: Dictionary = recipe["inputs"]
	
	# Sum up cost of all inputs using BID price (what market actually pays)
	for input_good in inputs.keys():
		var input_qty: int = inputs[input_good]
		var input_bid_price: float = market.get_bid_price(input_good) if market.has_method("get_bid_price") else get_market_price(input_good)
		total_input_cost += float(input_qty) * input_bid_price
	
	var output_qty: int = recipe["output_quantity"]
	if output_qty <= 0:
		return 0.0
	
	# Minimum price = cost per unit * (1 + profit margin)
	var cost_per_unit: float = total_input_cost / float(output_qty)
	return cost_per_unit * (1.0 + minimum_profit_margin)
