extends Node
class_name Market

# Structured result from the most recent buy/sell call.
# Keys: qty (int), reason (String), item (String), price (float), market_inv (int)
# Reason codes: "success", "partial", "blocked", "empty",
#   "insufficient_funds", "storage_full", "walk_away", "capped", "zero_request"
var last_trade_result: Dictionary = {}

# Batch 2 (docs/ECONOMY_BATCH2.md): a market with limits. It starts with a few thousand coins,
# holds at most twice its stock target (wheat_target 45, bread_target 50) and can only buy what
# it can pay for.
const START_MONEY: float = 3000.0
var money: float = Tuning.f("market_start_coins", START_MONEY)
var seeds: int = 100000
var wheat: int = 0
var bread: int = 0

var wheat_capacity: int = 90    # 2 x wheat_target
var bread_capacity: int = 100   # 2 x bread_target
# Villages differ (batch 2): set by World per village.
var soil_mult: float = 1.0   # wheat per harvest
## Troubles in force (scripts/village/shocks.gd): blight, an oven fire, a hard frost.
var shock_harvest_mult: float = 1.0
var shock_oven_mult: float = 1.0
var shock_extra_burn: int = 0
var oven_mult: float = 1.0   # loaves per oven day

const SEED_PRICE: float = 0.5
## Bread and wheat have a floor (1.00) and no ceiling: demand sets the price (docs/BREAD_MARKET.md).
const PRICE_STEP: float = 0.10  # 10% adjustment per day

# Price floors - stable lower bounds for staple goods
const WHEAT_PRICE_FLOOR: float = 1.00
const BREAD_PRICE_FLOOR: float = 1.00

# Decay configuration - generic per-good spoilage/loss mechanic
const DECAY_CONFIG: Dictionary = {
	"wheat": {
		"enabled": true,
		"min_rate_per_day": 0.01,  # PART 1: Reduced from 0.03 to 0.01
		"max_rate_per_day": 0.04,  # PART 1: Reduced from 0.10 to 0.04
		"applies_to_market": true
	},
	"bread": {
		"enabled": true,
		"min_rate_per_day": 0.02,  # PART 1: Reduced from 0.03 to 0.02
		"max_rate_per_day": 0.06,  # PART 1: Reduced from 0.10 to 0.06
		"applies_to_market": true
	},
	"seeds": {
		"enabled": false,
		"min_rate_per_day": 0.0,
		"max_rate_per_day": 0.0,
		"applies_to_market": false
	}
}

# PART 3: Weekly-held decay configuration
const DECAY_WINDOW_DAYS: int = 7  # Hold decay rate constant for 7 days

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
const BID_CURVE_SURPLUS_MULTIPLIER: float = 0.7  # Min 30% discount when full
const BID_CURVE_PRE_TARGET_RATIO: float = 0.80  # Where steep decline starts (80% of target)
const BID_CURVE_STEEPNESS: float = 3.0  # Exponent for steep decline near target (higher = steeper)
const MAX_MICROFILL_UNITS_PER_TRADE: int = 25  # Performance cap

# Price discovery configuration - reference prices follow clearing prices
const CLEARING_ANCHOR_STRENGTH: float = 0.5  # How much reference lerps toward clearing price (0.0-1.0)
const MAX_PREMIUM_OVER_CLEARING: float = 0.05  # Max 5% premium over avg clearing price
const MAX_INVENTORY_NUDGE_PER_DAY: float = 0.03  # Max 3% inventory-based adjustment per day
const MIN_TRADES_FOR_PRICE_DISCOVERY: int = 5  # Minimum trades to use price discovery
const MAX_DAILY_PRICE_CHANGE: float = 0.05  # Max 5% daily price movement cap
const DECAY_DISABLE_DAYS: int = 10  # Disable decay for first N days

# Producer hysteresis configuration - prevents price drift to floors by gating producer behavior at bands
const PRODUCER_HYSTERESIS_CONFIG: Dictionary = {
	"wheat": {
		"enabled": true,
		"stop_sell_at_or_above_upper_band": false,
		"resume_sell_at_or_below_lower_band": false,
		"stop_produce_at_or_above_upper_band": true,
		"resume_produce_at_or_below_lower_band": true
	},
	"bread": {
		"enabled": true,
		"stop_sell_at_or_above_upper_band": true,
		"resume_sell_at_or_below_lower_band": true,
		"stop_produce_at_or_above_upper_band": true,
		"resume_produce_at_or_below_lower_band": true
	}
}

var wheat_price: float = 1.0
var bread_price: float = 3.2   # batch 3: a loaf now takes 2 wheat and oven firewood (was 2.5)

# Firewood (batch 3). Woodworkers sell it here; every hearth and every oven buys it here.
const FIREWOOD_PRICE_FLOOR: float = 0.50   # no ceiling (Anthony's rule: no price caps)
var firewood: int = 30
var firewood_price: float = 1.5
var firewood_target: int = 30
var firewood_capacity: int = 80
var firewood_sold_today: int = 0
var firewood_bought_today: int = 0
var firewood_requested_today: int = 0
var firewood_short_today: int = 0
var firewood_wanted_today: int = 0   # asked for by buyers with the coins to pay for it
var firewood_sold_ema: float = 6.0

# PART 3: Targets aligned with actual throughput
## How much wheat the market aims to hold: a few days of what bakers actually buy, the same
## rule as bread. It was a fixed 45, so the farmer's ease-off and the wheat price answered
## to a made-up number instead of how much the bakers really use.
var wheat_target: int = 45
const WHEAT_DAYS_OF_STOCK: float = 3.0
const WHEAT_TARGET_MIN: int = 6
var wheat_bought_by_bakers_today: int = 0
var wheat_short_today: int = 0
var wheat_demand_ema: float = 15.0
## How much bread the market aims to hold: a few days of what people actually want. It
## follows demand instead of a fixed number, so the baker's ramp up / ease off and the
## price both answer to how much the town really eats.
var bread_target: int = 18
const BREAD_DAYS_OF_STOCK: float = 3.0
const BREAD_TARGET_MIN: int = 3          # only so the ratios never divide by zero
## Demand = loaves people bought + loaves they wanted but the shelf was empty. People who
## couldn't afford a loaf are not counted: that is a money problem, not demand.
var bread_bought_by_people_today: int = 0
var bread_short_today: int = 0
## Who was turned away today and for how much, so the same person coming back five times
## is one shortfall, not five (it drove the bread target to 158 loaves after a fire).
var _short_by: Dictionary = {"bread": {}, "wheat": {}}
var bread_demand_ema: float = 6.0

# Previous day inventory tracking for recovery detection
var wheat_prev: int = 0
var bread_prev: int = 0
var current_day: int = 0

# PART 3: Weekly-held decay rate tracking
var wheat_decay_rate: float = 0.0
var wheat_decay_days_remaining: int = 0
var bread_decay_rate: float = 0.0
var bread_decay_days_remaining: int = 0

