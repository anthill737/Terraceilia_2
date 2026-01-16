extends Node
class_name Market

var money: float = 100000.0
var seeds: int = 100000
var wheat: int = 0
var bread: int = 0

var wheat_capacity: int = 100
var bread_capacity: int = 200

const SEED_PRICE: float = 0.5
const WHEAT_PRICE_CEILING: float = 5.00
const BREAD_PRICE_CEILING: float = 10.00
const PRICE_STEP: float = 0.10  # 10% adjustment per day

# Price floors - stable lower bounds for staple goods
const WHEAT_PRICE_FLOOR: float = 1.00
const BREAD_PRICE_FLOOR: float = 1.00

# Decay configuration - generic per-good spoilage/loss mechanic
# REFACTOR: Softened to small tuning layer, not a regime driver
const DECAY_CONFIG: Dictionary = {
	"wheat": {
		"enabled": false,  # DISABLED: Wheat decay removed to allow equilibrium
		"min_rate_per_day": 0.0,
		"max_rate_per_day": 0.0,
		"applies_to_market": false
	},
	"bread": {
		"enabled": true,
		"min_rate_per_day": 0.005,  # SOFTENED: 0.5% min (was 2%)
		"max_rate_per_day": 0.015,  # SOFTENED: 1.5% max (was 6%)
		"applies_to_market": true
	},
	"seeds": {
		"enabled": false,
		"min_rate_per_day": 0.0,
		"max_rate_per_day": 0.0,
		"applies_to_market": false
	}
}

# REFACTOR: Removed weekly-held cadence - decay now applies smoothly each day
# const DECAY_WINDOW_DAYS: int = 7  # REMOVED

# Target band configuration - hysteresis for market willingness and producer throttling
# Affects ONLY bid multipliers, max_buy_qty, and producer throttling
# Does NOT affect reference price authority (prices still need trades to rise)
const TARGET_BAND_PCT: float = 0.15  # 15% band around target
const BAND_UPPER_BID_MULTIPLIER: float = 0.70  # Aggressive discount above upper band
const BAND_LOWER_BID_MULTIPLIER: float = 1.10  # PART 2: Reduced from 1.30 to 1.10 to prevent scarcity spiral
const BAND_UPPER_MAX_BUY_TAPER: float = 0.10  # Max buy qty tapers to 10% above upper band

# Sell pressure threshold - prevents monopoly price pegging
# If sell_pressure_ratio < threshold, price won't increase even if inventory is low
const SELL_PRESSURE_THRESHOLD: float = 0.5  # 50% fulfillment required

# Bid curve configuration - steep near target for strong downward pressure
const BID_CURVE_SCARCITY_MULTIPLIER: float = 1.3  # Max 30% premium when empty
const BID_CURVE_SURPLUS_MULTIPLIER: float = 0.5  # STEEPENED: 50% discount when oversupplied (was 0.7)
const BID_CURVE_OVERFLOW_MULTIPLIER: float = 0.3  # STEEP: 70% discount when far above capacity
const BID_CURVE_PRE_TARGET_RATIO: float = 0.80  # Where steep decline starts (80% of target)
const BID_CURVE_STEEPNESS: float = 4.0  # INCREASED: Steeper curve (was 3.0)
const MAX_MICROFILL_UNITS_PER_TRADE: int = 25  # Performance cap

# ESCALATING DISTRESS PRICING - Applied ONLY to overflow units (not normal stored units)
# Severity increases with oversupply ratio to create rapid supply contraction
# Normal units respect walk-away pricing; overflow units clear at escalating discounts
const DISTRESS_BASE_MULTIPLIER: float = 0.8  # Starting multiplier at oversupply_ratio ~1.0
const DISTRESS_STEEPNESS: float = 3.0  # How fast distress escalates with oversupply
const DISTRESS_FLOOR: float = 0.2  # Minimum multiplier (80% discount) at severe gluts

# Price discovery configuration - reference prices follow clearing prices
const CLEARING_ANCHOR_STRENGTH: float = 0.5  # How much reference lerps toward clearing price (0.0-1.0)
const MAX_PREMIUM_OVER_CLEARING: float = 0.05  # Max 5% premium over avg clearing price
const MAX_INVENTORY_NUDGE_PER_DAY: float = 0.03  # Max 3% inventory-based adjustment per day
const MIN_TRADES_FOR_PRICE_DISCOVERY: int = 5  # Minimum trades to use price discovery
const MAX_DAILY_PRICE_CHANGE: float = 0.05  # Max 5% daily price movement cap
const DECAY_DISABLE_DAYS: int = 10  # Disable decay for first N days

# Producer hysteresis configuration - DISABLED to allow equilibrium-capable behavior
# Producers now use continuous throttling via inventory pressure instead of hard gates
const PRODUCER_HYSTERESIS_CONFIG: Dictionary = {
	"wheat": {
		"enabled": false,  # DISABLED: Hard gates removed
		"stop_sell_at_or_above_upper_band": false,
		"resume_sell_at_or_below_lower_band": false,
		"stop_produce_at_or_above_upper_band": false,
		"resume_produce_at_or_below_lower_band": false
	},
	"bread": {
		"enabled": false,  # DISABLED: Hard gates removed
		"stop_sell_at_or_above_upper_band": false,
		"resume_sell_at_or_below_lower_band": false,
		"stop_produce_at_or_above_upper_band": false,
		"resume_produce_at_or_below_lower_band": false
	}
}

var wheat_price: float = 1.0
var bread_price: float = 2.5

# PART 3: Targets aligned with actual throughput
var wheat_target: int = 45  # Reduced from 60 to match production capacity
var bread_target: int = 50  # Reduced from 80 to match consumption

# Previous day inventory tracking for recovery detection
var wheat_prev: int = 0
var bread_prev: int = 0
var current_day: int = 0

# REFACTOR: Removed weekly-held decay rate tracking variables
# Decay now applies smoothly each day without windowing

