extends Node
class_name ProsperityMeter

## ProsperityMeter - Measures economic health to drive population growth
## Computes a normalized prosperity score (0.0-1.0) from weighted sub-scores:
## - Wealth health (money across agents)
## - Food security (bread inventory, reserve compliance)
## - Starvation pressure (starvation events, hunger ratios)
## - Market activity (trade volume/value)
## All weights and thresholds are config-driven.

# Configuration - Weights (must sum to 1.0 for proper normalization)
const WEALTH_WEIGHT: float = 0.25
const FOOD_WEIGHT: float = 0.30
const STARVATION_WEIGHT: float = 0.25  # Applied negatively
const TRADE_WEIGHT: float = 0.20

# Wealth configuration
const WEALTH_PER_CAPITA: bool = true  # If true, divide by household count
const WEALTH_TARGET: float = 100.0  # Normalization target (per capita if enabled)

# Food security configuration
const FOOD_BREAD_TARGET_WEIGHT: float = 0.6  # How much bread inventory matters
const FOOD_RESERVE_COMPLIANCE_WEIGHT: float = 0.4  # How much reserve compliance matters
const RESERVE_TARGET_THRESHOLD: float = 0.8  # Agent meets reserve if >= 80% of target

# Starvation configuration
const STARVATION_WINDOW_DAYS: int = 7  # Track events in last N days
const HUNGER_SAFE_RATIO: float = 0.5  # Below 50% hunger = safe

# Trade activity configuration
const TRADE_WINDOW_DAYS: int = 7  # Track trade activity over N days
const TRADE_VALUE_TARGET: float = 100.0  # Normalization target for daily trade value

# Growth trigger configuration
const PROSPERITY_THRESHOLD_TO_GROW: float = 0.70  # Spawn when above this
const PROSPERITY_THRESHOLD_TO_PAUSE: float = 0.60  # Hysteresis to prevent oscillation
const GROWTH_COOLDOWN_DAYS: int = 1  # Cooldown after spawn (0 = none, 1 = recommended)

# Smoothing configuration
const SMOOTHING_STRENGTH: float = 0.3  # EMA smoothing (0 = no smoothing, 1 = full smoothing)

# State
var prosperity_score: float = 0.5  # Current smoothed prosperity (0-1)
var prosperity_raw: float = 0.5  # Unsmoothed prosperity this day
var prosperity_inputs: Dictionary = {}  # Breakdown of sub-scores for logging
var last_spawn_day: int = -999  # Track last spawn for cooldown
var starvation_events: Array = []  # Ring buffer of starvation days
var trade_values: Array = []  # Ring buffer of daily trade values

# References
var event_bus = null
var market = null
var households: Array = []  # All active households


func bind_references(bus, mkt, household_list: Array) -> void:
	"""Wire to event bus, market, and household tracking array."""
	event_bus = bus
	market = mkt
	households = household_list


func update_prosperity(day: int) -> void:
	"""Compute prosperity score from current economic conditions. Call once per day."""
	if market == null or households.size() == 0:
		return
	
	# Track current starvation events
	_track_starvation_events(day)
	
	# Track daily trade value from market
	_track_trade_value(day)
	
	# Compute sub-scores (all normalized 0-1)
	var wealth_score: float = _compute_wealth_health()
	var food_score: float = _compute_food_security()
	var starvation_score: float = _compute_starvation_pressure()  # Higher = less pressure
	var trade_score: float = _compute_trade_activity()
	
	# Weighted blend
	prosperity_raw = (
		wealth_score * WEALTH_WEIGHT +
		food_score * FOOD_WEIGHT +
		starvation_score * STARVATION_WEIGHT +
		trade_score * TRADE_WEIGHT
	)
	prosperity_raw = clamp(prosperity_raw, 0.0, 1.0)
	
	# Apply smoothing (EMA)
	if SMOOTHING_STRENGTH > 0.0:
		prosperity_score = lerp(prosperity_score, prosperity_raw, 1.0 - SMOOTHING_STRENGTH)
	else:
		prosperity_score = prosperity_raw
	
	# Store breakdown for logging
	prosperity_inputs = {
		"wealth": wealth_score,
		"food": food_score,
		"starvation": starvation_score,
		"trade": trade_score,
		"raw": prosperity_raw,
		"smoothed": prosperity_score
	}
	
	# Log prosperity summary
	if event_bus:
		event_bus.log("Day %d: Prosperity=%.2f (wealth=%.2f food=%.2f hunger=%.2f starvation=%.2f trade=%.2f)" % [
			day, prosperity_score, wealth_score, food_score, starvation_score, starvation_score, trade_score
		])


func should_spawn_household(day: int) -> bool:
	"""Check if prosperity conditions allow household spawning."""
	# Check cooldown
	if GROWTH_COOLDOWN_DAYS > 0:
		if day - last_spawn_day < GROWTH_COOLDOWN_DAYS:
			return false
	
	# Check prosperity threshold with hysteresis
	if prosperity_score >= PROSPERITY_THRESHOLD_TO_GROW:
		return true
	
	return false


func record_spawn(day: int) -> void:
	"""Record that a household was spawned (for cooldown tracking)."""
	last_spawn_day = day


func record_starvation_event(day: int) -> void:
	"""Track starvation event for prosperity calculation."""
	starvation_events.append(day)
	# Trim to window
	while starvation_events.size() > 0 and starvation_events[0] < day - STARVATION_WINDOW_DAYS:
		starvation_events.pop_front()


