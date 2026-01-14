extends Node
class_name Market

var money: float = 100000.0
var seeds: int = 100000
var wheat: int = 0
var bread: int = 0

var wheat_capacity: int = 100
var bread_capacity: int = 200

const SEED_PRICE: float = 0.5
const WHEAT_PRICE_FLOOR: float = 0.50
const BREAD_PRICE_FLOOR: float = 1.00
const WHEAT_PRICE_CEILING: float = 5.00
const BREAD_PRICE_CEILING: float = 10.00
const PRICE_STEP: float = 0.10  # 10% adjustment per day

# Sell pressure threshold - prevents monopoly price pegging
# If sell_pressure_ratio < threshold, price won't increase even if inventory is low
const SELL_PRESSURE_THRESHOLD: float = 0.5  # 50% fulfillment required

# Bid pricing configuration
const BID_DISCOUNT_MIN: float = 0.8  # 20% max discount when at capacity
const BID_DISCOUNT_MAX: float = 1.0  # No discount when empty
const MAX_MICROFILL_UNITS_PER_TRADE: int = 25  # Performance cap

var wheat_price: float = 1.0
var bread_price: float = 2.5

var wheat_target: int = 50
var bread_target: int = 80

# Trade flow tracking (reset daily)
var wheat_sold_today: int = 0
var wheat_requested_today: int = 0
var bread_sold_today: int = 0
var bread_requested_today: int = 0

var event_bus: EventBus = null
var current_tick: int = 0


func _agent_label(agent) -> String:
	if agent == null:
		return "Unknown"
	if agent.has_method("get_display_name"):
		return str(agent.get_display_name())
	return str(agent.name)


func get_wallet(agent) -> Wallet:
	return agent.get_node("Wallet") as Wallet


func get_inv(agent) -> Inventory:
	return agent.get_node("Inventory") as Inventory


func set_tick(t: int) -> void:
	current_tick = t
	# Enforce price floors and ceilings
	wheat_price = clamp(wheat_price, WHEAT_PRICE_FLOOR, WHEAT_PRICE_CEILING)
	bread_price = clamp(bread_price, BREAD_PRICE_FLOOR, BREAD_PRICE_CEILING)


## Bid Price API - Used by producers for economic decisions

func get_bid_price(good: String) -> float:
	"""Get current bid price for a good (what market will pay right now).
	Bid price = reference_price * inventory_discount_factor.
	Bid drops as inventory approaches capacity."""
	var reference_price: float = 0.0
	var current_inv: int = 0
	var capacity: int = 0
	var floor_price: float = 0.0
	
	match good:
		"wheat":
			reference_price = wheat_price
			current_inv = wheat
			capacity = wheat_capacity
			floor_price = WHEAT_PRICE_FLOOR
		"bread":
			reference_price = bread_price
			current_inv = bread
			capacity = bread_capacity
			floor_price = BREAD_PRICE_FLOOR
		_:
			return 0.0
	
	# Calculate inventory pressure (0.0 = empty, 1.0 = at capacity)
	var inventory_pressure: float = 0.0 if capacity == 0 else float(current_inv) / float(capacity)
	
	# Calculate discount factor (1.0 at empty, BID_DISCOUNT_MIN at capacity)
	var discount_factor: float = BID_DISCOUNT_MAX - (inventory_pressure * (BID_DISCOUNT_MAX - BID_DISCOUNT_MIN))
	
	# Apply discount and enforce floor
	var bid: float = reference_price * discount_factor
	return max(bid, floor_price)


func get_max_buy_qty(good: String) -> int:
	"""Get maximum quantity market can buy per trade (remaining capacity)."""
	match good:
		"wheat":
			return max(0, wheat_capacity - wheat)
		"bread":
			return max(0, bread_capacity - bread)
		_:
			return 0


## Market Saturation API - Reusable for all producers