# Trade flow tracking (reset daily)
var wheat_sold_today: int = 0
var wheat_requested_today: int = 0
var bread_sold_today: int = 0
var bread_requested_today: int = 0

# Overflow tracking (reset daily) - units that clear but don't store
var wheat_overflow_today: int = 0
var bread_overflow_today: int = 0

# REFACTOR: Removed market-side hysteresis tracking (hard buy blocking disabled)
# Market now uses smooth tapering via bid multipliers and max_buy_qty

# Clearing price tracking (reset daily) - prevents reference price ratcheting
var wheat_total_cleared: int = 0
var wheat_total_value: float = 0.0
var bread_total_cleared: int = 0
var bread_total_value: float = 0.0

# Producer hysteresis state tracking - prevents repeated state change spam
var producer_hysteresis_state: Dictionary = {
	"wheat": {
		"can_sell": true,
		"can_produce": true
	},
	"bread": {
		"can_sell": true,
		"can_produce": true
	}
}

var event_bus: EventBus = null
var current_tick: int = 0
var market_shocks = null  # Reference to shock system (MarketShocks instance)

# Overflow tracking (reset daily, not cumulative)
var daily_wheat_overflow: int = 0
var daily_bread_overflow: int = 0


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
	
	# PART 1: Log market parameters once at startup
	if t == 0 and event_bus:
		# Log wheat parameters
		var wheat_lower: int = int(float(wheat_target) * (1.0 - TARGET_BAND_PCT))
		var wheat_upper: int = int(float(wheat_target) * (1.0 + TARGET_BAND_PCT))
		event_bus.log("[MARKET PARAMS] wheat: target=%d, lower_band=%d, upper_band=%d, band_pct=%.2f, decay_min=%.2f, decay_max=%.2f, lower_bid_mult=%.2f" % [
			wheat_target, wheat_lower, wheat_upper, TARGET_BAND_PCT,
			DECAY_CONFIG["wheat"]["min_rate_per_day"],
			DECAY_CONFIG["wheat"]["max_rate_per_day"],
			BAND_LOWER_BID_MULTIPLIER
		])
		# Log bread parameters
		var bread_lower: int = int(float(bread_target) * (1.0 - TARGET_BAND_PCT))
		var bread_upper: int = int(float(bread_target) * (1.0 + TARGET_BAND_PCT))
		event_bus.log("[MARKET PARAMS] bread: target=%d, lower_band=%d, upper_band=%d, band_pct=%.2f, decay_min=%.2f, decay_max=%.2f, lower_bid_mult=%.2f" % [
			bread_target, bread_lower, bread_upper, TARGET_BAND_PCT,
			DECAY_CONFIG["bread"]["min_rate_per_day"],
			DECAY_CONFIG["bread"]["max_rate_per_day"],
			BAND_LOWER_BID_MULTIPLIER
		])
	
	# Enforce price floors and ceilings
	wheat_price = clamp(wheat_price, WHEAT_PRICE_FLOOR, WHEAT_PRICE_CEILING)
	bread_price = clamp(bread_price, BREAD_PRICE_FLOOR, BREAD_PRICE_CEILING)
	
	# Update producer hysteresis state based on inventory bands
	_update_producer_hysteresis("wheat", wheat, wheat_target)
	_update_producer_hysteresis("bread", bread, bread_target)


## Producer Hysteresis API - Prevents price drift to floors

func _update_producer_hysteresis(good: String, current_inv: int, target_inv: int) -> void:
	"""Update producer hysteresis state for a good based on current inventory vs bands.
	Logs only on state transitions to avoid spam."""
	if not PRODUCER_HYSTERESIS_CONFIG.has(good):
		return
	
	var config = PRODUCER_HYSTERESIS_CONFIG[good]
	if not config["enabled"]:
		return
	
	var lower_band: int = int(float(target_inv) * (1.0 - TARGET_BAND_PCT))
	var upper_band: int = int(float(target_inv) * (1.0 + TARGET_BAND_PCT))
	var state = producer_hysteresis_state[good]
	
	# Update selling state
	if config["stop_sell_at_or_above_upper_band"]:
		var was_can_sell: bool = state["can_sell"]
		if current_inv >= upper_band:
			state["can_sell"] = false
		elif current_inv <= lower_band:
			state["can_sell"] = true
		# Log only on state change
		if was_can_sell != state["can_sell"] and event_bus:
			if state["can_sell"]:
				event_bus.log("[HYSTERESIS] %s SELLING RESUMED (inventory %d <= lower_band %d)" % [good, current_inv, lower_band])
			else:
				event_bus.log("[HYSTERESIS] %s SELLING PAUSED (inventory %d >= upper_band %d)" % [good, current_inv, upper_band])
	
	# Update production state
	if config["stop_produce_at_or_above_upper_band"]:
		var was_can_produce: bool = state["can_produce"]
		if current_inv >= upper_band:
			state["can_produce"] = false
		elif current_inv <= lower_band:
			state["can_produce"] = true
		# Log only on state change
		if was_can_produce != state["can_produce"] and event_bus:
			if state["can_produce"]:
				event_bus.log("[HYSTERESIS] %s PRODUCTION RESUMED (inventory %d <= lower_band %d)" % [good, current_inv, lower_band])
			else:
				event_bus.log("[HYSTERESIS] %s PRODUCTION PAUSED (inventory %d >= upper_band %d)" % [good, current_inv, upper_band])


func can_producer_sell(good: String) -> bool:
	"""Check if producers are allowed to sell this good to market (hysteresis gate)."""
	if not PRODUCER_HYSTERESIS_CONFIG.has(good):
		return true
	if not PRODUCER_HYSTERESIS_CONFIG[good]["enabled"]:
		return true
	return producer_hysteresis_state[good]["can_sell"]


func can_producer_produce(good: String) -> bool:
	"""Check if producers are allowed to produce this good for market (hysteresis gate)."""
	if not PRODUCER_HYSTERESIS_CONFIG.has(good):
		return true
	if not PRODUCER_HYSTERESIS_CONFIG[good]["enabled"]:
		return true
	return producer_hysteresis_state[good]["can_produce"]


