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

var wheat_price: float = 1.0
var bread_price: float = 2.5

var event_bus: EventBus = null
var current_tick: int = 0


func get_wallet(agent) -> Wallet:
	return agent.get_node("Wallet") as Wallet


func get_inv(agent) -> Inventory:
	return agent.get_node("Inventory") as Inventory


func set_tick(t: int) -> void:
	current_tick = t
	# Enforce price floors
	wheat_price = max(wheat_price, WHEAT_PRICE_FLOOR)
	bread_price = max(bread_price, BREAD_PRICE_FLOOR)


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
			event_bus.log("Tick %d: Farmer tried to sell %d wheat, but market wheat storage FULL (%d/%d)" % [current_tick, farmer_wheat, wheat, wheat_capacity])
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
			event_bus.log("Tick %d: Farmer tried to sell wheat, but market cannot afford (money=$%.2f)" % [current_tick, money])
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
			event_bus.log("Tick %d: Farmer sold %d/%d wheat (market wheat=%d/%d, limited by storage)" % [current_tick, amount, original_farmer_wheat, wheat, wheat_capacity])
		else:
			event_bus.log("Tick %d: Market bought %d wheat from Farmer for $%.2f (market wheat=%d/%d)" % [current_tick, amount, actual_payout, wheat, wheat_capacity])


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
			event_bus.log("Tick %d: Market sold %d seeds to Farmer for $%.2f" % [current_tick, needed, cost])


func sell_wheat_to_baker(baker: Baker, requested: int) -> int:
	if requested <= 0:
		return 0
	
	# Check if market has no wheat
	if wheat == 0:
		if event_bus:
			event_bus.log("Tick %d: Baker tried to buy %d wheat, but market has 0." % [current_tick, requested])
		return 0
	
	var baker_wallet: Wallet = get_wallet(baker)
	var baker_inv: Inventory = get_inv(baker)
	
	# Determine how much baker can afford
	var max_affordable: int = int(floor(baker_wallet.money / wheat_price))
	
	# Check if baker cannot afford any
	if max_affordable == 0:
		if event_bus:
			event_bus.log("Tick %d: Baker tried to buy wheat, but cannot afford any at $%.2f (money=$%.2f)." % [current_tick, wheat_price, baker_wallet.money])
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
			event_bus.log("Tick %d: Baker requested %d wheat; bought %d (market wheat=%d, affordable=%d)." % [current_tick, requested, amount_sold, before_market_wheat, max_affordable])
		else:
			event_bus.log("Tick %d: Market sold %d wheat to Baker for $%.2f" % [current_tick, amount_sold, cost])
	
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
			event_bus.log("Tick %d: Baker tried to sell %d bread, but market bread storage FULL (%d/%d)" % [current_tick, baker_bread, bread, bread_capacity])
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
			event_bus.log("Tick %d: Baker tried to sell bread, but market cannot afford (money=$%.2f)" % [current_tick, money])
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
			event_bus.log("Tick %d: Baker sold %d/%d bread (market bread=%d/%d, limited by storage)" % [current_tick, amount, original_baker_bread, bread, bread_capacity])
		else:
			event_bus.log("Tick %d: Market bought %d bread from Baker for $%.2f (market bread=%d/%d)" % [current_tick, amount, actual_payout, bread, bread_capacity])


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
			event_bus.log("Tick %d: Agent tried to sell %d bread, but market bread storage FULL (%d/%d)" % [current_tick, amount_offered, bread, bread_capacity])
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
			event_bus.log("Tick %d: Agent tried to sell bread, but market cannot afford (money=$%.2f)" % [current_tick, money])
		return 0
	
	# Execute transaction
	var actual_payout: float = amount * bread_price
	agent_inv.remove("bread", amount)
	agent_wallet.credit(actual_payout)
	bread += amount
	money -= actual_payout
	
	# Log transaction
	if event_bus:
		event_bus.log("Tick %d: Market bought %d bread from agent for $%.2f (market bread=%d/%d)" % [current_tick, amount, actual_payout, bread, bread_capacity])
	
	return amount


func sell_bread_to_household(h, requested: int) -> int:
	if requested <= 0:
		return 0
	
	# Check if market has no bread
	if bread <= 0:
		if event_bus:
			event_bus.log("Tick %d: Household tried to buy %d bread, but market has 0" % [current_tick, requested])
		return 0
	
	var h_wallet: Wallet = get_wallet(h)
	
	# Determine how much can be sold
	var max_by_inventory: int = min(requested, bread)
	var max_affordable: int = int(floor(h_wallet.money / bread_price))
	var qty: int = min(max_by_inventory, max_affordable)
	
	if qty <= 0:
		if event_bus:
			event_bus.log("Tick %d: Household cannot afford bread ($%.2f), money=$%.2f" % [current_tick, bread_price, h_wallet.money])
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
	
	# Check if market has no bread
	if bread <= 0:
		if event_bus:
			event_bus.log("Tick %d: Agent tried to buy %d bread, but market has 0" % [current_tick, requested])
		return 0
	
	var agent_wallet: Wallet = get_wallet(agent)
	
	# Determine how much can be sold
	var max_by_inventory: int = min(requested, bread)
	var max_affordable: int = int(floor(agent_wallet.money / bread_price))
	var qty: int = min(max_by_inventory, max_affordable)
	
	if qty <= 0:
		if event_bus:
			event_bus.log("Tick %d: Agent cannot afford bread ($%.2f), money=$%.2f" % [current_tick, bread_price, agent_wallet.money])
		return 0
	
	# Perform transaction
	var cost: float = float(qty) * bread_price
	agent_wallet.debit(cost)
	money += cost
	bread -= qty
	
	if event_bus and qty < requested:
		event_bus.log("Tick %d: Agent bought %d/%d bread (limited by availability or money)" % [current_tick, qty, requested])
	
	return qty
