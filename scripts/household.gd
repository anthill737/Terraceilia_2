extends Node
class_name Household

var money: float = 5000.0
var bread_consumed: int = 0
var event_bus: EventBus = null
var current_tick: int = 0


func set_tick(t: int) -> void:
	current_tick = t


func request_bread(market: Market, amount: int) -> void:
	var purchased: int = market.sell_bread_to_household(self, amount)
	bread_consumed += purchased
	
	if event_bus != null:
		if purchased > 0:
			var cost: float = purchased * market.BREAD_PRICE
			event_bus.log("Tick %d: Household bought %d bread for $%.2f" % [current_tick, purchased, cost])
		else:
			event_bus.log("Tick %d: Household wanted %d bread, bought 0 (market bread=%d, money=$%.2f)" % [current_tick, amount, market.bread, money])