func is_market_buy_blocked(good: String) -> bool:
	"""REFACTOR: Market buying is never hard-blocked. 
	Returns false always - smooth tapering via bid/cap replaces hard closure."""
	return false


func get_production_throttle_for_hysteresis(good: String) -> float:
	"""Get procurement throttle factor based on hysteresis state.
	Returns 0.0 when production paused, 1.0 when production allowed."""
	if not can_producer_produce(good):
		return 0.0
	return 1.0


func get_distress_multiplier(good: String, current_inv: int, target_inv: int) -> float:
	"""Compute escalating distress multiplier for overflow units based on oversupply severity.
	
	Distress escalates as inventory exceeds target:
	- oversupply_ratio = 1.0 → base multiplier (0.8)
	- oversupply_ratio = 1.5 → moderate distress (~0.4-0.5)
	- oversupply_ratio = 2.0+ → severe distress (floor 0.2)
	
	Returns multiplier in range [DISTRESS_FLOOR, DISTRESS_BASE_MULTIPLIER].
	Applied ONLY to overflow units; normal stored units use full bid price.
	"""
	if target_inv <= 0:
		return DISTRESS_BASE_MULTIPLIER
	
	# Calculate oversupply ratio (clamped to >= 1.0)
	var oversupply_ratio: float = max(1.0, float(current_inv) / float(target_inv))
	
	# Exponential decay: multiplier drops as oversupply increases
	# Formula: base × exp(-steepness × (ratio - 1.0))
	var excess_ratio: float = oversupply_ratio - 1.0
	var multiplier: float = DISTRESS_BASE_MULTIPLIER * exp(-DISTRESS_STEEPNESS * excess_ratio)
	
	# Clamp to floor
	multiplier = max(DISTRESS_FLOOR, multiplier)
	
	return multiplier


## Bid Price API - Used by producers for economic decisions

func get_bid_price(good: String) -> float:
	"""Get current bid price for a good (what market will pay right now).
	Uses target bands to compute market willingness:
	- Below lower_band: strong premium (high willingness)
	- Within bands: normal bid curve
	- Above upper_band: aggressive discount (low willingness)
	Does NOT affect reference price authority."""
	var reference_price: float = 0.0
	var current_inv: int = 0
	var target_inv: int = 0
	var floor_price: float = 0.0
	
	match good:
		"wheat":
			reference_price = wheat_price
			current_inv = wheat
			target_inv = wheat_target
			floor_price = WHEAT_PRICE_FLOOR
		"bread":
			reference_price = bread_price
			current_inv = bread
			target_inv = bread_target
			floor_price = BREAD_PRICE_FLOOR
		_:
			return 0.0
	
	if target_inv <= 0:
		return reference_price
	
	# Calculate target bands
	var lower_band: float = float(target_inv) * (1.0 - TARGET_BAND_PCT)
	var upper_band: float = float(target_inv) * (1.0 + TARGET_BAND_PCT)
	var inv_float: float = float(current_inv)
	
	# Calculate bid multiplier using band-based willingness
	var bid_multiplier: float = 1.0
	
	if inv_float >= upper_band:
		# Above upper band: STEEP discount (market oversupplied)
		# Use exponential decay for aggressive bid collapse
		var excess_ratio: float = (inv_float - upper_band) / float(target_inv)
		
		# Apply steeper curve: exponential decay
		if excess_ratio <= 0.25:
			# 0-25% above upper band: lerp from 0.85 to BAND_UPPER_BID_MULTIPLIER (0.70)
			bid_multiplier = lerp(0.85, BAND_UPPER_BID_MULTIPLIER, excess_ratio / 0.25)
		elif excess_ratio <= 0.5:
			# 25-50% above upper band: lerp from 0.70 to BID_CURVE_SURPLUS_MULTIPLIER (0.5)
			bid_multiplier = lerp(BAND_UPPER_BID_MULTIPLIER, BID_CURVE_SURPLUS_MULTIPLIER, (excess_ratio - 0.25) / 0.25)
		else:
			# >50% above upper band: collapse to BID_CURVE_OVERFLOW_MULTIPLIER (0.3)
			var overflow_ratio: float = min((excess_ratio - 0.5) / 0.5, 1.0)
			bid_multiplier = lerp(BID_CURVE_SURPLUS_MULTIPLIER, BID_CURVE_OVERFLOW_MULTIPLIER, overflow_ratio)
	elif inv_float <= lower_band:
		# Below lower band: strong premium (market undersupplied, high willingness)
		var shortage_ratio: float = (lower_band - inv_float) / float(target_inv)
		shortage_ratio = min(shortage_ratio, 0.5)  # Cap at 50% below lower band
		# Lerp from 1.0 at lower_band to BAND_LOWER_BID_MULTIPLIER at max shortage
		bid_multiplier = lerp(1.0, BAND_LOWER_BID_MULTIPLIER, shortage_ratio / 0.5)
	else:
		# Within bands: normal gentle slope
		var band_position: float = (inv_float - lower_band) / (upper_band - lower_band)
		# Lerp from 1.0 at lower_band to 0.85 at upper_band
		bid_multiplier = lerp(1.0, 0.85, band_position)
	
	# Apply multiplier and enforce floor
	var bid: float = reference_price * bid_multiplier
	return max(bid, floor_price)


