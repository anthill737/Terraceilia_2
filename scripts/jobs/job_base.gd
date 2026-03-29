extends Node
class_name JobBase

## Base class for role-specific job components.
## Each job holds convenience refs to the parent Agent's shared components
## and implements role-specific tick, physics, day-change, and inspector logic.

var agent: Agent = null

# Convenience refs (populated in setup() to avoid agent.xxx everywhere)
var wallet: Wallet = null
var inv: Inventory = null
var hunger: HungerNeed = null
var food_stockpile: FoodStockpile = null
var route: RouteRunner = null
var cap: InventoryCapacity = null
var food_reserve: FoodReserve = null
var market: Market = null
var event_bus: EventBus = null

## Emitted when the agent commits to an outbound cross-village trip.
## Fires at departure — current_village_ref is still the ORIGIN village.
signal trade_departed(from_village: Node, to_village: Node)
## Emitted ONLY when the agent physically arrives at a FOREIGN village.
## This is the canonical migration-complete signal.
## Fires after current_village_ref, market, and all context refs are updated.
signal trade_arrived(village: Node)
## Emitted when the agent departs a foreign village to return home.
signal trade_return_departed(from_village: Node, to_village: Node)
## Emitted when the agent arrives back at their home village after a trade trip.
signal trade_return_arrived(village: Node)


func setup(a: Agent) -> void:
	agent = a
	wallet = a.wallet
	inv = a.inv
	hunger = a.hunger
	food_stockpile = a.food_stockpile
	route = a.route
	cap = a.cap
	food_reserve = a.food_reserve
	market = a.market
	event_bus = a.event_bus


func activate() -> void:
	pass


func deactivate() -> void:
	pass


func set_tick(_t: int) -> void:
	pass


func physics_tick(_delta: float) -> void:
	pass


func on_day_changed(_day: int) -> void:
	pass


func get_job_inspector_data() -> Dictionary:
	return {}


func get_display_name() -> String:
	return "Unknown"


func get_status_text() -> String:
	return "idle"