# Trade flow tracking (reset daily)
var wheat_sold_today: int = 0
var wheat_requested_today: int = 0
var bread_sold_today: int = 0
var bread_requested_today: int = 0

# Market-side hysteresis tracking - prevents buy clearing above upper band
var wheat_market_buy_blocked: bool = false
var bread_market_buy_blocked: bool = false

# Clearing price tracking (reset daily) - prevents reference price ratcheting
## Running totals since the game began, for tests and the HUD (never reset).
var totals := {"wheat_from_farmers": 0, "wheat_to_bakers": 0, "bread_from_bakers": 0,
	"bread_to_people": 0, "firewood_in": 0, "firewood_out": 0}
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

var market_seeded: bool = false

var event_bus: EventBus = null
var current_tick: int = 0


func seed_market(seed_wheat: int, seed_bread: int, seed_seeds: int) -> void:
	if market_seeded:
		return
	market_seeded = true
	wheat += seed_wheat
	bread += seed_bread
	seeds += seed_seeds
	_update_producer_hysteresis("wheat", wheat, wheat_target)
	_update_producer_hysteresis("bread", bread, bread_target)
	var msg := "[BOOTSTRAP] Seeded market: wheat=%d bread=%d seeds=%d (day=0 tick=0)" % [
		seed_wheat, seed_bread, seed_seeds]
	print(msg)
	if event_bus:
		event_bus.emit_log(msg)


# ── Buyers pay the makers (docs/BUY_FROM_MAKERS.md) ──────────────────────────────
## The market is the place goods are sold and where their price is set. It is not a buyer:
## a maker puts goods on the shelf and is paid when somebody buys them, with the buyer's own
## coins at the price the buyer paid. Before 2026-11-13 the market bought everything with a
## purse of its own; when owners piled up their takings that purse ran dry, the market could
## buy nothing, the shelves emptied and people starved holding coins.
##
## Whose goods are on each shelf: good -> {key -> {"who": the maker, or null for the town's
## own stock, "qty": how much of the shelf is theirs}}. Each maker's goods are that maker's
## stall: a buyer picks one stall by chance and buys there (_take_payment). Goods lost from
## the shelf (spoiling, rats) are lost by everyone in the same share.
var shelf: Dictionary = {"wheat": {}, "bread": {}, "firewood": {}}
var paid_to_makers: Dictionary = {"wheat": 0.0, "bread": 0.0, "firewood": 0.0}
var paid_to_town: Dictionary = {"wheat": 0.0, "bread": 0.0, "firewood": 0.0}
## Who made the stock nobody is recorded as bringing (what the shelf starts with): the
## town's first maker of that good. Set by the village.
var first_maker: Callable = func(_good: String): return null


static func direct() -> bool:
	return Tuning.on("buy_from_makers", true)


## Bring the ledger for `good` in line with `stock` units on the shelf.
func _sync_shelf(good: String, stock: int) -> void:
	var d: Dictionary = shelf[good]
	var held: float = 0.0
	for k in d:
		held += float(d[k].qty)
	if stock <= 0:
		d.clear()
	elif held <= 0.0001:
		d.clear()
		var maker = first_maker.call(good)
		if maker != null and is_instance_valid(maker):
			d[maker.get_instance_id()] = {"who": maker, "qty": float(stock)}
		else:
			d["town"] = {"who": null, "qty": float(stock)}   # nobody to credit: the town's
	elif absf(held - float(stock)) > 0.0001:
		var f: float = float(stock) / held
		for k in d:
			d[k].qty = float(d[k].qty) * f


## `seller` has just put `qty` of `good` on the shelf (the stock already counts it).
func _shelve(good: String, seller, qty: int) -> void:
	if qty <= 0:
		return
	_sync_shelf(good, int(get(good)) - qty)
	var d: Dictionary = shelf[good]
	if seller == null or not is_instance_valid(seller):
		var t: Dictionary = d.get("town", {"who": null, "qty": 0.0})
		t.qty = float(t.qty) + float(qty)
		d["town"] = t
		return
	var key: int = seller.get_instance_id()
	var e: Dictionary = d.get(key, {"who": seller, "qty": 0.0})
	e.qty = float(e.qty) + float(qty)
	d[key] = e


## Tests: put `qty` of `good` on the shelf as `seller`'s (null: nobody's).
func _shelve_for_test(good: String, seller, qty: int) -> void:
	set(good, int(get(good)) + qty)
	_shelve(good, seller, qty)


## How much of `good` on the shelf is `seller`'s.
func on_shelf(good: String, seller) -> float:
	if seller == null or not is_instance_valid(seller):
		return 0.0
	_sync_shelf(good, int(get(good)))
	var e = (shelf[good] as Dictionary).get(seller.get_instance_id(), null)
	return float(e.qty) if e != null else 0.0


## A buyer has paid `cost` for `qty` of `good` (call before the stock is reduced). With
## buy_from_makers on, the buyer has picked one maker's stall by chance (Anthony: "If I'm
## walking down an open market and I see 12 vendors, I pick one and I buy their stuff") and
## that maker gets the whole payment. If that stall has less than the buyer wants, the rest
## comes from another stall picked the same way. Goods of someone who is gone, and the town's
## own stock, are one more stall, and what they sell for goes to the town's purse.
func _take_payment(good: String, qty: int, cost: float) -> void:
	if not direct():
		money += cost
		return
	var stock: int = int(get(good))
	_sync_shelf(good, stock)
	var d: Dictionary = shelf[good]
	var each: float = cost / float(maxi(1, qty))
	var want: float = float(qty)
	var left: float = cost
	while want > 0.0001 and not d.is_empty():
		var keys: Array = d.keys()
		var k = keys[randi() % keys.size()]
		var e: Dictionary = d[k]
		var take: float = minf(want, float(e.qty))
		var coins: float = each * take
		e.qty = float(e.qty) - take
		want -= take
		left -= coins
		var who = e.who
		var w: Wallet = get_wallet(who) if who != null and is_instance_valid(who) and not who.is_queued_for_deletion() else null
		if w != null:
			w.credit(coins)
			who.cashflow_today_income += coins
			paid_to_makers[good] = float(paid_to_makers[good]) + coins
		else:
			money += coins
			paid_to_town[good] = float(paid_to_town[good]) + coins
		if float(e.qty) <= 0.0001:
			d.erase(k)
	if absf(left) > 0.0000001:
		money += left


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
		event_bus.emit_log("[MARKET PARAMS] wheat: target=%d, lower_band=%d, upper_band=%d, band_pct=%.2f, decay_min=%.2f, decay_max=%.2f, lower_bid_mult=%.2f" % [
			wheat_target, wheat_lower, wheat_upper, TARGET_BAND_PCT,
			DECAY_CONFIG["wheat"]["min_rate_per_day"],
			DECAY_CONFIG["wheat"]["max_rate_per_day"],
			BAND_LOWER_BID_MULTIPLIER
		])
		# Log bread parameters
		var bread_lower: int = int(float(bread_target) * (1.0 - TARGET_BAND_PCT))
		var bread_upper: int = int(float(bread_target) * (1.0 + TARGET_BAND_PCT))
		event_bus.emit_log("[MARKET PARAMS] bread: target=%d, lower_band=%d, upper_band=%d, band_pct=%.2f, decay_min=%.2f, decay_max=%.2f, lower_bid_mult=%.2f" % [
			bread_target, bread_lower, bread_upper, TARGET_BAND_PCT,
			DECAY_CONFIG["bread"]["min_rate_per_day"],
			DECAY_CONFIG["bread"]["max_rate_per_day"],
			BAND_LOWER_BID_MULTIPLIER
		])
	
	# Enforce price floors and ceilings
	wheat_price = maxf(wheat_price, WHEAT_PRICE_FLOOR)
	bread_price = maxf(bread_price, BREAD_PRICE_FLOOR)
	
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
				event_bus.emit_log("[HYSTERESIS] %s SELLING RESUMED (inventory %d <= lower_band %d)" % [good, current_inv, lower_band])
			else:
				event_bus.emit_log("[HYSTERESIS] %s SELLING PAUSED (inventory %d >= upper_band %d)" % [good, current_inv, upper_band])
	
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
				event_bus.emit_log("[HYSTERESIS] %s PRODUCTION RESUMED (inventory %d <= lower_band %d)" % [good, current_inv, lower_band])
			else:
				event_bus.emit_log("[HYSTERESIS] %s PRODUCTION PAUSED (inventory %d >= upper_band %d)" % [good, current_inv, upper_band])


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
	"""Check if market buying is currently blocked due to hysteresis (inventory >= upper_band).
	PART 1: Distinguish market-blocked state from no-demand state."""
	match good:
		"wheat":
			return wheat_market_buy_blocked
		"bread":
			return bread_market_buy_blocked
		_:
			return false