func is_saturated(good: String) -> bool:
	"""Check if market storage is full for a given good."""
	match good:
		"wheat":
			return wheat >= wheat_capacity
		"bread":
			return bread >= bread_capacity
		_:
			if event_bus:
				event_bus.log("ERROR: Unknown good '%s' in is_saturated()" % good)
			return false


func remaining_capacity(good: String) -> int:
	"""Get remaining storage space for a given good."""
	match good:
		"wheat":
			return max(0, wheat_capacity - wheat)
		"bread":
			return max(0, bread_capacity - bread)
		_:
			if event_bus:
				event_bus.log("ERROR: Unknown good '%s' in remaining_capacity()" % good)
			return 0


func get_saturation_info(good: String) -> Dictionary:
	"""Get detailed saturation info for logging/decisions."""
	match good:
		"wheat":
			return {
				"current": wheat,
				"capacity": wheat_capacity,
				"remaining": remaining_capacity("wheat"),
				"saturated": is_saturated("wheat")
			}
		"bread":
			return {
				"current": bread,
				"capacity": bread_capacity,
				"remaining": remaining_capacity("bread"),
				"saturated": is_saturated("bread")
			}
		_:
			return {}


func buy_wheat_from_farmer(farmer: Farmer, min_acceptable_price: float = 0.0) -> int:
	"""Micro-fill buying: purchase wheat 1 unit at a time, recomputing bid after each unit.
	Stops when bid drops below min_acceptable_price or inventory/money constraints hit."""
	var farmer_inv: Inventory = get_inv(farmer)
	var farmer_wallet: Wallet = get_wallet(farmer)
	var farmer_wheat: int = farmer_inv.get_qty("wheat")
	
	if farmer_wheat <= 0:
		return 0
	
	# Check available storage space
	var available_space: int = wheat_capacity - wheat
	if available_space <= 0:
		if event_bus:
			event_bus.log("Tick %d: %s tried to sell %d wheat, but market wheat storage FULL (%d/%d)" % [current_tick, _agent_label(farmer), farmer_wheat, wheat, wheat_capacity])
		return 0
	
	# Determine max units to process this trade (performance cap)
	var max_units: int = min(farmer_wheat, available_space, MAX_MICROFILL_UNITS_PER_TRADE)
	
	# Micro-fill loop: buy 1 unit at a time
	var units_bought: int = 0
	var total_paid: float = 0.0
	var initial_bid: float = get_bid_price("wheat")
	var stopped_by_price: bool = false
	
	for i in range(max_units):
		# Recompute bid based on current inventory
		var current_bid: float = get_bid_price("wheat")
		
		# Check if bid dropped below min acceptable
		if min_acceptable_price > 0.0 and current_bid < min_acceptable_price:
			stopped_by_price = true
			if event_bus and units_bought > 0:
				event_bus.log("Tick %d: Market micro-fill wheat: offered %d, bought %d (bid fell %.2f→%.2f, stopped at min_price %.2f)" % [current_tick, farmer_wheat, units_bought, initial_bid, current_bid, min_acceptable_price])
			break
		
		# Check if market can afford this unit
		if money < current_bid:
			break
		
		# Buy 1 unit
		farmer_inv.remove("wheat", 1)
		farmer_wallet.credit(current_bid)
		wheat += 1
		money -= current_bid
		total_paid += current_bid
		units_bought += 1
	
	# Track flow for pricing
	wheat_sold_today += units_bought
	
	# Log transaction
	if event_bus and units_bought > 0:
		if not stopped_by_price:
			if units_bought < farmer_wheat:
				event_bus.log("Tick %d: %s sold %d/%d wheat for $%.2f (market wheat=%d/%d)" % [current_tick, _agent_label(farmer), units_bought, farmer_wheat, total_paid, wheat, wheat_capacity])
			else:
				event_bus.log("Tick %d: Market bought %d wheat from %s for $%.2f (market wheat=%d/%d)" % [current_tick, units_bought, _agent_label(farmer), total_paid, wheat, wheat_capacity])
	
	return units_bought


