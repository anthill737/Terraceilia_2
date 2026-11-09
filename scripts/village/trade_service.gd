class_name VillageTradeService
extends Node

## Phase 6 trade service extracted from village.gd.
## Holds per-village trade flow counters and provides read-only market snapshots.
## Village keeps one instance as a child node and delegates all trade-related calls.

var _village: Node = null
var _market = null  # Market

## Cumulative trade flow counters — reset each day via reset_trade_flow_counters().
var wheat_exported: int = 0
var wheat_imported: int = 0
var bread_exported: int = 0
var bread_imported: int = 0


## Bind village context. Call after market is created and added to the scene.
func setup(village: Node, p_market: Node) -> void:
	_village = village
	_market = p_market


## Returns a lightweight snapshot of this village's market for trade evaluation.
## FarmerJob / BakerJob call this on every village to compute
##   expected_profit = sell_price - local_price - travel_cost
## and decide whether to travel here.
func get_trade_snapshot() -> Dictionary:
	if _market == null or not is_instance_valid(_market):
		return {}
	return {
		"village_ref":       _village,
		"village_id":        _village.village_id,
		"village_name":      _village.village_name,
		"wheat_price":       _market.get_bid_price("wheat"),
		"bread_price":       _market.get_bid_price("bread"),
		"wheat_qty":         _market.wheat,
		"bread_qty":         _market.bread,
		"world_pos":         _village.global_position,
		"wheat_target":      _market.wheat_target,
		"bread_target":      _market.bread_target,
		"wheat_buy_blocked": _market.wheat_market_buy_blocked,
		"bread_buy_blocked": _market.bread_market_buy_blocked,
	}


## Records goods exported by an agent belonging to the parent village (sold abroad).
## Called by the agent's job script after completing a trade sale at a remote village.
func record_trade_export(good: String, qty: int) -> void:
	match good:
		"wheat": wheat_exported += qty
		"bread": bread_exported += qty


## Records goods imported into the parent village (sold here by a visiting foreign agent).
## Called by the agent's job script after completing a trade sale at this village.
func record_trade_import(good: String, qty: int) -> void:
	match good:
		"wheat": wheat_imported += qty
		"bread": bread_imported += qty


## Returns a summary of cumulative trade flow for the parent village.
## Positive net means more imported than exported (net receiver).
func get_trade_flow_summary() -> Dictionary:
	var vname: String = _village.village_name if is_instance_valid(_village) else "?"
	return {
		"village":        vname,
		"wheat_exported": wheat_exported,
		"wheat_imported": wheat_imported,
		"bread_exported": bread_exported,
		"bread_imported": bread_imported,
		"net_wheat":      wheat_imported - wheat_exported,
		"net_bread":      bread_imported - bread_exported,
	}


## Resets all trade flow counters to zero. Call at the start of each day.
func reset_trade_flow_counters() -> void:
	wheat_exported = 0
	wheat_imported = 0
	bread_exported = 0
	bread_imported = 0