func get_max_buy_qty(good: String) -> int:
	"""Get maximum quantity market can buy per trade.
	REFACTOR: Smooth tapering based on bands, NO HARD CUTOFF.
	- Below lower_band: full capacity available
	- Within bands: smooth taper using curve
	- Above upper_band: gentle taper continues (minimum 10% capacity)"""
	var current_inv: int = 0
	var capacity: int = 0
	var target_inv: int = 0
	
	match good:
		"wheat":
			current_inv = wheat
			capacity = wheat_capacity
			target_inv = wheat_target
		"bread":
			current_inv = bread
			capacity = bread_capacity
			target_inv = bread_target
		_:
			return 0
	
	var remaining: int = max(0, capacity - current_inv)
	
	if target_inv <= 0:
		return remaining
	
	# Calculate bands
	var lower_band: float = float(target_inv) * (1.0 - TARGET_BAND_PCT)
	var upper_band: float = float(target_inv) * (1.0 + TARGET_BAND_PCT)
	var inv_float: float = float(current_inv)
	
	# REFACTOR: Smooth tapering instead of hard cutoff
	if inv_float >= upper_band:
		# Above upper band: taper to minimum (10% of remaining)
		var excess_ratio: float = (inv_float - upper_band) / float(target_inv)
		excess_ratio = min(excess_ratio, 0.5)  # Cap at 50% above upper band
		var taper_factor: float = lerp(1.0, BAND_UPPER_MAX_BUY_TAPER, excess_ratio / 0.5)
		return max(1, int(float(remaining) * taper_factor))  # Minimum 1 unit
	
	return max(0, remaining)


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


func buy_wheat_from_farmer(farmer: Farmer, min_acceptable_price: float = 0.0, is_survival: bool = false) -> int:
	"""Micro-fill buying with OVERFLOW support: purchase wheat 1 unit at a time.
	Units beyond capacity go to overflow (export/waste) at discounted bid.
	Stops when bid drops below min_acceptable_price or money runs out.
	is_survival: If true, allows purchase even above upper_band but doesn't update clearing stats."""
	
	# HYSTERESIS GATE: Check if wheat selling is allowed (skip for survival purchases)
	if not is_survival and not can_producer_sell("wheat"):
		if event_bus:
			event_bus.log("Tick %d: %s wheat sale BLOCKED by hysteresis (inventory >= upper_band)" % [current_tick, _agent_label(farmer)])
		return 0
	
	var farmer_inv: Inventory = get_inv(farmer)
	var farmer_wallet: Wallet = get_wallet(farmer)
	var farmer_wheat: int = farmer_inv.get_qty("wheat")
	
	if farmer_wheat <= 0:
		return 0
	
	# OVERFLOW SUPPORT: No hard capacity refusal
	# Determine max units to process this trade (performance cap only)
	var max_units: int = min(farmer_wheat, MAX_MICROFILL_UNITS_PER_TRADE)
	
	# Micro-fill loop: buy 1 unit at a time
	var units_bought: int = 0
	var units_stored: int = 0
	var units_overflow: int = 0
	var total_paid: float = 0.0
	var stored_payment: float = 0.0
	var overflow_payment: float = 0.0
	var initial_bid: float = get_bid_price("wheat")
	var final_bid: float = initial_bid
	var stopped_by_price: bool = false
	var stopped_by_cap: bool = false
	
	for i in range(max_units):
		# Recompute bid based on current inventory
		var current_bid: float = get_bid_price("wheat")
		final_bid = current_bid
		
		# Determine if this unit goes to storage or overflow
		var is_overflow: bool = (wheat >= wheat_capacity)
		
		# Apply escalating distress pricing ONLY to overflow units
		var unit_price: float = current_bid
		if is_overflow:
			var distress_mult: float = get_distress_multiplier("wheat", wheat, wheat_target)
			unit_price = current_bid * distress_mult
		
		# Check if bid dropped below min acceptable (for NORMAL units only)
		# Overflow units ignore walk-away pricing (forced liquidation)
		if not is_overflow and min_acceptable_price > 0.0 and current_bid < min_acceptable_price:
			stopped_by_price = true
			break
		
		# Check if market can afford this unit
		if money < unit_price:
			break
		
		# Buy 1 unit - pay farmer at unit_price
		farmer_inv.remove("wheat", 1)
		farmer_wallet.credit(unit_price)
		money -= unit_price
		total_paid += unit_price
		units_bought += 1
		
		# Route to storage or overflow
		if not is_overflow:
			wheat += 1
			units_stored += 1
			stored_payment += unit_price
		else:
			# Overflow: unit is purchased but not stored (export/waste/dump)
			units_overflow += 1
			overflow_payment += unit_price
	
	# Check if capped by performance limit
	if units_bought == max_units and units_bought < farmer_wheat:
		stopped_by_cap = true
	
	# Track flow for pricing
	wheat_sold_today += units_bought
	daily_wheat_overflow += units_overflow
	
	# Track clearing prices for all valid market-directed trades
	# Exclude survival purchases from pricing statistics
	if units_bought > 0 and not is_survival:
		wheat_total_cleared += units_bought
		wheat_total_value += total_paid
	
	# Summary log
	if event_bus and units_bought > 0:
		var avg_price: float = total_paid / float(units_bought)
		var reason: String = "complete"
		if stopped_by_price:
			reason = "walk-away"
		elif stopped_by_cap:
			reason = "capped"
		
		if units_overflow > 0:
			var avg_stored: float = stored_payment / float(units_stored) if units_stored > 0 else 0.0
			var avg_overflow: float = overflow_payment / float(units_overflow)
			var oversupply_ratio: float = float(wheat) / float(wheat_target)
			var distress_mult: float = get_distress_multiplier("wheat", wheat, wheat_target)
			event_bus.log("Tick %d: %s wheat sale: offered=%d, cleared=%d (stored=%d @$%.2f, overflow=%d @$%.2f DISTRESS×%.2f ratio=%.2f), weighted_avg=$%.2f, bid=%.2f→%.2f (%s)" % [
				current_tick, _agent_label(farmer), farmer_wheat, units_bought, units_stored, avg_stored, units_overflow, avg_overflow, distress_mult, oversupply_ratio, avg_price, initial_bid, final_bid, reason
			])
		else:
			event_bus.log("Tick %d: %s wheat sale: offered=%d, cleared=%d, avg=$%.2f, bid=%.2f→%.2f (%s)" % [
				current_tick, _agent_label(farmer), farmer_wheat, units_bought, avg_price, initial_bid, final_bid, reason
			])
	
	return units_bought