func sell_seeds_to_farmer(farmer: Farmer) -> void:
	var farmer_inv: Inventory = get_inv(farmer)
	var farmer_wallet: Wallet = get_wallet(farmer)
	var current_seeds: int = farmer_inv.get_qty("seeds")
	
	if current_seeds >= 20:
		return
	
	var needed: int = 20 - current_seeds
	var cost: float = needed * SEED_PRICE
	
	if farmer_wallet.can_afford(cost) and seeds >= needed:
		# Transfer seeds and money
		money += cost
		seeds -= needed
		farmer_wallet.debit(cost)
		farmer_inv.add("seeds", needed)
		
		if event_bus:
			event_bus.log("Tick %d: Market sold %d seeds to %s for $%.2f" % [current_tick, needed, _agent_label(farmer), cost])


func sell_wheat_to_baker(baker: Baker, requested: int) -> int:
	if requested <= 0:
		return 0
	
	# Track demand
	wheat_requested_today += requested
	
	# Check if market has no wheat
	if wheat == 0:
		if event_bus:
			event_bus.log("Tick %d: %s tried to buy %d wheat, but market has 0." % [current_tick, _agent_label(baker), requested])
		return 0
	
	var baker_wallet: Wallet = get_wallet(baker)
	var baker_inv: Inventory = get_inv(baker)
	
	# Determine how much baker can afford
	var max_affordable: int = int(floor(baker_wallet.money / wheat_price))
	
	# Check if baker cannot afford any
	if max_affordable == 0:
		if event_bus:
			event_bus.log("Tick %d: %s tried to buy wheat, but cannot afford any at $%.2f (money=$%.2f)." % [current_tick, _agent_label(baker), wheat_price, baker_wallet.money])
		return 0
	
	# Determine how much wheat is available
	var before_market_wheat: int = wheat
	var amount_sold: int = min(requested, wheat)
	amount_sold = min(amount_sold, max_affordable)
	
	if amount_sold <= 0:
		return 0
	
	# Perform transaction
	var cost: float = amount_sold * wheat_price
	baker_wallet.debit(cost)
	money += cost
	baker_inv.add("wheat", amount_sold)
	wheat -= amount_sold
	
	# Log success or partial fulfillment
	if event_bus:
		if amount_sold < requested:
			event_bus.log("Tick %d: %s requested %d wheat; bought %d (market wheat=%d, affordable=%d)." % [current_tick, _agent_label(baker), requested, amount_sold, before_market_wheat, max_affordable])
		else:
			event_bus.log("Tick %d: Market sold %d wheat to %s for $%.2f" % [current_tick, amount_sold, _agent_label(baker), cost])
	
	return amount_sold