func get_production_throttle_for_hysteresis(good: String) -> float:
	"""Get procurement throttle factor based on hysteresis state.
	Returns 0.0 when production paused, 1.0 when production allowed."""
	if not can_producer_produce(good):
		return 0.0
	return 1.0


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
		# Above upper band: aggressive discount (market saturated, low willingness)
		var excess_ratio: float = (inv_float - upper_band) / float(target_inv)
		excess_ratio = min(excess_ratio, 0.5)  # Cap at 50% above upper band
		# Lerp from 0.85 at upper_band to BAND_UPPER_BID_MULTIPLIER at max excess
		bid_multiplier = lerp(0.85, BAND_UPPER_BID_MULTIPLIER, excess_ratio / 0.5)
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
	Uses target bands to taper willingness:
	- Below lower_band: full capacity available
	- Within bands: normal capacity
	- Above upper_band: HARD CUTOFF - returns 0 (market-side hysteresis)"""
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
	
	# PART 1: HARD CUTOFF - When inventory >= upper_band, NO market-directed purchases allowed
	# This prevents prices from drifting downward due to forced clearing at discount bids
	if inv_float >= upper_band:
		# Update tracking flag for logging
		match good:
			"wheat":
				wheat_market_buy_blocked = true
			"bread":
				bread_market_buy_blocked = true
		return 0
	
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
				event_bus.emit_log("ERROR: Unknown good '%s' in is_saturated()" % good)
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
				event_bus.emit_log("ERROR: Unknown good '%s' in remaining_capacity()" % good)
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


func _set_result(qty: int, reason: String, item: String, price: float = 0.0) -> void:
	last_trade_result = {
		"qty": qty,
		"reason": reason,
		"item": item,
		"price": price,
		"market_wheat": wheat,
		"market_bread": bread,
	}


func buy_wheat_from_farmer(farmer: Agent, min_acceptable_price: float = 0.0, is_survival: bool = false) -> int:
	"""Micro-fill buying: purchase wheat 1 unit at a time, recomputing bid after each unit.
	Stops when bid drops below min_acceptable_price or inventory/money constraints hit.
	is_survival: If true, allows purchase even above upper_band but doesn't update clearing stats."""
	
	# Wheat selling is NEVER blocked — log override when inventory is high
	var upper_band_check: int = int(float(wheat_target) * (1.0 + TARGET_BAND_PCT))
	if not is_survival and wheat >= upper_band_check:
		if event_bus:
			event_bus.emit_log("[WHEAT SELL OVERRIDE] day=%d inv_high=%d allowing_sell=true" % [current_day, wheat])
	
	var farmer_inv: Inventory = get_inv(farmer)
	var farmer_wallet: Wallet = get_wallet(farmer)
	var farmer_wheat: int = farmer_inv.get_qty("wheat")
	
	if farmer_wheat <= 0:
		_set_result(0, "empty", "wheat", wheat_price)
		return 0
	
	# Check available storage space
	var available_space: int = wheat_capacity - wheat
	if available_space <= 0:
		if event_bus:
			event_bus.emit_log("Tick %d: %s tried to sell %d wheat, but market wheat storage FULL (%d/%d)" % [current_tick, _agent_label(farmer), farmer_wheat, wheat, wheat_capacity])
		_set_result(0, "storage_full", "wheat", wheat_price)
		return 0
	
	# Determine max units to process this trade (performance cap)
	var max_units: int = min(farmer_wheat, available_space, MAX_MICROFILL_UNITS_PER_TRADE)
	
	# Micro-fill loop: buy 1 unit at a time
	var units_bought: int = 0
	var total_paid: float = 0.0
	var initial_bid: float = get_bid_price("wheat")
	var final_bid: float = initial_bid
	var stopped_by_price: bool = false
	var stopped_by_cap: bool = false
	
	for i in range(max_units):
		var current_bid: float = get_bid_price("wheat")
		final_bid = current_bid
		
		if min_acceptable_price > 0.0 and current_bid < min_acceptable_price:
			stopped_by_price = true
			break
		
		if not direct() and money < current_bid:
			break
		
		farmer_inv.remove("wheat", 1)
		wheat += 1
		if not direct():
			farmer_wallet.credit(current_bid)
			money -= current_bid
		total_paid += current_bid
		units_bought += 1
	
	if units_bought == max_units and units_bought < farmer_wheat:
		stopped_by_cap = true
	if direct():
		_shelve("wheat", farmer, units_bought)
	
	wheat_sold_today += units_bought
	totals.wheat_from_farmers += units_bought
	
	var upper_band_wheat: int = int(float(wheat_target) * (1.0 + TARGET_BAND_PCT))
	var should_update_clearing: bool = not is_survival and (wheat - units_bought) < upper_band_wheat
	if units_bought > 0 and should_update_clearing:
		wheat_total_cleared += units_bought
		wheat_total_value += total_paid
	
	var avg_price: float = total_paid / float(max(units_bought, 1))
	var reason: String = "success"
	if units_bought == 0:
		reason = "insufficient_funds"
	elif stopped_by_price:
		reason = "walk_away"
	elif stopped_by_cap:
		reason = "capped"
	elif units_bought < farmer_wheat:
		reason = "partial"
	_set_result(units_bought, reason, "wheat", avg_price)
	
	if event_bus and units_bought > 0:
		event_bus.emit_log("Tick %d: %s wheat sale: offered=%d, cleared=%d, avg=$%.2f, bid=%.2f→%.2f (%s)" % [current_tick, _agent_label(farmer), farmer_wheat, units_bought, avg_price, initial_bid, final_bid, reason])
		var inv_after_sale: int = wheat
		event_bus.emit_log("[WHEAT SALE] day=%d pop=%s offered=%d cleared=%d avg_price=%.2f inv_before=%d inv_after=%d" % [
			current_day, _agent_label(farmer), farmer_wheat, units_bought, avg_price,
			wheat - units_bought, inv_after_sale])
	
	return units_bought


