extends Node
class_name InventoryThrottle

## Gradual production throttling based on market inventory pressure.
## Prevents binary on/off production behavior that causes price floor collapses.
## Smoothly reduces production as market inventory approaches target levels.

# Configuration
var soft_throttle_threshold: float = 0.7  # Start throttling at 70% of target inventory
var min_throttle: float = 0.2  # Never throttle below 20% production
var enabled: bool = true

# Current state
var production_throttle: float = 1.0  # 0.0 = stopped, 1.0 = full speed
var last_throttle_band: int = 10  # For band-change logging (0-10 scale)

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


## Calculate production throttle factor based on market inventory pressure.
## Uses target bands for hysteresis to avoid rapid toggling.
## Returns value between min_throttle and 1.0.
## Recipe format: { "output_good": String, ... }
func calculate_throttle(recipe: Dictionary) -> float:
	if not enabled or market == null:
		return 1.0
	
	if not recipe.has("output_good"):
		return 1.0
	
	var output_good: String = recipe["output_good"]
	
	# Get market inventory levels
	var market_inventory: int = 0
	var target_inventory: int = 0
	
	if output_good == "bread":
		market_inventory = market.bread
		target_inventory = market.bread_target
	elif output_good == "wheat":
		market_inventory = market.wheat
		target_inventory = market.wheat_target
	else:
		# Unknown good - no throttle
		return 1.0
	
	if target_inventory <= 0:
		return 1.0
	
	# Calculate target bands (use market's TARGET_BAND_PCT)
	var band_pct: float = 0.15  # Match market's TARGET_BAND_PCT
	var lower_band: float = float(target_inventory) * (1.0 - band_pct)
	var upper_band: float = float(target_inventory) * (1.0 + band_pct)
	var inv_float: float = float(market_inventory)
	
	# Apply throttle using bands (hysteresis)
	var throttle: float = 1.0
	
	if inv_float >= upper_band:
		# Above upper band: throttle strongly (market saturated)
		var excess_ratio: float = (inv_float - upper_band) / float(target_inventory)
		excess_ratio = min(excess_ratio, 0.5)  # Cap at 50% above upper band
		# Lerp from soft_throttle_threshold at upper_band to min_throttle at max excess
		throttle = lerp(soft_throttle_threshold, min_throttle, excess_ratio / 0.5)
	elif inv_float <= lower_band:
		# Below lower band: full production (market undersupplied)
		throttle = 1.0
	else:
		# Within bands: moderate throttling based on position
		var band_position: float = (inv_float - lower_band) / (upper_band - lower_band)
		# Lerp from 1.0 at lower_band to soft_throttle_threshold at upper_band
		throttle = lerp(1.0, soft_throttle_threshold, band_position)
	
	throttle = clamp(throttle, min_throttle, 1.0)
	
	# Update state and log band changes
	var current_band: int = int(throttle * 10.0)  # 0-10 scale
	if current_band != last_throttle_band:
		if event_bus:
			var throttle_percent: int = int(throttle * 100.0)
			var last_percent: int = int((float(last_throttle_band) / 10.0) * 100.0)
			var inv_percent: float = (inv_float / float(target_inventory)) * 100.0 if target_inventory > 0 else 0.0
			event_bus.log("Tick %d: %s throttling production: %d%% → %d%% (inventory: %.1f%%)" % [
				current_tick, agent_name, last_percent, throttle_percent, inv_percent
			])
		last_throttle_band = current_band
	
	production_throttle = throttle
	return throttle


## Get current throttle factor (for diagnostics/UI).
func get_throttle() -> float:
	return production_throttle


## Apply throttle to a batch size (for production).
## Returns throttled batch size, always >= 1 if input > 0.
func apply_to_batch(batch_size: int) -> int:
	if batch_size <= 0:
		return 0
	var throttled: float = float(batch_size) * production_throttle
	# Always produce at least 1 unit if throttle active
	return max(1, int(round(throttled)))


## Apply throttle to sell quantity.
## Returns throttled amount, can be 0 if heavily throttled.
func apply_to_sell(amount: int) -> int:
	if amount <= 0:
		return 0
	var throttled: float = float(amount) * production_throttle
	return max(0, int(round(throttled)))