func buy_bread_from_baker(baker: Baker, min_acceptable_price: float = 0.0) -> int:
	"""Micro-fill buying: purchase bread 1 unit at a time, recomputing bid after each unit.
	Stops when bid drops below min_acceptable_price or inventory/money constraints hit."""
	var baker_inv: Inventory = get_inv(baker)
	var baker_wallet: Wallet = get_wallet(baker)
	var baker_bread: int = baker_inv.get_qty("bread")
	
	if baker_bread <= 0:
		return 0
	
	# Check available storage space
	var available_space: int = bread_capacity - bread
	if available_space <= 0:
		if event_bus:
			event_bus.log("Tick %d: %s tried to sell %d bread, but market bread storage FULL (%d/%d)" % [current_tick, _agent_label(baker), baker_bread, bread, bread_capacity])
		return 0
	
	# Determine max units to process this trade (performance cap)
	var max_units: int = min(baker_bread, available_space, MAX_MICROFILL_UNITS_PER_TRADE)
	
	# Micro-fill loop: buy 1 unit at a time
	var units_bought: int = 0
	var total_paid: float = 0.0
	var initial_bid: float = get_bid_price("bread")
	var stopped_by_price: bool = false
	
	for i in range(max_units):
		# Recompute bid based on current inventory
		var current_bid: float = get_bid_price("bread")
		
		# Check if bid dropped below min acceptable
		if min_acceptable_price > 0.0 and current_bid < min_acceptable_price:
			stopped_by_price = true
			if event_bus and units_bought > 0:
				event_bus.log("Tick %d: Market micro-fill bread: offered %d, bought %d (bid fell %.2f→%.2f, stopped at min_price %.2f)" % [current_tick, baker_bread, units_bought, initial_bid, current_bid, min_acceptable_price])
			break
		
		# Check if market can afford this unit
		if money < current_bid:
			break
		
		# Buy 1 unit
		baker_inv.remove("bread", 1)
		baker_wallet.credit(current_bid)
		bread += 1
		money -= current_bid
		total_paid += current_bid
		units_bought += 1
	
	# Track flow for pricing
	bread_sold_today += units_bought
	
	# Log transaction
	if event_bus and units_bought > 0:
		if not stopped_by_price:
			if units_bought < baker_bread:
				event_bus.log("Tick %d: %s sold %d/%d bread for $%.2f (market bread=%d/%d)" % [current_tick, _agent_label(baker), units_bought, baker_bread, total_paid, bread, bread_capacity])
			else:
				event_bus.log("Tick %d: Market bought %d bread from %s for $%.2f (market bread=%d/%d)" % [current_tick, units_bought, _agent_label(baker), total_paid, bread, bread_capacity])
	
	return units_bought


func buy_bread_from_agent(agent, amount_offered: int, min_acceptable_price: float = 0.0) -> int:
	"""Buy a specific amount of bread from any agent using micro-fill approach.
	Stops when bid drops below min_acceptable_price or inventory/money constraints hit."""
	if amount_offered <= 0:
		return 0
	
	var agent_inv: Inventory = get_inv(agent)
	var agent_wallet: Wallet = get_wallet(agent)
	var agent_bread: int = agent_inv.get_qty("bread")
	
	if agent_bread <= 0:
		return 0
	
	# Check available storage space
	var available_space: int = bread_capacity - bread
	if available_space <= 0:
		if event_bus:
			event_bus.log("Tick %d: %s tried to sell %d bread, but market bread storage FULL (%d/%d)" % [current_tick, _agent_label(agent), amount_offered, bread, bread_capacity])
		return 0
	
	# Determine max units to process this trade (performance cap)
	var max_units: int = min(amount_offered, agent_bread, available_space, MAX_MICROFILL_UNITS_PER_TRADE)
	
	# Micro-fill loop: buy 1 unit at a time
	var units_bought: int = 0
	var total_paid: float = 0.0
	var initial_bid: float = get_bid_price("bread")
	var stopped_by_price: bool = false
	
	for i in range(max_units):
		# Recompute bid based on current inventory
		var current_bid: float = get_bid_price("bread")
		
		# Check if bid dropped below min acceptable
		if min_acceptable_price > 0.0 and current_bid < min_acceptable_price:
			stopped_by_price = true
			if event_bus and i == 0:
				event_bus.log("Tick %d: %s refused sell: bid %.2f < min %.2f" % [current_tick, _agent_label(agent), current_bid, min_acceptable_price])
			elif event_bus and units_bought > 0:
				event_bus.log("Tick %d: Market micro-fill bread: offered %d, bought %d (bid fell %.2f→%.2f, stopped at min_price %.2f)" % [current_tick, amount_offered, units_bought, initial_bid, current_bid, min_acceptable_price])
			break
		
		# Check if market can afford this unit
		if money < current_bid:
			break
		
		# Buy 1 unit
		agent_inv.remove("bread", 1)
		agent_wallet.credit(current_bid)
		bread += 1
		money -= current_bid
		total_paid += current_bid
		units_bought += 1
	
	# Track flow for pricing
	bread_sold_today += units_bought
	
	# Log transaction
	if event_bus and units_bought > 0:
		if not stopped_by_price:
			event_bus.log("Tick %d: Market bought %d bread from %s for $%.2f (market bread=%d/%d)" % [current_tick, units_bought, _agent_label(agent), total_paid, bread, bread_capacity])
	
	return units_bought