func sell_seeds_to_farmer(farmer: Agent) -> void:
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
			event_bus.emit_log("Tick %d: Market sold %d seeds to %s for $%.2f" % [current_tick, needed, _agent_label(farmer), cost])


func sell_wheat_to_baker(baker: Agent, requested: int) -> int:
	if requested <= 0:
		_set_result(0, "zero_request", "wheat", wheat_price)
		return 0
	
	wheat_requested_today += requested
	
	if wheat == 0:
		_note_short("wheat", baker, requested)
		if event_bus:
			event_bus.emit_log("Tick %d: %s tried to buy %d wheat, but market has 0." % [current_tick, _agent_label(baker), requested])
		_set_result(0, "empty", "wheat", wheat_price)
		return 0
	
	var baker_wallet: Wallet = get_wallet(baker)
	var baker_inv: Inventory = get_inv(baker)
	var max_affordable: int = int(floor(baker_wallet.money / wheat_price))
	
	if max_affordable == 0:
		if event_bus:
			event_bus.emit_log("Tick %d: %s tried to buy wheat, but cannot afford any at $%.2f (money=$%.2f)." % [current_tick, _agent_label(baker), wheat_price, baker_wallet.money])
		_set_result(0, "insufficient_funds", "wheat", wheat_price)
		return 0
	
	var before_market_wheat: int = wheat
	if requested > wheat and baker_wallet.money >= float(requested) * wheat_price:
		_note_short("wheat", baker, requested - wheat)
	var amount_sold: int = min(requested, wheat)
	amount_sold = min(amount_sold, max_affordable)
	
	if amount_sold <= 0:
		_set_result(0, "insufficient_funds", "wheat", wheat_price)
		return 0
	
	var cost: float = amount_sold * wheat_price
	baker_wallet.debit(cost)
	_take_payment("wheat", amount_sold, cost)
	baker_inv.add("wheat", amount_sold)
	wheat -= amount_sold
	totals.wheat_to_bakers += amount_sold
	wheat_bought_by_bakers_today += amount_sold
	
	var reason: String = "success" if amount_sold >= requested else "partial"
	_set_result(amount_sold, reason, "wheat", wheat_price)
	
	if event_bus:
		if amount_sold < requested:
			event_bus.emit_log("Tick %d: %s requested %d wheat; bought %d (market wheat=%d, affordable=%d)." % [current_tick, _agent_label(baker), requested, amount_sold, before_market_wheat, max_affordable])
		else:
			event_bus.emit_log("Tick %d: Market sold %d wheat to %s for $%.2f" % [current_tick, amount_sold, _agent_label(baker), cost])
	
	return amount_sold


func buy_bread_from_baker(baker: Agent, min_acceptable_price: float = 0.0, is_survival: bool = false) -> int:
	"""Micro-fill buying: purchase bread 1 unit at a time, recomputing bid after each unit.
	Stops when bid drops below min_acceptable_price or inventory/money constraints hit.
	is_survival: If true, allows purchase even above upper_band but doesn't update clearing stats."""
	
	if not is_survival and not can_producer_sell("bread"):
		if event_bus:
			event_bus.emit_log("Tick %d: %s bread sale BLOCKED by hysteresis (inventory >= upper_band)" % [current_tick, _agent_label(baker)])
		_set_result(0, "blocked", "bread", bread_price)
		return 0
	
	var baker_inv: Inventory = get_inv(baker)
	var baker_wallet: Wallet = get_wallet(baker)
	var baker_bread: int = baker_inv.get_qty("bread")
	
	if baker_bread <= 0:
		_set_result(0, "empty", "bread", bread_price)
		return 0
	
	var available_space: int = bread_capacity - bread
	if available_space <= 0:
		if event_bus:
			event_bus.emit_log("Tick %d: %s tried to sell %d bread, but market bread storage FULL (%d/%d)" % [current_tick, _agent_label(baker), baker_bread, bread, bread_capacity])
		_set_result(0, "storage_full", "bread", bread_price)
		return 0
	
	var max_units: int = min(baker_bread, available_space, MAX_MICROFILL_UNITS_PER_TRADE)
	var units_bought: int = 0
	var total_paid: float = 0.0
	var initial_bid: float = get_bid_price("bread")
	var final_bid: float = initial_bid
	var stopped_by_price: bool = false
	var stopped_by_cap: bool = false
	
	for i in range(max_units):
		var current_bid: float = get_bid_price("bread")
		final_bid = current_bid
		if min_acceptable_price > 0.0 and current_bid < min_acceptable_price:
			stopped_by_price = true
			break
		if not direct() and money < current_bid:
			break
		baker_inv.remove("bread", 1)
		bread += 1
		if not direct():
			baker_wallet.credit(current_bid)
			money -= current_bid
		total_paid += current_bid
		units_bought += 1
	
	if units_bought == max_units and units_bought < baker_bread:
		stopped_by_cap = true
	if direct():
		_shelve("bread", baker, units_bought)
	
	bread_sold_today += units_bought
	totals.bread_from_bakers += units_bought
	
	var upper_band_bread: int = int(float(bread_target) * (1.0 + TARGET_BAND_PCT))
	var should_update_clearing: bool = not is_survival and (bread - units_bought) < upper_band_bread
	if units_bought > 0 and should_update_clearing:
		bread_total_cleared += units_bought
		bread_total_value += total_paid
	
	var avg_price: float = total_paid / float(max(units_bought, 1))
	var reason: String = "success"
	if units_bought == 0:
		reason = "insufficient_funds"
	elif stopped_by_price:
		reason = "walk_away"
	elif stopped_by_cap:
		reason = "capped"
	elif units_bought < baker_bread:
		reason = "partial"
	_set_result(units_bought, reason, "bread", avg_price)
	
	if event_bus and units_bought > 0:
		var trade_type: String = " (SURVIVAL)" if is_survival else ""
		event_bus.emit_log("Tick %d: %s bread sale: offered=%d, cleared=%d, avg=$%.2f, bid=%.2f→%.2f (%s)%s" % [current_tick, _agent_label(baker), baker_bread, units_bought, avg_price, initial_bid, final_bid, reason, trade_type])
	
	return units_bought