func sell_seeds_to_farmer(farmer: Farmer) -> void:
	var farmer_inv: Inventory = get_inv(farmer)
	var farmer_wallet: Wallet = get_wallet(farmer)
	var current_seeds: int = farmer_inv.get_qty("seeds")
	
	if current_seeds >= 20:
		return
	
	var needed: int = 20 - current_seeds
	
	# Apply seed shock if active (reduces availability)
	if market_shocks:
		var shock_mult: float = market_shocks.get_seed_availability_multiplier()
		needed = max(1, int(float(needed) * shock_mult))
	
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


func buy_bread_from_baker(baker: Baker, min_acceptable_price: float = 0.0, is_survival: bool = false) -> int:
	"""Micro-fill buying with OVERFLOW support: purchase bread 1 unit at a time.
	Units beyond capacity go to overflow (export/waste) at discounted bid.
	Stops when bid drops below min_acceptable_price or money runs out.
	is_survival: If true, allows purchase even above upper_band but doesn't update clearing stats."""
	
	# HYSTERESIS GATE: Check if bread selling is allowed (skip for survival purchases)
	if not is_survival and not can_producer_sell("bread"):
		if event_bus:
			event_bus.log("Tick %d: %s bread sale BLOCKED by hysteresis (inventory >= upper_band)" % [current_tick, _agent_label(baker)])
		return 0
	
	var baker_inv: Inventory = get_inv(baker)
	var baker_wallet: Wallet = get_wallet(baker)
	var baker_bread: int = baker_inv.get_qty("bread")
	
	if baker_bread <= 0:
		return 0
	
	# OVERFLOW SUPPORT: No hard capacity refusal
	# Determine max units to process this trade (performance cap only)
	var max_units: int = min(baker_bread, MAX_MICROFILL_UNITS_PER_TRADE)
	
	# Micro-fill loop: buy 1 unit at a time
	var units_bought: int = 0
	var units_stored: int = 0
	var units_overflow: int = 0
	var total_paid: float = 0.0
	var stored_payment: float = 0.0
	var overflow_payment: float = 0.0
	var initial_bid: float = get_bid_price("bread")
	var final_bid: float = initial_bid
	var stopped_by_price: bool = false
	var stopped_by_cap: bool = false
	
	for i in range(max_units):
		# Recompute bid based on current inventory
		var current_bid: float = get_bid_price("bread")
		final_bid = current_bid
		
		# Determine if this unit goes to storage or overflow
		var is_overflow: bool = (bread >= bread_capacity)
		
		# Apply escalating distress pricing ONLY to overflow units
		var unit_price: float = current_bid
		if is_overflow:
			var distress_mult: float = get_distress_multiplier("bread", bread, bread_target)
			unit_price = current_bid * distress_mult
		
		# Check if bid dropped below min acceptable (for NORMAL units only)
		# Overflow units ignore walk-away pricing (forced liquidation)
		if not is_overflow and min_acceptable_price > 0.0 and current_bid < min_acceptable_price:
			stopped_by_price = true
			break
		
		# Check if market can afford this unit
		if money < unit_price:
			break
		
		# Buy 1 unit - pay baker at unit_price
		baker_inv.remove("bread", 1)
		baker_wallet.credit(unit_price)
		money -= unit_price
		total_paid += unit_price
		units_bought += 1
		
		# Route to storage or overflow
		if not is_overflow:
			bread += 1
			units_stored += 1
			stored_payment += unit_price
		else:
			# Overflow: unit is purchased but not stored (export/waste/dump)
			units_overflow += 1
			overflow_payment += unit_price
	
	# Check if capped by performance limit
	if units_bought == max_units and units_bought < baker_bread:
		stopped_by_cap = true
	
	# Track flow for pricing
	bread_sold_today += units_bought
	daily_bread_overflow += units_overflow
	
	# Track clearing prices for all valid market-directed trades
	# Exclude survival purchases from pricing statistics
	if units_bought > 0 and not is_survival:
		bread_total_cleared += units_bought
		bread_total_value += total_paid
	
	# Summary log
	if event_bus and units_bought > 0:
		var avg_price: float = total_paid / float(units_bought)
		var reason: String = "complete"
		if stopped_by_price:
			reason = "walk-away"
		elif stopped_by_cap:
			reason = "capped"
		var trade_type: String = " (SURVIVAL)" if is_survival else ""
		
		if units_overflow > 0:
			var avg_stored: float = stored_payment / float(units_stored) if units_stored > 0 else 0.0
			var avg_overflow: float = overflow_payment / float(units_overflow)
			var oversupply_ratio: float = float(bread) / float(bread_target)
			var distress_mult: float = get_distress_multiplier("bread", bread, bread_target)
			event_bus.log("Tick %d: %s bread sale: offered=%d, cleared=%d (stored=%d @$%.2f, overflow=%d @$%.2f DISTRESS×%.2f ratio=%.2f), weighted_avg=$%.2f, bid=%.2f→%.2f (%s)%s" % [
				current_tick, _agent_label(baker), baker_bread, units_bought, units_stored, avg_stored, units_overflow, avg_overflow, distress_mult, oversupply_ratio, avg_price, initial_bid, final_bid, reason, trade_type
			])
		else:
			event_bus.log("Tick %d: %s bread sale: offered=%d, cleared=%d, avg=$%.2f, bid=%.2f→%.2f (%s)%s" % [
				current_tick, _agent_label(baker), baker_bread, units_bought, avg_price, initial_bid, final_bid, reason, trade_type
			])
	
	return units_bought


