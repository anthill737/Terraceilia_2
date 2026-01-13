extends Node
class_name EconomyAudit


func audit(farmer: Farmer, baker: Baker, market: Market, bus: EventBus, tick: int) -> void:
	var errors: Array[String] = []
	
	# Check farmer
	var farmer_wallet = farmer.get_node("Wallet")
	var farmer_inv = farmer.get_node("Inventory")
	var farmer_hunger = farmer.get_node("HungerNeed")
	if farmer_wallet.money < -0.001:
		errors.append("Farmer money negative: %.2f" % farmer_wallet.money)
	if farmer_inv.get_qty("seeds") < 0:
		errors.append("Farmer seeds negative: %d" % farmer_inv.get_qty("seeds"))
	if farmer_inv.get_qty("wheat") < 0:
		errors.append("Farmer wheat negative: %d" % farmer_inv.get_qty("wheat"))
	if farmer_inv.get_qty("bread") < 0:
		errors.append("Farmer bread negative: %d" % farmer_inv.get_qty("bread"))
	if farmer_hunger.hunger_days < 0:
		errors.append("Farmer hunger_days negative: %d" % farmer_hunger.hunger_days)
	if farmer_hunger.hunger_days > farmer_hunger.hunger_max_days + 5:
		errors.append("Farmer hunger_days unreasonable: %d" % farmer_hunger.hunger_days)
	if is_nan(farmer_wallet.money):
		errors.append("Farmer money is NaN")
	
	# Check baker
	var baker_wallet = baker.get_node("Wallet")
	var baker_inv = baker.get_node("Inventory")
	var baker_hunger = baker.get_node("HungerNeed")
	if baker_wallet.money < -0.001:
		errors.append("Baker money negative: %.2f" % baker_wallet.money)
	if baker_inv.get_qty("wheat") < 0:
		errors.append("Baker wheat negative: %d" % baker_inv.get_qty("wheat"))
	if baker_inv.get_qty("flour") < 0:
		errors.append("Baker flour negative: %d" % baker_inv.get_qty("flour"))
	if baker_inv.get_qty("bread") < 0:
		errors.append("Baker bread negative: %d" % baker_inv.get_qty("bread"))
	if baker_hunger.hunger_days < 0:
		errors.append("Baker hunger_days negative: %d" % baker_hunger.hunger_days)
	if baker_hunger.hunger_days > baker_hunger.hunger_max_days + 5:
		errors.append("Baker hunger_days unreasonable: %d" % baker_hunger.hunger_days)
	if is_nan(baker_wallet.money):
		errors.append("Baker money is NaN")
	
	# Check market
	if market.money < -0.001:
		errors.append("Market money negative: %.2f" % market.money)
	if market.seeds < 0:
		errors.append("Market seeds negative: %d" % market.seeds)
	if market.wheat < 0:
		errors.append("Market wheat negative: %d" % market.wheat)
	if market.bread < 0:
		errors.append("Market bread negative: %d" % market.bread)
	if market.wheat > market.wheat_capacity:
		errors.append("Market wheat exceeds capacity: %d/%d" % [market.wheat, market.wheat_capacity])
	if market.bread > market.bread_capacity:
		errors.append("Market bread exceeds capacity: %d/%d" % [market.bread, market.bread_capacity])
	if market.wheat_price < market.WHEAT_PRICE_FLOOR - 0.001:
		errors.append("Market wheat_price below floor: %.2f < %.2f" % [market.wheat_price, market.WHEAT_PRICE_FLOOR])
	if market.wheat_price > market.WHEAT_PRICE_CEILING + 0.001:
		errors.append("Market wheat_price above ceiling: %.2f > %.2f" % [market.wheat_price, market.WHEAT_PRICE_CEILING])
	if market.bread_price < market.BREAD_PRICE_FLOOR - 0.001:
		errors.append("Market bread_price below floor: %.2f < %.2f" % [market.bread_price, market.BREAD_PRICE_FLOOR])
	if market.bread_price > market.BREAD_PRICE_CEILING + 0.001:
		errors.append("Market bread_price above ceiling: %.2f > %.2f" % [market.bread_price, market.BREAD_PRICE_CEILING])
	if is_nan(market.money):
		errors.append("Market money is NaN")
	
	# Report errors
	if errors.size() > 0:
		for error in errors:
			bus.log("Tick %d: AUDIT FAIL: %s" % [tick, error])
		assert(false, "Economy audit failed at tick %d" % tick)
