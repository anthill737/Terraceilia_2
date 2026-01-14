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

var wheat_price: float = 1.0
var bread_price: float = 2.5

var wheat_target: int = 50
var bread_target: int = 80

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


func buy_wheat_from_farmer(farmer: Farmer) -> void:
	var farmer_inv: Inventory = get_inv(farmer)
	var farmer_wallet: Wallet = get_wallet(farmer)
	var farmer_wheat: int = farmer_inv.get_qty("wheat")
	
	if farmer_wheat <= 0:
		return
	
	# Check available storage space
	var available_space: int = wheat_capacity - wheat
	if available_space <= 0:
		if event_bus:
			event_bus.log("Tick %d: %s tried to sell %d wheat, but market wheat storage FULL (%d/%d)" % [current_tick, _agent_label(farmer), farmer_wheat, wheat, wheat_capacity])
		return
	
	# Determine how much we can buy (limited by space)
	var original_farmer_wheat: int = farmer_wheat
	var amount: int = min(farmer_wheat, available_space)
	var payout: float = amount * wheat_price
	
	# Check if market can afford it
	if money < payout:
		var affordable: int = int(floor(money / wheat_price))
		amount = min(amount, affordable)
	
	if amount <= 0:
		if event_bus:
			event_bus.log("Tick %d: %s tried to sell wheat, but market cannot afford (money=$%.2f)" % [current_tick, _agent_label(farmer), money])
		return
	
	# Execute transaction
	var actual_payout: float = amount * wheat_price
	farmer_inv.remove("wheat", amount)
	farmer_wallet.credit(actual_payout)
	wheat += amount
	money -= actual_payout
	
	# Log transaction
	if event_bus:
		if amount < original_farmer_wheat:
			event_bus.log("Tick %d: %s sold %d/%d wheat (market wheat=%d/%d, limited by storage)" % [current_tick, _agent_label(farmer), amount, original_farmer_wheat, wheat, wheat_capacity])
		else:
			event_bus.log("Tick %d: Market bought %d wheat from %s for $%.2f (market wheat=%d/%d)" % [current_tick, amount, _agent_label(farmer), actual_payout, wheat, wheat_capacity])


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


func buy_bread_from_baker(baker: Baker) -> void:
	var baker_inv: Inventory = get_inv(baker)
	var baker_wallet: Wallet = get_wallet(baker)
	var baker_bread: int = baker_inv.get_qty("bread")
	
	if baker_bread <= 0:
		return
	
	# Check available storage space
	var available_space: int = bread_capacity - bread
	if available_space <= 0:
		if event_bus:
			event_bus.log("Tick %d: %s tried to sell %d bread, but market bread storage FULL (%d/%d)" % [current_tick, _agent_label(baker), baker_bread, bread, bread_capacity])
		return
	
	# Determine how much we can buy (limited by space)
	var original_baker_bread: int = baker_bread
	var amount: int = min(baker_bread, available_space)
	var payout: float = amount * bread_price
	
	# Check if market can afford it
	if money < payout:
		var affordable: int = int(floor(money / bread_price))
		amount = min(amount, affordable)
	
	if amount <= 0:
		if event_bus:
			event_bus.log("Tick %d: %s tried to sell bread, but market cannot afford (money=$%.2f)" % [current_tick, _agent_label(baker), money])
		return
	
	# Execute transaction
	var actual_payout: float = amount * bread_price
	baker_inv.remove("bread", amount)
	baker_wallet.credit(actual_payout)
	bread += amount
	money -= actual_payout
	
	# Log transaction
	if event_bus:
		if amount < original_baker_bread:
			event_bus.log("Tick %d: %s sold %d/%d bread (market bread=%d/%d, limited by storage)" % [current_tick, _agent_label(baker), amount, original_baker_bread, bread, bread_capacity])
		else:
			event_bus.log("Tick %d: Market bought %d bread from %s for $%.2f (market bread=%d/%d)" % [current_tick, amount, _agent_label(baker), actual_payout, bread, bread_capacity])


func buy_bread_from_agent(agent, amount_offered: int) -> int:
	"""Buy a specific amount of bread from any agent (e.g., baker selling while preserving buffer)"""
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
	
	# Determine how much we can buy (limited by what they offer, what they have, and space)
	var amount: int = min(amount_offered, agent_bread)
	amount = min(amount, available_space)
	var payout: float = amount * bread_price
	
	# Check if market can afford it
	if money < payout:
		var affordable: int = int(floor(money / bread_price))
		amount = min(amount, affordable)
	
	if amount <= 0:
		if event_bus:
			event_bus.log("Tick %d: %s tried to sell bread, but market cannot afford (money=$%.2f)" % [current_tick, _agent_label(agent), money])
		return 0
	
	# Execute transaction
	var actual_payout: float = amount * bread_price
	agent_inv.remove("bread", amount)
	agent_wallet.credit(actual_payout)
	bread += amount
	money -= actual_payout
	
	# Log transaction
	if event_bus:
		event_bus.log("Tick %d: Market bought %d bread from %s for $%.2f (market bread=%d/%d)" % [current_tick, amount, _agent_label(agent), actual_payout, bread, bread_capacity])
	
	return amount


func sell_bread_to_household(h, requested: int) -> int:
	if requested <= 0:
		return 0
	
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


# ==================== DAILY PRICE ADJUSTMENT ====================

func on_day_changed(day: int) -> void:
	"""Called by Calendar when a new day starts. Adjusts prices based on inventory vs target."""
	_adjust_wheat_price(day)
	_adjust_bread_price(day)


func _adjust_wheat_price(day: int) -> void:
	var old_price: float = wheat_price
	
	if wheat < wheat_target:
		# Low inventory → raise price (scarcity)
		wheat_price *= (1.0 + PRICE_STEP)
	elif wheat > wheat_target:
		# High inventory → lower price (surplus)
		wheat_price *= (1.0 - PRICE_STEP)
	else:
		return  # At target, no change
	
	wheat_price = clamp(wheat_price, WHEAT_PRICE_FLOOR, WHEAT_PRICE_CEILING)
	
	if abs(wheat_price - old_price) > 0.0001 and event_bus:
		event_bus.log("Day %d: wheat_price $%.2f → $%.2f (inv %d / target %d)" % [day, old_price, wheat_price, wheat, wheat_target])


func _adjust_bread_price(day: int) -> void:
	var old_price: float = bread_price
	
	if bread < bread_target:
		# Low inventory → raise price (scarcity)
		bread_price *= (1.0 + PRICE_STEP)
	elif bread > bread_target:
		# High inventory → lower price (surplus)
		bread_price *= (1.0 - PRICE_STEP)
	else:
		return  # At target, no change
	
	bread_price = clamp(bread_price, BREAD_PRICE_FLOOR, BREAD_PRICE_CEILING)
	
	if abs(bread_price - old_price) > 0.0001 and event_bus:
		event_bus.log("Day %d: bread_price $%.2f → $%.2f (inv %d / target %d)" % [day, old_price, bread_price, bread, bread_target])