func buy_bread_from_agent(agent, amount_offered: int, min_acceptable_price: float = 0.0, is_survival: bool = false) -> int:
	"""Buy a specific amount of bread from any agent using micro-fill approach.
	Stops when bid drops below min_acceptable_price or inventory/money constraints hit.
	is_survival: If true, allows purchase even above upper_band but doesn't update clearing stats."""

	if not is_survival and agent.is_in_group("bakers") and not can_producer_sell("bread"):
		if event_bus:
			event_bus.emit_log("Tick %d: %s bread sale BLOCKED by hysteresis (inventory >= upper_band)" % [current_tick, _agent_label(agent)])
		_set_result(0, "blocked", "bread", bread_price)
		return 0
	
	if amount_offered <= 0:
		_set_result(0, "empty", "bread", bread_price)
		return 0
	
	var agent_inv: Inventory = get_inv(agent)
	var agent_wallet: Wallet = get_wallet(agent)
	var agent_bread: int = agent_inv.get_qty("bread")
	
	if agent_bread <= 0:
		_set_result(0, "empty", "bread", bread_price)
		return 0
	
	var available_space: int = bread_capacity - bread
	if available_space <= 0:
		if event_bus:
			event_bus.emit_log("Tick %d: %s tried to sell %d bread, but market bread storage FULL (%d/%d)" % [current_tick, _agent_label(agent), amount_offered, bread, bread_capacity])
		_set_result(0, "storage_full", "bread", bread_price)
		return 0
	
	var max_units: int = min(amount_offered, agent_bread, available_space, MAX_MICROFILL_UNITS_PER_TRADE)
	var units_bought: int = 0
	var total_paid: float = 0.0
	var initial_bid: float = get_bid_price("bread")
	var final_bid: float = initial_bid
	var stopped_by_price: bool = false
	var stopped_by_cap: bool = false
	
	for i in range(max_units):
		var current_bid: float = get_bid_price("bread")
		final_bid = current_bid
		if min_acceptable_price > 0.0 and current_bid < min_acceptable_price:
			stopped_by_price = true
			break
		if not direct() and money < current_bid:
			break
		agent_inv.remove("bread", 1)
		bread += 1
		if not direct():
			agent_wallet.credit(current_bid)
			money -= current_bid
		total_paid += current_bid
		units_bought += 1
	
	if units_bought == max_units and units_bought < amount_offered:
		stopped_by_cap = true
	if direct():
		_shelve("bread", agent, units_bought)
	
	bread_sold_today += units_bought
	totals.bread_from_bakers += units_bought
	
	var upper_band_bread: int = int(float(bread_target) * (1.0 + TARGET_BAND_PCT))
	var should_update_clearing: bool = not is_survival and (bread - units_bought) < upper_band_bread
	if units_bought > 0 and should_update_clearing:
		bread_total_cleared += units_bought
		bread_total_value += total_paid
	
	var avg_price: float = total_paid / float(max(units_bought, 1))
	var reason: String = "success"
	if units_bought == 0:
		reason = "insufficient_funds"
	elif stopped_by_price:
		reason = "walk_away"
	elif stopped_by_cap:
		reason = "capped"
	elif units_bought < amount_offered:
		reason = "partial"
	_set_result(units_bought, reason, "bread", avg_price)
	
	if event_bus and units_bought > 0:
		var trade_type: String = " (SURVIVAL)" if is_survival else ""
		event_bus.emit_log("Tick %d: %s bread sale: offered=%d, cleared=%d, avg=$%.2f, bid=%.2f→%.2f (%s)%s" % [current_tick, _agent_label(agent), amount_offered, units_bought, avg_price, initial_bid, final_bid, reason, trade_type])
	
	return units_bought


func sell_bread_to_household(h, requested: int) -> int:
	if requested <= 0:
		_set_result(0, "zero_request", "bread", bread_price)
		return 0
	
	bread_requested_today += requested
	
	if bread <= 0:
		_note_short("bread", h, requested)
		if event_bus:
			event_bus.emit_log("[BREAD EMPTY] day=%d tick=%d buyer=%s wanted=%d inv=0" % [current_day, current_tick, _agent_label(h), requested])
		_set_result(0, "empty", "bread", bread_price)
		return 0
	
	var h_wallet: Wallet = get_wallet(h)
	var max_by_inventory: int = min(requested, bread)
	var shelf_short: int = requested - max_by_inventory
	if shelf_short > 0 and h_wallet.money >= float(requested) * bread_price:
		_note_short("bread", h, shelf_short)
	var max_affordable: int = int(floor(h_wallet.money / bread_price))
	var qty: int = min(max_by_inventory, max_affordable)
	
	if qty <= 0:
		if event_bus:
			event_bus.emit_log("Tick %d: %s cannot afford bread ($%.2f), money=$%.2f" % [current_tick, _agent_label(h), bread_price, h_wallet.money])
		_set_result(0, "insufficient_funds", "bread", bread_price)
		return 0
	
	var cost: float = float(qty) * bread_price
	h_wallet.debit(cost)
	_take_payment("bread", qty, cost)
	bread -= qty
	bread_bought_by_people_today += qty
	totals.bread_to_people += qty
	
	var reason: String = "success" if qty >= requested else "partial"
	_set_result(qty, reason, "bread", bread_price)
	return qty


func sell_bread_to_agent(agent, requested: int) -> int:
	if requested <= 0:
		_set_result(0, "zero_request", "bread", bread_price)
		return 0
	
	bread_requested_today += requested
	
	if agent.is_in_group("bakers"):
		var can_buy_own_output: bool = false
		var food_reserve = agent.get_node_or_null("FoodReserve")
		if food_reserve and food_reserve.is_survival_mode:
			can_buy_own_output = true
		var profit_checker = agent.get_node_or_null("ProductionProfitability")
		if profit_checker and not profit_checker.is_profitable:
			can_buy_own_output = true
		if not can_buy_own_output:
			if event_bus:
				event_bus.emit_log("ERROR Tick %d: Baker attempted to buy bread (BLOCKED)" % current_tick)
			_set_result(0, "blocked", "bread", bread_price)
			return 0
	
	if bread <= 0:
		_note_short("bread", agent, requested)
		if event_bus:
			event_bus.emit_log("Tick %d: %s tried to buy %d bread, but market has 0" % [current_tick, _agent_label(agent), requested])
		_set_result(0, "empty", "bread", bread_price)
		return 0
	
	var agent_wallet: Wallet = get_wallet(agent)
	var max_by_inventory: int = min(requested, bread)
	var shelf_short: int = requested - max_by_inventory
	if shelf_short > 0 and agent_wallet.money >= float(requested) * bread_price:
		_note_short("bread", agent, shelf_short)
	var max_affordable: int = int(floor(agent_wallet.money / bread_price))
	var qty: int = min(max_by_inventory, max_affordable)
	
	if qty <= 0:
		if event_bus:
			event_bus.emit_log("Tick %d: %s cannot afford bread ($%.2f), money=$%.2f" % [current_tick, _agent_label(agent), bread_price, agent_wallet.money])
		_set_result(0, "insufficient_funds", "bread", bread_price)
		return 0
	
	var cost: float = float(qty) * bread_price
	agent_wallet.debit(cost)
	_take_payment("bread", qty, cost)
	bread -= qty
	bread_bought_by_people_today += qty
	totals.bread_to_people += qty
	
	var reason: String = "success" if qty >= requested else "partial"
	_set_result(qty, reason, "bread", bread_price)
	
	if event_bus and qty < requested:
		event_bus.emit_log("Tick %d: %s bought %d/%d bread (limited by availability or money)" % [current_tick, _agent_label(agent), qty, requested])
	
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