func buy_bread_from_agent(agent, amount_offered: int, min_acceptable_price: float = 0.0, is_survival: bool = false) -> int:
	"""Micro-fill buying with OVERFLOW support: purchase bread 1 unit at a time.
	Units beyond capacity go to overflow (export/waste) at discounted bid.
	Stops when bid drops below min_acceptable_price or money runs out.
	is_survival: If true, allows purchase even above upper_band but doesn't update clearing stats."""
	
	# HYSTERESIS GATE: Check if bread selling is allowed (applies to all producers, skip for survival)
	# Note: Baker is the primary bread producer, but this gate applies generically
	if not is_survival and agent is Baker and not can_producer_sell("bread"):
		if event_bus:
			event_bus.log("Tick %d: %s bread sale BLOCKED by hysteresis (inventory >= upper_band)" % [current_tick, _agent_label(agent)])
		return 0
	
	if amount_offered <= 0:
		return 0
	
	var agent_inv: Inventory = get_inv(agent)
	var agent_wallet: Wallet = get_wallet(agent)
	var agent_bread: int = agent_inv.get_qty("bread")
	
	if agent_bread <= 0:
		return 0
	
	# OVERFLOW SUPPORT: No hard capacity refusal
	# Determine max units to process this trade (performance cap only)
	var max_units: int = min(amount_offered, agent_bread, MAX_MICROFILL_UNITS_PER_TRADE)
	
	# Micro-fill loop: buy 1 unit at a time
	var units_bought: int = 0
	var units_stored: int = 0
	var units_overflow: int = 0
	var total_paid: float = 0.0
	var stored_payment: float = 0.0
	var overflow_payment: float = 0.0
	var initial_bid: float = get_bid_price("bread")
	var final_bid: float = initial_bid
	var stopped_by_price: bool = false
	var stopped_by_cap: bool = false
	
	for i in range(max_units):
		# Recompute bid based on current inventory
		var current_bid: float = get_bid_price("bread")
		final_bid = current_bid
		
		# Determine if this unit goes to storage or overflow
		var is_overflow: bool = (bread >= bread_capacity)
		
		# Apply escalating distress pricing ONLY to overflow units
		var unit_price: float = current_bid
		if is_overflow:
			var distress_mult: float = get_distress_multiplier("bread", bread, bread_target)
			unit_price = current_bid * distress_mult
		
		# Check if bid dropped below min acceptable (for NORMAL units only)
		# Overflow units ignore walk-away pricing (forced liquidation)
		if not is_overflow and min_acceptable_price > 0.0 and current_bid < min_acceptable_price:
			stopped_by_price = true
			break
		
		# Check if market can afford this unit
		if money < unit_price:
			break
		
		# Buy 1 unit - pay agent at unit_price
		agent_inv.remove("bread", 1)
		agent_wallet.credit(unit_price)
		money -= unit_price
		total_paid += unit_price
		units_bought += 1
		
		# Route to storage or overflow
		if not is_overflow:
			bread += 1
			units_stored += 1
			stored_payment += unit_price
		else:
			# Overflow: unit is purchased but not stored (export/waste/dump)
			units_overflow += 1
			overflow_payment += unit_price
	
	# Check if capped by performance limit
	if units_bought == max_units and units_bought < amount_offered:
		stopped_by_cap = true
	
	# Track flow for pricing
	bread_sold_today += units_bought
	daily_bread_overflow += units_overflow
	
	# Track clearing prices for all valid market-directed trades
	# Exclude survival purchases from pricing statistics
	if units_bought > 0 and not is_survival:
		bread_total_cleared += units_bought
		bread_total_value += total_paid
	
	# Summary log
	if event_bus and units_bought > 0:
		var avg_price: float = total_paid / float(units_bought)
		var reason: String = "complete"
		if stopped_by_price:
			reason = "walk-away"
		elif stopped_by_cap:
			reason = "capped"
		var trade_type: String = " (SURVIVAL)" if is_survival else ""
		
		if units_overflow > 0:
			var avg_stored: float = stored_payment / float(units_stored) if units_stored > 0 else 0.0
			var avg_overflow: float = overflow_payment / float(units_overflow)
			var oversupply_ratio: float = float(bread) / float(bread_target)
			var distress_mult: float = get_distress_multiplier("bread", bread, bread_target)
			event_bus.log("Tick %d: %s bread sale: offered=%d, cleared=%d (stored=%d @$%.2f, overflow=%d @$%.2f DISTRESS×%.2f ratio=%.2f), weighted_avg=$%.2f, bid=%.2f→%.2f (%s)%s" % [
				current_tick, _agent_label(agent), amount_offered, units_bought, units_stored, avg_stored, units_overflow, avg_overflow, distress_mult, oversupply_ratio, avg_price, initial_bid, final_bid, reason, trade_type
			])
		else:
			event_bus.log("Tick %d: %s bread sale: offered=%d, cleared=%d, avg=$%.2f, bid=%.2f→%.2f (%s)%s" % [
				current_tick, _agent_label(agent), amount_offered, units_bought, avg_price, initial_bid, final_bid, reason, trade_type
			])
	
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
	current_day = day
	
	# Apply inventory decay first (before price adjustments)
	_apply_inventory_decay(day)
	
	_adjust_wheat_price(day)
	_adjust_bread_price(day)
	
	# Store current inventory for next day's recovery detection
	wheat_prev = wheat
	bread_prev = bread
	
	# REFACTOR: Removed market-side hysteresis blocking logs (no longer applicable)
	
	# Reset daily flow counters
	wheat_sold_today = 0
	wheat_requested_today = 0
	bread_sold_today = 0
	bread_requested_today = 0
	
	# Reset overflow counters
	daily_wheat_overflow = 0
	daily_bread_overflow = 0
	
	# REFACTOR: Removed market-side hysteresis tracking reset (no longer used)
	
	# Reset clearing price tracking
	wheat_total_cleared = 0
	wheat_total_value = 0.0
	bread_total_cleared = 0
	bread_total_value = 0.0