func sell_bread_to_household(h, requested: int) -> int:
	if requested <= 0:
		return 0
	
	# Track demand
	bread_requested_today += requested
	
	# Check if market has no bread
	if bread <= 0:
		if event_bus:
			event_bus.log("Tick %d: %s tried to buy %d bread, but market has 0" % [current_tick, _agent_label(h), requested])
		return 0
	
	var h_wallet: Wallet = get_wallet(h)
	
	# Determine how much can be sold
	var max_by_inventory: int = min(requested, bread)
	var max_affordable: int = int(floor(h_wallet.money / bread_price))
	var qty: int = min(max_by_inventory, max_affordable)
	
	if qty <= 0:
		if event_bus:
			event_bus.log("Tick %d: %s cannot afford bread ($%.2f), money=$%.2f" % [current_tick, _agent_label(h), bread_price, h_wallet.money])
		return 0
	
	# Perform transaction
	var cost: float = float(qty) * bread_price
	h_wallet.debit(cost)
	money += cost
	bread -= qty
	
	return qty


func sell_bread_to_agent(agent, requested: int) -> int:
	if requested <= 0:
		return 0
	
	# Track demand
	bread_requested_today += requested
	
	# GUARD RAIL: Prevent producers from buying their own output UNLESS:
	# 1. They are in survival mode (food reserve critical), OR
	# 2. Production is profit-paused (can't produce their own food)
	if agent is Baker:
		var can_buy_own_output: bool = false
		
		# Check if in survival mode
		var food_reserve = agent.get_node_or_null("FoodReserve")
		if food_reserve and food_reserve.is_survival_mode:
			can_buy_own_output = true
		
		# Check if production is profit-paused
		var profit_checker = agent.get_node_or_null("ProductionProfitability")
		if profit_checker and not profit_checker.is_profitable:
			can_buy_own_output = true
		
		if not can_buy_own_output:
			if event_bus:
				event_bus.log("ERROR Tick %d: Baker attempted to buy bread (BLOCKED - producers must not buy their output unless survival mode or production paused)" % current_tick)
			return 0
	
	# Check if market has no bread
	if bread <= 0:
		if event_bus:
			event_bus.log("Tick %d: %s tried to buy %d bread, but market has 0" % [current_tick, _agent_label(agent), requested])
		return 0
	
	var agent_wallet: Wallet = get_wallet(agent)
	
	# Determine how much can be sold
	var max_by_inventory: int = min(requested, bread)
	var max_affordable: int = int(floor(agent_wallet.money / bread_price))
	var qty: int = min(max_by_inventory, max_affordable)
	
	if qty <= 0:
		if event_bus:
			event_bus.log("Tick %d: %s cannot afford bread ($%.2f), money=$%.2f" % [current_tick, _agent_label(agent), bread_price, agent_wallet.money])
		return 0
	
	# Perform transaction
	var cost: float = float(qty) * bread_price
	agent_wallet.debit(cost)
	money += cost
	bread -= qty
	
	if event_bus and qty < requested:
		event_bus.log("Tick %d: %s bought %d/%d bread (limited by availability or money)" % [current_tick, _agent_label(agent), qty, requested])
	
	return qty


# ==================== SELL PRESSURE CALCULATION ====================