func _note_short(good: String, who, n: int) -> void:
	if n <= 0 or who == null:
		return
	var key: int = who.get_instance_id()
	var prev: int = int(_short_by[good].get(key, 0))
	if n <= prev:
		return
	_short_by[good][key] = n
	if good == "bread":
		bread_short_today += n - prev
	else:
		wheat_short_today += n - prev


func _update_bread_target() -> void:
	var wanted: int = bread_bought_by_people_today + bread_short_today
	bread_demand_ema = 0.3 * float(wanted) + 0.7 * bread_demand_ema
	bread_target = maxi(BREAD_TARGET_MIN, roundi(BREAD_DAYS_OF_STOCK * bread_demand_ema))
	if event_bus:
		event_bus.emit_log("[BREAD DEMAND] day=%d bought=%d short=%d avg=%.1f target=%d stock=%d" % [
			current_day, bread_bought_by_people_today, bread_short_today, bread_demand_ema, bread_target, bread])


func _update_wheat_target() -> void:
	var wanted: int = wheat_bought_by_bakers_today + wheat_short_today
	wheat_demand_ema = 0.3 * float(wanted) + 0.7 * wheat_demand_ema
	# Never above what the store can hold with its top band (the store's size stays fixed).
	wheat_target = clampi(roundi(WHEAT_DAYS_OF_STOCK * wheat_demand_ema), WHEAT_TARGET_MIN,
		int(float(wheat_capacity) / (1.0 + TARGET_BAND_PCT)))
	if event_bus:
		event_bus.emit_log("[WHEAT DEMAND] day=%d bought=%d short=%d avg=%.1f target=%d stock=%d" % [
			current_day, wheat_bought_by_bakers_today, wheat_short_today, wheat_demand_ema, wheat_target, wheat])


func on_day_changed(day: int) -> void:
	"""Called by Calendar when a new day starts. Adjusts prices based on inventory vs target."""
	current_day = day
	
	# Apply inventory decay first (before price adjustments)
	_apply_inventory_decay(day)
	
	_update_bread_target()
	_update_wheat_target()
	_adjust_wheat_price(day)
	_adjust_bread_price(day)
	_adjust_firewood_price()
	
	# Store current inventory for next day's recovery detection
	wheat_prev = wheat
	bread_prev = bread
	
	# PART 4: Log market-side hysteresis blocking before reset
	if wheat_market_buy_blocked and event_bus:
		var wheat_upper: int = int(float(wheat_target) * (1.0 + TARGET_BAND_PCT))
		event_bus.emit_log("Day %d: MARKET BUY BLOCKED - wheat (inventory %d >= upper_band %d)" % [day, wheat, wheat_upper])
	if bread_market_buy_blocked and event_bus:
		var bread_upper: int = int(float(bread_target) * (1.0 + TARGET_BAND_PCT))
		event_bus.emit_log("Day %d: MARKET BUY BLOCKED - bread (inventory %d >= upper_band %d)" % [day, bread, bread_upper])
	
	# Daily bread status diagnostic
	if event_bus:
		event_bus.emit_log("[BREAD STATUS] day=%d inv=%d paused_sell=%s paused_prod=%s" % [
			day, bread,
			not can_producer_sell("bread"),
			not can_producer_produce("bread")])

	# Reset daily flow counters
	wheat_sold_today = 0
	wheat_requested_today = 0
	bread_sold_today = 0
	bread_requested_today = 0
	bread_bought_by_people_today = 0
	bread_short_today = 0
	_short_by = {"bread": {}, "wheat": {}}
	wheat_bought_by_bakers_today = 0
	wheat_short_today = 0
	
	# Reset market-side hysteresis tracking
	wheat_market_buy_blocked = false
	bread_market_buy_blocked = false
	
	# Reset clearing price tracking
	wheat_total_cleared = 0
	wheat_total_value = 0.0
	bread_total_cleared = 0
	bread_total_value = 0.0


