extends Node
class_name MarketShocks

## Bounded real-market shock mechanics
## - Seasonal yield variation (±5-10% for wheat)
## - Random demand shock days (households eat +1 occasionally)
## - Seed supply availability shocks

# Configuration
const SEASONAL_ENABLED: bool = true
const SEASONAL_MIN_MULTIPLIER: float = 0.90  # 90% minimum yield
const SEASONAL_MAX_MULTIPLIER: float = 1.10  # 110% maximum yield
const SEASON_PERIOD_DAYS: int = 90  # Full cycle over 90 days

const DEMAND_SHOCK_ENABLED: bool = true
const DEMAND_SHOCK_DAY_PROBABILITY: float = 0.08  # 8% chance per day
const DEMAND_SHOCK_EXTRA_FOOD: int = 1  # +1 bread per affected consumer
const DEMAND_SHOCK_AFFECTED_SHARE: float = 0.30  # 30% of consumers affected

const SEED_SHOCK_ENABLED: bool = true
const SEED_SHOCK_PROBABILITY: float = 0.05  # 5% chance per day to start
const SEED_SHOCK_DURATION_MIN: int = 3  # Minimum 3 days
const SEED_SHOCK_DURATION_MAX: int = 7  # Maximum 7 days
const SEED_SHOCK_CAP_MULTIPLIER: float = 0.5  # Reduce seed availability to 50%

# State tracking
var current_day: int = 0
var wheat_yield_multiplier: float = 1.0
var is_demand_shock_active: bool = false
var is_seed_shock_active: bool = false
var seed_shock_days_remaining: int = 0
var event_bus: EventBus = null

# RNG seed for reproducibility
var rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	# Seed RNG for reproducible results
	rng.seed = hash("market_shocks_2025")


func set_event_bus(bus: EventBus) -> void:
	event_bus = bus


func set_day(day: int) -> void:
	current_day = day
	
	# Update seasonal yield multiplier
	if SEASONAL_ENABLED:
		_update_seasonal_yield()
	
	# Check for new demand shock
	if DEMAND_SHOCK_ENABLED:
		_check_demand_shock()
	
	# Update seed shock state
	if SEED_SHOCK_ENABLED:
		_update_seed_shock()


func _update_seasonal_yield() -> void:
	"""Calculate seasonal yield multiplier based on day of year.
	Uses sinusoidal pattern for smooth seasonal variation."""
	var old_multiplier: float = wheat_yield_multiplier
	
	# Calculate position in season cycle (0 to 1)
	var cycle_position: float = float(current_day % SEASON_PERIOD_DAYS) / float(SEASON_PERIOD_DAYS)
	
	# Use sine wave for smooth seasonal variation
	# Peak at 0.25 cycle (day ~23), trough at 0.75 cycle (day ~68)
	var sine_value: float = sin(cycle_position * TAU)  # TAU = 2*PI
	
	# Map sine (-1 to 1) to multiplier range (min to max)
	wheat_yield_multiplier = lerp(
		(SEASONAL_MIN_MULTIPLIER + SEASONAL_MAX_MULTIPLIER) / 2.0,
		SEASONAL_MAX_MULTIPLIER,
		sine_value
	)
	
	# Clamp to configured bounds
	wheat_yield_multiplier = clamp(wheat_yield_multiplier, SEASONAL_MIN_MULTIPLIER, SEASONAL_MAX_MULTIPLIER)
	
	# Log on significant changes (>2% difference)
	if event_bus and abs(wheat_yield_multiplier - old_multiplier) > 0.02:
		event_bus.log("Day %d: Seasonal yield multiplier = %.2f (cycle pos %.1f%%)" % [
			current_day, wheat_yield_multiplier, cycle_position * 100.0
		])


func _check_demand_shock() -> void:
	"""Roll for demand shock activation each day."""
	var roll: float = rng.randf()
	var was_active: bool = is_demand_shock_active
	is_demand_shock_active = roll < DEMAND_SHOCK_DAY_PROBABILITY
	
	# Log only on state change
	if is_demand_shock_active and not was_active and event_bus:
		event_bus.log("Day %d: DEMAND SHOCK - +%d food for %.0f%% of consumers" % [
			current_day, DEMAND_SHOCK_EXTRA_FOOD, DEMAND_SHOCK_AFFECTED_SHARE * 100.0
		])


func _update_seed_shock() -> void:
	"""Manage seed supply shock state."""
	if is_seed_shock_active:
		# Decrement duration
		seed_shock_days_remaining -= 1
		if seed_shock_days_remaining <= 0:
			is_seed_shock_active = false
			if event_bus:
				event_bus.log("Day %d: SEED SHOCK ENDED - supply restored" % current_day)
	else:
		# Roll for new shock
		var roll: float = rng.randf()
		if roll < SEED_SHOCK_PROBABILITY:
			is_seed_shock_active = true
			seed_shock_days_remaining = rng.randi_range(SEED_SHOCK_DURATION_MIN, SEED_SHOCK_DURATION_MAX)
			if event_bus:
				event_bus.log("Day %d: SEED SHOCK STARTED - supply reduced to %.0f%% for %d days" % [
					current_day, SEED_SHOCK_CAP_MULTIPLIER * 100.0, seed_shock_days_remaining
				])


func get_wheat_yield_multiplier() -> float:
	"""Get current seasonal yield multiplier for wheat production."""
	return wheat_yield_multiplier if SEASONAL_ENABLED else 1.0


func should_apply_demand_shock() -> bool:
	"""Check if demand shock is active today."""
	return is_demand_shock_active and DEMAND_SHOCK_ENABLED


func get_demand_shock_extra_food() -> int:
	"""Get extra food units needed per affected consumer during demand shock."""
	return DEMAND_SHOCK_EXTRA_FOOD if is_demand_shock_active else 0


func get_demand_shock_affected_share() -> float:
	"""Get fraction of consumers affected by demand shock."""
	return DEMAND_SHOCK_AFFECTED_SHARE if is_demand_shock_active else 0.0


func get_seed_availability_multiplier() -> float:
	"""Get seed availability multiplier (1.0 = normal, <1.0 = reduced)."""
	if is_seed_shock_active and SEED_SHOCK_ENABLED:
		return SEED_SHOCK_CAP_MULTIPLIER
	return 1.0