func _get_sell_pressure_ratio(good: String) -> float:
	"""Calculate sell_pressure_ratio = units_sold / max(units_requested, 1)
	Low ratio means demand exists but supply is constrained (potential monopoly)."""
	var sold: int = 0
	var requested: int = 0
	
	match good:
		"wheat":
			sold = wheat_sold_today
			requested = wheat_requested_today
		"bread":
			sold = bread_sold_today
			requested = bread_requested_today
		_:
			return 1.0  # Unknown good, no pressure constraint
	
	if requested == 0:
		return 1.0  # No demand, no pressure constraint
	
	return float(sold) / float(requested)


# ==================== DAILY PRICE ADJUSTMENT ======================================

func on_day_changed(day: int) -> void:
	"""Called by Calendar when a new day starts. Adjusts prices based on inventory vs target."""
	_adjust_wheat_price(day)
	_adjust_bread_price(day)
	
	# Reset daily flow counters
	wheat_sold_today = 0
	wheat_requested_today = 0
	bread_sold_today = 0
	bread_requested_today = 0


func _adjust_wheat_price(day: int) -> void:
	var old_price: float = wheat_price
	var sell_pressure: float = _get_sell_pressure_ratio("wheat")
	var price_change_blocked: bool = false
	
	if wheat < wheat_target:
		# Low inventory suggests scarcity, but check sell pressure first
		if sell_pressure < SELL_PRESSURE_THRESHOLD:
			# Demand exists but not being fulfilled - BLOCK price increase
			price_change_blocked = true
			if event_bus:
				event_bus.log("Day %d: wheat price increase BLOCKED due to low sell flow (pressure: %.1f%%, inv: %d/%d, sold: %d, requested: %d)" % [day, sell_pressure * 100.0, wheat, wheat_target, wheat_sold_today, wheat_requested_today])
		else:
			# Genuine scarcity with good fulfillment - allow price increase
			wheat_price *= (1.0 + PRICE_STEP)
	elif wheat > wheat_target:
		# High inventory → lower price (surplus)
		wheat_price *= (1.0 - PRICE_STEP)
	else:
		return  # At target, no change
	
	if not price_change_blocked:
		wheat_price = clamp(wheat_price, WHEAT_PRICE_FLOOR, WHEAT_PRICE_CEILING)
		
		if abs(wheat_price - old_price) > 0.0001 and event_bus:
			event_bus.log("Day %d: wheat_price $%.2f → $%.2f (inv %d / target %d, pressure: %.1f%%)" % [day, old_price, wheat_price, wheat, wheat_target, sell_pressure * 100.0])


func _adjust_bread_price(day: int) -> void:
	var old_price: float = bread_price
	var sell_pressure: float = _get_sell_pressure_ratio("bread")
	var price_change_blocked: bool = false
	
	if bread < bread_target:
		# Low inventory suggests scarcity, but check sell pressure first
		if sell_pressure < SELL_PRESSURE_THRESHOLD:
			# Demand exists but not being fulfilled - BLOCK price increase
			price_change_blocked = true
			if event_bus:
				event_bus.log("Day %d: bread price increase BLOCKED due to low sell flow (pressure: %.1f%%, inv: %d/%d, sold: %d, requested: %d)" % [day, sell_pressure * 100.0, bread, bread_target, bread_sold_today, bread_requested_today])
		else:
			# Genuine scarcity with good fulfillment - allow price increase
			bread_price *= (1.0 + PRICE_STEP)
	elif bread > bread_target:
		# High inventory → lower price (surplus)
		bread_price *= (1.0 - PRICE_STEP)
	else:
		return  # At target, no change
	
	if not price_change_blocked:
		bread_price = clamp(bread_price, BREAD_PRICE_FLOOR, BREAD_PRICE_CEILING)
		
		if abs(bread_price - old_price) > 0.0001 and event_bus:
			event_bus.log("Day %d: bread_price $%.2f → $%.2f (inv %d / target %d, pressure: %.1f%%)" % [day, old_price, bread_price, bread, bread_target, sell_pressure * 100.0])