func _apply_inventory_decay(day: int) -> void:
	"""Apply inventory decay with weekly-held rates, only when inventory > upper_band."""
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
		var _target_inventory: int = 0
		var upper_band: int = 0
		var current_decay_rate: float = 0.0
		var decay_days_remaining: int = 0
		
		match good_name:
			"wheat":
				current_inventory = wheat
				_target_inventory = wheat_target
				upper_band = int(float(wheat_target) * (1.0 + TARGET_BAND_PCT))
				current_decay_rate = wheat_decay_rate
				decay_days_remaining = wheat_decay_days_remaining
			"bread":
				current_inventory = bread
				_target_inventory = bread_target
				upper_band = int(float(bread_target) * (1.0 + TARGET_BAND_PCT))
				current_decay_rate = bread_decay_rate
				decay_days_remaining = bread_decay_days_remaining
			"seeds":
				current_inventory = seeds
				_target_inventory = 0  # Seeds have no target
				upper_band = 0
				current_decay_rate = 0.0
				decay_days_remaining = 0
			_:
				continue  # Unknown good
		
		if current_inventory <= 0:
			continue  # No inventory to decay
		
		# PART 2: Only decay when inventory > upper_band (true oversupply)
		if current_inventory <= upper_band:
			continue  # Skip decay when at or below upper band
		
		# PART 3: Weekly-held decay rate mechanism
		# Decrement window counter and re-roll rate if needed
		if decay_days_remaining <= 0:
			# Roll new decay rate and reset window
			var min_rate: float = config.get("min_rate_per_day", 0.0)
			var max_rate: float = config.get("max_rate_per_day", 0.0)
			current_decay_rate = randf_range(min_rate, max_rate)
			decay_days_remaining = DECAY_WINDOW_DAYS
			
			# PART 4: Log when new decay rate is rolled
			if event_bus:
				event_bus.emit_log("Day %d: %s decay rate set to %.1f%% for next %d days" % [
					day, good_name, current_decay_rate * 100.0, DECAY_WINDOW_DAYS
				])
		
		# Store back to instance variables
		match good_name:
			"wheat":
				wheat_decay_rate = current_decay_rate
				wheat_decay_days_remaining = decay_days_remaining - 1
			"bread":
				bread_decay_rate = current_decay_rate
				bread_decay_days_remaining = decay_days_remaining - 1
		
		# Calculate decay amount using held rate (floor to integer)
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
		
		# PART 4: Log decay application
		if event_bus:
			event_bus.emit_log("Day %d: %s decay removed %d units (rate %.1f%%), inv %d→%d" % [
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
	var upper_band: int = int(float(wheat_target) * (1.0 + TARGET_BAND_PCT))
	var lower_band: int = int(float(wheat_target) * (1.0 - TARGET_BAND_PCT))
	
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
		if wheat > wheat_prev and wheat >= upper_band:
			# Inventory increased and above upper band (oversupply) -> apply downward adjustment
			# Mirror the upward adjustment magnitude used during scarcity
			var recovery_adjustment: float = -min(MAX_INVENTORY_NUDGE_PER_DAY, (inv_ratio - 1.0) * MAX_INVENTORY_NUDGE_PER_DAY)
			inventory_nudge += recovery_adjustment
		
		new_price *= (1.0 + inventory_nudge)
		
		# Step 3: CRITICAL - prevent upward drift beyond clearing reality
		var max_allowed_price: float = avg_clearing_price * (1.0 + MAX_PREMIUM_OVER_CLEARING)
		if new_price > max_allowed_price:
			new_price = max_allowed_price
			cap_applied = true
		update_reason = "cleared"
	elif wheat_total_cleared == 0:
		# PART 2: Distinguish market-blocked from no-demand
		
		if wheat < lower_band and wheat_short_today > 0:
			# Buyers went without and the shelf is low: the price rises (docs/BREAD_MARKET.md). It
			# used to hold here, because nothing was bought from producers to set a clearing price,
			# so an empty shelf left the price where it was while people starved.
			new_price *= (1.0 + PRICE_STEP)
			update_reason = "short: buyers went without"
		elif wheat_market_buy_blocked:
			# Market buying is intentionally blocked due to hysteresis
			# HOLD price steady - no increase, no decrease
			new_price = old_price
			update_reason = "price held (market blocked)"
		elif wheat > upper_band:
			# Market is OPEN but no trades occurred AND inventory is oversupplied
			# This is genuine lack of demand -> decrease price
			new_price *= (1.0 - PRICE_STEP)
			update_reason = "no-demand decrease"
		else:
			# Normal inventory but no demand -> hold price flat
			new_price = old_price
			update_reason = "no-demand cap"
	else:
		# Trades below threshold: allow only neutral or downward movement
		
		if wheat < lower_band and wheat_short_today > 0:
			# Buyers went without and the shelf is low: the price rises (docs/BREAD_MARKET.md). It
			# used to hold here, because nothing was bought from producers to set a clearing price,
			# so an empty shelf left the price where it was while people starved.
			new_price *= (1.0 + PRICE_STEP)
			update_reason = "short: buyers went without"
		elif wheat_market_buy_blocked:
			# Market buying is blocked - hold price steady
			new_price = old_price
			update_reason = "price held (market blocked)"
		elif wheat > upper_band:
			# Market open but low trades with oversupply -> decrease
			new_price *= (1.0 - PRICE_STEP)
			update_reason = "low-trades decrease"
		else:
			# Low trades but normal inventory -> hold
			new_price = old_price
			update_reason = "low-trades cap"
	
	# Change 3: Apply hard daily price movement cap (±5%)
	var max_change: float = old_price * Tuning.f("price_daily_limit", MAX_DAILY_PRICE_CHANGE)
	if new_price > old_price + max_change:
		new_price = old_price + max_change
	elif new_price < old_price - max_change:
		new_price = old_price - max_change
	
	# Apply floor and ceiling
	wheat_price = maxf(new_price, WHEAT_PRICE_FLOOR)
	
	# Calculate band status for logging
	var bid_mult: float = get_bid_price("wheat") / wheat_price if wheat_price > 0 else 1.0
	var max_buy: int = get_max_buy_qty("wheat")
	
	# Daily diagnostic log
	if event_bus:
		if wheat_total_cleared > 0:
			event_bus.emit_log("Day %d: wheat | inv %d [%d-%d-%d] | bid×%.2f | cap %d | trades=%d | $%.2f→$%.2f | %s" % [
				day, wheat, lower_band, wheat_target, upper_band, bid_mult, max_buy,
				wheat_total_cleared, old_price, wheat_price,
				update_reason + (" (CAP)" if cap_applied else "")
			])
		else:
			event_bus.emit_log("Day %d: wheat | inv %d [%d-%d-%d] | bid×%.2f | cap %d | trades=0 | $%.2f→$%.2f | %s" % [
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
	var upper_band: int = int(float(bread_target) * (1.0 + TARGET_BAND_PCT))
	var lower_band: int = int(float(bread_target) * (1.0 - TARGET_BAND_PCT))
	
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
		if bread > bread_prev and bread >= upper_band:
			# Inventory increased and above upper band (oversupply) -> apply downward adjustment
			# Mirror the upward adjustment magnitude used during scarcity
			var recovery_adjustment: float = -min(MAX_INVENTORY_NUDGE_PER_DAY, (inv_ratio - 1.0) * MAX_INVENTORY_NUDGE_PER_DAY)
			inventory_nudge += recovery_adjustment
		
		new_price *= (1.0 + inventory_nudge)
		
		# Step 3: CRITICAL - prevent upward drift beyond clearing reality
		var max_allowed_price: float = avg_clearing_price * (1.0 + MAX_PREMIUM_OVER_CLEARING)
		if new_price > max_allowed_price:
			new_price = max_allowed_price
			cap_applied = true
		update_reason = "cleared"
	elif bread_total_cleared == 0:
		# PART 2: Distinguish market-blocked from no-demand
		
		if bread < lower_band and bread_short_today > 0:
			# Buyers went without and the shelf is low: the price rises (docs/BREAD_MARKET.md). It
			# used to hold here, because nothing was bought from producers to set a clearing price,
			# so an empty shelf left the price where it was while people starved.
			new_price *= (1.0 + PRICE_STEP)
			update_reason = "short: buyers went without"
		elif bread_market_buy_blocked:
			# Market buying is intentionally blocked due to hysteresis
			# HOLD price steady - no increase, no decrease
			new_price = old_price
			update_reason = "price held (market blocked)"
		elif bread > upper_band:
			# Market is OPEN but no trades occurred AND inventory is oversupplied
			# This is genuine lack of demand -> decrease price
			new_price *= (1.0 - PRICE_STEP)
			update_reason = "no-demand decrease"
		else:
			# Normal inventory but no demand -> hold price flat
			new_price = old_price
			update_reason = "no-demand cap"
	else:
		# Trades below threshold: allow only neutral or downward movement
		
		if bread < lower_band and bread_short_today > 0:
			# Buyers went without and the shelf is low: the price rises (docs/BREAD_MARKET.md). It
			# used to hold here, because nothing was bought from producers to set a clearing price,
			# so an empty shelf left the price where it was while people starved.
			new_price *= (1.0 + PRICE_STEP)
			update_reason = "short: buyers went without"
		elif bread_market_buy_blocked:
			# Market buying is blocked - hold price steady
			new_price = old_price
			update_reason = "price held (market blocked)"
		elif bread > upper_band:
			# Market open but low trades with oversupply -> decrease
			new_price *= (1.0 - PRICE_STEP)
			update_reason = "low-trades decrease"
		else:
			# Low trades but normal inventory -> hold
			new_price = old_price
			update_reason = "low-trades cap"
	
	# Change 3: Apply hard daily price movement cap (±5%)
	var max_change: float = old_price * Tuning.f("price_daily_limit", MAX_DAILY_PRICE_CHANGE)
	if new_price > old_price + max_change:
		new_price = old_price + max_change
	elif new_price < old_price - max_change:
		new_price = old_price - max_change
	
	# Apply floor and ceiling
	bread_price = maxf(new_price, BREAD_PRICE_FLOOR)
	
	# Calculate band status for logging
	var bid_mult: float = get_bid_price("bread") / bread_price if bread_price > 0 else 1.0
	var max_buy: int = get_max_buy_qty("bread")
	
	# Daily diagnostic log
	if event_bus:
		if bread_total_cleared > 0:
			event_bus.emit_log("Day %d: bread | inv %d [%d-%d-%d] | bid×%.2f | cap %d | trades=%d | $%.2f→$%.2f | %s" % [
				day, bread, lower_band, bread_target, upper_band, bid_mult, max_buy,
				bread_total_cleared, old_price, bread_price,
				update_reason + (" (CAP)" if cap_applied else "")
			])
		else:
			event_bus.emit_log("Day %d: bread | inv %d [%d-%d-%d] | bid×%.2f | cap %d | trades=0 | $%.2f→$%.2f | %s" % [
				day, bread, lower_band, bread_target, upper_band, bid_mult, max_buy,
				old_price, bread_price, update_reason
			])


# ─── Firewood (batch 3) ───────────────────────────────────────────────────────

## What the market pays a woodworker today: the price, less when the pile is over its target
## band and a little more when it is under (the same banding wheat and bread use).
func firewood_bid() -> float:
	var t: float = float(maxi(1, firewood_target))
	var bid: float = firewood_price
	if float(firewood) > t * (1.0 + TARGET_BAND_PCT):
		bid *= BAND_UPPER_BID_MULTIPLIER
	elif float(firewood) < t * (1.0 - TARGET_BAND_PCT):
		bid *= BAND_LOWER_BID_MULTIPLIER
	return maxf(FIREWOOD_PRICE_FLOOR, bid)


## A woodworker sells firewood to the market. Coins move from the market's purse to the
## seller's; nothing is sold below `min_acceptable_price`. Returns the amount bought.
func buy_firewood_from_agent(agent, amount_offered: int, min_acceptable_price: float = 0.0) -> int:
	if agent == null or amount_offered <= 0:
		return 0
	var bid: float = firewood_bid()
	if bid < min_acceptable_price:
		return 0
	var a_inv = get_inv(agent)
	var a_wallet = get_wallet(agent)
	if a_inv == null or a_wallet == null:
		return 0
	var qty: int = mini(amount_offered, a_inv.get_qty("firewood"))
	qty = mini(qty, firewood_capacity - firewood)
	if not direct():
		qty = mini(qty, int(floor(money / bid)))
	if qty <= 0:
		return 0
	var pay: float = float(qty) * bid
	a_inv.items["firewood"] = a_inv.get_qty("firewood") - qty
	firewood += qty
	if direct():
		_shelve("firewood", agent, qty)
	else:
		a_wallet.credit(pay)
		money -= pay
	firewood_bought_today += qty
	totals.firewood_in += qty
	return qty


## Anyone buys firewood at today's price. Coins move from the buyer to the market's purse.
## Returns the amount sold; the caller puts it in the buyer's inventory.
func sell_firewood_to_agent(agent, requested: int) -> int:
	if agent == null or requested <= 0:
		return 0
	var a_wallet = get_wallet(agent)
	if a_wallet == null:
		return 0
	firewood_requested_today += requested
	# Demand is what buyers can pay for: a request with no coins behind it moves no price.
	var can_pay: int = mini(requested, int(floor(a_wallet.money / firewood_price)))
	firewood_wanted_today += can_pay
	var qty: int = mini(can_pay, firewood)
	if qty < can_pay:
		firewood_short_today += can_pay - qty   # the pile ran short (not: the buyer was poor)
	if qty <= 0:
		return 0
	var cost: float = float(qty) * firewood_price
	a_wallet.debit(cost)
	_take_payment("firewood", qty, cost)
	firewood -= qty
	firewood_sold_today += qty
	totals.firewood_out += qty
	return qty


## Daily: firewood gets dearer when the pile is low or ran short, cheaper when it is piling
## up, by at most MAX_DAILY_PRICE_CHANGE. The target pile follows about two days of sales.
func _adjust_firewood_price() -> void:
	var t: float = float(maxi(1, firewood_target))
	# With no ceiling the price has to follow buyers: it rises only on a day somebody with coins
	# asked for firewood. In a dead town with an empty pile it used to climb 12% a day for ever
	# (27 billion a log by day 1,500).
	if firewood_wanted_today > 0 and (float(firewood) < t * (1.0 - TARGET_BAND_PCT) or firewood_short_today > 0):
		# An empty pile bids up fast (12% a day); it crept 5% a day while hearths went cold.
		firewood_price *= 1.0 + (0.12 if firewood <= 0 else Tuning.f("price_daily_limit", MAX_DAILY_PRICE_CHANGE) * clampf(1.0 - float(firewood) / t, 0.2, 1.0))
	elif float(firewood) > t * (1.0 + TARGET_BAND_PCT):
		firewood_price *= 1.0 - Tuning.f("price_daily_limit", MAX_DAILY_PRICE_CHANGE) * clampf(float(firewood) / t - 1.0, 0.2, 1.0)
	firewood_price = maxf(firewood_price, FIREWOOD_PRICE_FLOOR)
	firewood_sold_ema = 0.3 * float(firewood_sold_today) + 0.7 * firewood_sold_ema
	firewood_target = maxi(30, roundi(2.0 * firewood_sold_ema))
	firewood_capacity = maxi(80, firewood_target * 2)
	firewood_sold_today = 0
	firewood_bought_today = 0
	firewood_requested_today = 0
	firewood_short_today = 0
	firewood_wanted_today = 0