func _apply_inventory_decay(day: int) -> void:
	"""Apply inventory decay smoothly, only when inventory > upper_band.
	REFACTOR: Removed weekly windowing - decay rate is consistent per-day now."""
	# Early-game stabilization - disable decay for first N days
	if day < DECAY_DISABLE_DAYS:
		return
	
	for good_name in DECAY_CONFIG.keys():
		var config = DECAY_CONFIG[good_name]
		if not config.get("enabled", false):
			continue
		if not config.get("applies_to_market", false):
			continue
		
		# Get current inventory, target, and upper band for this good
		var current_inventory: int = 0
		var target_inventory: int = 0
		var upper_band: int = 0
		
		match good_name:
			"wheat":
				current_inventory = wheat
				target_inventory = wheat_target
				upper_band = int(float(wheat_target) * (1.0 + TARGET_BAND_PCT))
			"bread":
				current_inventory = bread
				target_inventory = bread_target
				upper_band = int(float(bread_target) * (1.0 + TARGET_BAND_PCT))
			"seeds":
				current_inventory = seeds
				target_inventory = 0  # Seeds have no target
				upper_band = 0
			_:
				continue  # Unknown good
		
		if current_inventory <= 0:
			continue  # No inventory to decay
		
		# Only decay when inventory > upper_band (true oversupply)
		if current_inventory <= upper_band:
			continue  # Skip decay when at or below upper band
		
		# REFACTOR: Use simple random rate within range each day
		var min_rate: float = config.get("min_rate_per_day", 0.0)
		var max_rate: float = config.get("max_rate_per_day", 0.0)
		var current_decay_rate: float = randf_range(min_rate, max_rate)
		
		# Calculate decay amount using rate (floor to integer)
		var decay_amount: int = int(floor(float(current_inventory) * current_decay_rate))
		if decay_amount <= 0:
			continue  # No decay this day
		
		# Apply decay to inventory (never below zero)
		var old_inventory: int = current_inventory
		match good_name:
			"wheat":
				wheat = max(0, wheat - decay_amount)
				current_inventory = wheat
			"bread":
				bread = max(0, bread - decay_amount)
				current_inventory = bread
			"seeds":
				seeds = max(0, seeds - decay_amount)
				current_inventory = seeds
		
		# Log decay application
		if event_bus:
			event_bus.log("Day %d: %s decay removed %d units (rate %.1f%%), inv %d→%d" % [
				day, good_name, decay_amount, current_decay_rate * 100.0,
				old_inventory, current_inventory
			])


func _adjust_wheat_price(day: int) -> void:
	var old_price: float = wheat_price
	
	# Calculate clearing price statistics
	var has_clearing_data: bool = wheat_total_cleared >= MIN_TRADES_FOR_PRICE_DISCOVERY
	var avg_clearing_price: float = 0.0
	if wheat_total_cleared > 0:
		avg_clearing_price = wheat_total_value / float(wheat_total_cleared)
	
	var new_price: float = old_price
	var cap_applied: bool = false
	var update_reason: String = ""
	
	if has_clearing_data:
		# PRICE DISCOVERY MODE: Anchor reference to actual clearing prices
		# Step 1: Lerp reference toward clearing price
		new_price = lerp(old_price, avg_clearing_price, CLEARING_ANCHOR_STRENGTH)
		
		# Step 2: Apply bounded inventory nudge
		var inv_ratio: float = float(wheat) / float(wheat_target) if wheat_target > 0 else 1.0
		var inventory_nudge: float = 0.0
		if wheat < wheat_target:
			# Low inventory -> small upward nudge
			inventory_nudge = min(MAX_INVENTORY_NUDGE_PER_DAY, (1.0 - inv_ratio) * MAX_INVENTORY_NUDGE_PER_DAY)
		elif wheat > wheat_target:
			# High inventory -> small downward nudge
			inventory_nudge = -min(MAX_INVENTORY_NUDGE_PER_DAY, (inv_ratio - 1.0) * MAX_INVENTORY_NUDGE_PER_DAY)
		
		# Change 1: Downward pressure on recovery (only when inventory >= upper_band)
		var upper_band: int = int(float(wheat_target) * (1.0 + TARGET_BAND_PCT))
		if wheat > wheat_prev and wheat >= upper_band:
			# Inventory increased and above upper band (oversupply) -> apply downward adjustment
			# Mirror the upward adjustment magnitude used during scarcity
			var recovery_adjustment: float = -min(MAX_INVENTORY_NUDGE_PER_DAY, (1.0 - inv_ratio) * MAX_INVENTORY_NUDGE_PER_DAY)
			inventory_nudge += recovery_adjustment
		
		new_price *= (1.0 + inventory_nudge)
		
		# Step 3: CRITICAL - prevent upward drift beyond clearing reality
		var max_allowed_price: float = avg_clearing_price * (1.0 + MAX_PREMIUM_OVER_CLEARING)
		if new_price > max_allowed_price:
			new_price = max_allowed_price
			cap_applied = true
		update_reason = "cleared"
	elif wheat_total_cleared == 0:
		# REFACTOR: No trades - check if oversupply exists
		var upper_band: int = int(float(wheat_target) * (1.0 + TARGET_BAND_PCT))
		
		if wheat > upper_band:
			# Inventory oversupplied with no demand -> decrease price
			new_price *= (1.0 - PRICE_STEP)
			update_reason = "no-demand decrease"
		else:
			# Normal inventory but no demand -> hold price flat
			new_price = old_price
			update_reason = "no-demand cap"
	else:
		# Trades below threshold: allow only neutral or downward movement
		var upper_band: int = int(float(wheat_target) * (1.0 + TARGET_BAND_PCT))
		
		if wheat > upper_band:
			# Low trades with oversupply -> decrease
			new_price *= (1.0 - PRICE_STEP)
			update_reason = "low-trades decrease"
		else:
			# Low trades but normal inventory -> hold
			new_price = old_price
			update_reason = "low-trades cap"
	
	# Change 3: Apply hard daily price movement cap (±5%)
	var max_change: float = old_price * MAX_DAILY_PRICE_CHANGE
	if new_price > old_price + max_change:
		new_price = old_price + max_change
	elif new_price < old_price - max_change:
		new_price = old_price - max_change
	
	# Apply floor and ceiling
	wheat_price = clamp(new_price, WHEAT_PRICE_FLOOR, WHEAT_PRICE_CEILING)
	
	# Calculate band status for logging
	var lower_band: int = int(float(wheat_target) * (1.0 - TARGET_BAND_PCT))
	var upper_band: int = int(float(wheat_target) * (1.0 + TARGET_BAND_PCT))
	var bid_mult: float = get_bid_price("wheat") / wheat_price if wheat_price > 0 else 1.0
	var max_buy: int = get_max_buy_qty("wheat")
	
	# Daily diagnostic log
	if event_bus:
		if wheat_total_cleared > 0:
			event_bus.log("Day %d: wheat | inv %d [%d-%d-%d] | bid×%.2f | cap %d | trades=%d | $%.2f→$%.2f | %s" % [
				day, wheat, lower_band, wheat_target, upper_band, bid_mult, max_buy,
				wheat_total_cleared, old_price, wheat_price,
				update_reason + (" (CAP)" if cap_applied else "")
			])
		else:
			event_bus.log("Day %d: wheat | inv %d [%d-%d-%d] | bid×%.2f | cap %d | trades=0 | $%.2f→$%.2f | %s" % [
				day, wheat, lower_band, wheat_target, upper_band, bid_mult, max_buy,
				old_price, wheat_price, update_reason
			])