func record_trade_value(day: int, value: float) -> void:
	"""Track daily trade value for prosperity calculation."""
	trade_values.append(value)
	# Trim to window
	if trade_values.size() > TRADE_WINDOW_DAYS:
		trade_values.pop_front()


## Private helper functions for sub-score computation

func _compute_wealth_health() -> float:
	"""Compute normalized wealth health score (0-1)."""
	if households.size() == 0:
		return 0.0
	
	var total_wealth: float = 0.0
	for household in households:
		if household == null:
			continue
		var wallet = household.get_node_or_null("Wallet")
		if wallet:
			total_wealth += wallet.money
	
	# Normalize
	var target = WEALTH_TARGET
	if WEALTH_PER_CAPITA and households.size() > 0:
		target = WEALTH_TARGET  # Already per-capita target
		total_wealth = total_wealth / float(households.size())
	else:
		target = WEALTH_TARGET * float(households.size())
	
	var score = total_wealth / target if target > 0 else 0.0
	return clamp(score, 0.0, 1.0)


func _compute_food_security() -> float:
	"""Compute normalized food security score (0-1)."""
	var bread_score: float = 0.0
	var reserve_score: float = 0.0
	
	# A) Market bread inventory vs target
	if market and market.bread_target > 0:
		var inventory_ratio = float(market.bread) / float(market.bread_target)
		bread_score = clamp(inventory_ratio, 0.0, 1.0)
	
	# B) Fraction of households meeting food reserve targets
	if households.size() > 0:
		var compliant_count: int = 0
		for household in households:
			if household == null:
				continue
			var food_reserve = household.get_node_or_null("FoodReserve")
			if food_reserve:
				var status = food_reserve.get_reserve_status()
				var current = status["current"]
				var minimum = status["minimum"]
				if minimum > 0 and float(current) >= float(minimum) * RESERVE_TARGET_THRESHOLD:
					compliant_count += 1
		reserve_score = float(compliant_count) / float(households.size())
	
	# Weighted blend
	var food_score = (
		bread_score * FOOD_BREAD_TARGET_WEIGHT +
		reserve_score * FOOD_RESERVE_COMPLIANCE_WEIGHT
	)
	return clamp(food_score, 0.0, 1.0)


func _compute_starvation_pressure() -> float:
	"""Compute starvation pressure score (0-1, higher = less pressure = better)."""
	var starvation_score: float = 1.0
	var hunger_score: float = 1.0
	
	# A) Starvation events in window (fewer = better)
	# If we have starvation events, score drops
	var events_in_window = starvation_events.size()
	if events_in_window > 0:
		# Assume 1 event = 50% penalty, 2+ events = 0
		starvation_score = max(0.0, 1.0 - float(events_in_window) * 0.5)
	
	# B) Average hunger ratio across agents (lower hunger = better)
	if households.size() > 0:
		var total_hunger_ratio: float = 0.0
		var agent_count: int = 0
		for household in households:
			if household == null:
				continue
			var hunger = household.get_node_or_null("HungerNeed")
			if hunger and hunger.hunger_max_days > 0:
				var hunger_ratio = float(hunger.hunger_days) / float(hunger.hunger_max_days)
				total_hunger_ratio += hunger_ratio
				agent_count += 1
		
		if agent_count > 0:
			var avg_hunger = total_hunger_ratio / float(agent_count)
			# Lower hunger = higher score
			# If avg_hunger < HUNGER_SAFE_RATIO (0.5), full score
			# If avg_hunger >= 1.0, zero score
			if avg_hunger <= HUNGER_SAFE_RATIO:
				hunger_score = 1.0
			else:
				hunger_score = 1.0 - ((avg_hunger - HUNGER_SAFE_RATIO) / (1.0 - HUNGER_SAFE_RATIO))
				hunger_score = max(0.0, hunger_score)
	
	# Blend starvation and hunger scores
	return (starvation_score + hunger_score) * 0.5


func _compute_trade_activity() -> float:
	"""Compute trade activity score (0-1) based on recent trade volume."""
	if trade_values.size() == 0:
		return 0.5  # Neutral if no data yet
	
	# Average daily trade value
	var total_value: float = 0.0
	for value in trade_values:
		total_value += value
	var avg_daily_value = total_value / float(trade_values.size())
	
	# Normalize against target
	var score = avg_daily_value / TRADE_VALUE_TARGET if TRADE_VALUE_TARGET > 0 else 0.0
	return clamp(score, 0.0, 1.0)


func _track_starvation_events(day: int) -> void:
	"""Check all households for starvation and record events."""
	for household in households:
		if household == null:
			continue
		var hunger = household.get_node_or_null("HungerNeed")
		if hunger and hunger.is_starving:
			# Record starvation event if not already recorded today
			if starvation_events.size() == 0 or starvation_events[starvation_events.size() - 1] != day:
				starvation_events.append(day)
	
	# Trim to window
	while starvation_events.size() > 0 and starvation_events[0] < day - STARVATION_WINDOW_DAYS:
		starvation_events.pop_front()


func _track_trade_value(day: int) -> void:
	"""Record today's total trade value from market."""
	if market == null:
		return
	
	# Sum wheat and bread trade values
	var daily_value = market.wheat_total_value + market.bread_total_value
	trade_values.append(daily_value)
	
	# Trim to window
	if trade_values.size() > TRADE_WINDOW_DAYS:
		trade_values.pop_front()