func _adjust_bread_price(day: int) -> void:
	var old_price: float = bread_price
	
	# Calculate clearing price statistics
	var has_clearing_data: bool = bread_total_cleared >= MIN_TRADES_FOR_PRICE_DISCOVERY
	var avg_clearing_price: float = 0.0
	if bread_total_cleared > 0:
		avg_clearing_price = bread_total_value / float(bread_total_cleared)
	
	var new_price: float = old_price
	var cap_applied: bool = false
	var update_reason: String = ""
	
	if has_clearing_data:
		# PRICE DISCOVERY MODE: Anchor reference to actual clearing prices
		# Step 1: Lerp reference toward clearing price
		new_price = lerp(old_price, avg_clearing_price, CLEARING_ANCHOR_STRENGTH)
		
		# Step 2: Apply bounded inventory nudge
		var inv_ratio: float = float(bread) / float(bread_target) if bread_target > 0 else 1.0
		var inventory_nudge: float = 0.0
		if bread < bread_target:
			# Low inventory -> small upward nudge
			inventory_nudge = min(MAX_INVENTORY_NUDGE_PER_DAY, (1.0 - inv_ratio) * MAX_INVENTORY_NUDGE_PER_DAY)
		elif bread > bread_target:
			# High inventory -> small downward nudge
			inventory_nudge = -min(MAX_INVENTORY_NUDGE_PER_DAY, (inv_ratio - 1.0) * MAX_INVENTORY_NUDGE_PER_DAY)
		
		# Change 1: Downward pressure on recovery (only when inventory >= upper_band)
		var upper_band: int = int(float(bread_target) * (1.0 + TARGET_BAND_PCT))
		if bread > bread_prev and bread >= upper_band:
			# Inventory increased and above upper band (oversupply) -> apply downward adjustment
			# Mirror the upward adjustment magnitude used during scarcity
			var recovery_adjustment: float = -min(MAX_INVENTORY_NUDGE_PER_DAY, (1.0 - inv_ratio) * MAX_INVENTORY_NUDGE_PER_DAY)
			inventory_nudge += recovery_adjustment
		
		new_price *= (1.0 + inventory_nudge)
		
		# Step 3: CRITICAL - prevent upward drift beyond clearing reality
		var max_allowed_price: float = avg_clearing_price * (1.0 + MAX_PREMIUM_OVER_CLEARING)
		if new_price > max_allowed_price:
			new_price = max_allowed_price
			cap_applied = true
		update_reason = "cleared"
	elif bread_total_cleared == 0:
		# REFACTOR: No trades - check if oversupply exists
		var upper_band: int = int(float(bread_target) * (1.0 + TARGET_BAND_PCT))
		
		if bread > upper_band:
			# Inventory oversupplied with no demand -> decrease price
			new_price *= (1.0 - PRICE_STEP)
			update_reason = "no-demand decrease"
		else:
			# Normal inventory but no demand -> hold price flat
			new_price = old_price
			update_reason = "no-demand cap"
	else:
		# Trades below threshold: allow only neutral or downward movement
		var upper_band: int = int(float(bread_target) * (1.0 + TARGET_BAND_PCT))
		
		if bread > upper_band:
			# Low trades with oversupply -> decrease
			new_price *= (1.0 - PRICE_STEP)
			update_reason = "low-trades decrease"
		else:
			# Low trades but normal inventory -> hold
			new_price = old_price
			update_reason = "low-trades cap"
	
	# Change 3: Apply hard daily price movement cap (±5%)
	var max_change: float = old_price * MAX_DAILY_PRICE_CHANGE
	if new_price > old_price + max_change:
		new_price = old_price + max_change
	elif new_price < old_price - max_change:
		new_price = old_price - max_change
	
	# Apply floor and ceiling
	bread_price = clamp(new_price, BREAD_PRICE_FLOOR, BREAD_PRICE_CEILING)
	
	# Calculate band status for logging
	var lower_band: int = int(float(bread_target) * (1.0 - TARGET_BAND_PCT))
	var upper_band: int = int(float(bread_target) * (1.0 + TARGET_BAND_PCT))
	var bid_mult: float = get_bid_price("bread") / bread_price if bread_price > 0 else 1.0
	var max_buy: int = get_max_buy_qty("bread")
	
	# Daily diagnostic log
	if event_bus:
		if bread_total_cleared > 0:
			event_bus.log("Day %d: bread | inv %d [%d-%d-%d] | bid×%.2f | cap %d | trades=%d | $%.2f→$%.2f | %s" % [
				day, bread, lower_band, bread_target, upper_band, bid_mult, max_buy,
				bread_total_cleared, old_price, bread_price,
				update_reason + (" (CAP)" if cap_applied else "")
			])
		else:
			event_bus.log("Day %d: bread | inv %d [%d-%d-%d] | bid×%.2f | cap %d | trades=0 | $%.2f→$%.2f | %s" % [
				day, bread, lower_band, bread_target, upper_band, bid_mult, max_buy,
				old_price, bread_price, update_reason
			])
