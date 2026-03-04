extends Node
class_name TradeManager

## External trade counterparty: imports scarce goods at a markup over local price,
## exports surplus goods at a discount.  NO world price anchors — all prices are
## derived from the town's current market reference price.

# ─── Config (set via load_config) ────────────────────────────────────────────
var enabled: bool = true
var check_interval: int = 1

var import_threshold: Dictionary = {"wheat": 5, "bread": 5}
var export_threshold: Dictionary = {"wheat": 60, "bread": 70}
var import_lot: Dictionary = {"wheat": 20, "bread": 10}
var export_lot: Dictionary = {"wheat": 20, "bread": 20}
var import_cap: Dictionary = {"wheat": 40, "bread": 20}
var export_cap: Dictionary = {"wheat": 40, "bread": 40}
var import_markup: Dictionary = {"wheat": 0.35, "bread": 0.35}
var export_discount: Dictionary = {"wheat": 0.20, "bread": 0.20}
var fee_flat: float = 0.0
var fee_pct: float = 0.0
var use_rng: bool = true
var daily_probability: float = 0.80
var rng_seed_val: int = 12345

# ─── Treasury config ──────────────────────────────────────────────────────
var treasury_cash_start_cfg: float = 0.0
var treasury_income_pct: float = 0.0
var treasury_debug_logs: bool = true

# ─── Dependencies ────────────────────────────────────────────────────────────
var market: Market = null
var event_bus: EventBus = null

# ─── Daily caps remaining (reset each trade day) ────────────────────────────
var _import_rem: Dictionary = {"wheat": 0, "bread": 0}
var _export_rem: Dictionary = {"wheat": 0, "bread": 0}

# ─── Daily totals (for [TRADE STATUS] log) ───────────────────────────────────
var _imports_today: Dictionary = {"wheat": 0, "bread": 0}
var _exports_today: Dictionary = {"wheat": 0, "bread": 0}

# ─── Seeded RNG ──────────────────────────────────────────────────────────────
var _rng: RandomNumberGenerator = null

# ─── Tracked goods ───────────────────────────────────────────────────────────
const GOODS: Array[String] = ["wheat", "bread"]


func load_config(cfg: Dictionary) -> void:
	var t: Dictionary = cfg.get("trade", {})
	enabled = bool(t.get("trade_enabled", true))
	check_interval = int(t.get("trade_check_interval_days", 1))
	import_threshold = _dict_int(t.get("import_trigger_inv_threshold", import_threshold))
	export_threshold = _dict_int(t.get("export_trigger_inv_threshold", export_threshold))
	import_lot = _dict_int(t.get("import_lot_size", import_lot))
	export_lot = _dict_int(t.get("export_lot_size", export_lot))
	import_cap = _dict_int(t.get("daily_import_cap", import_cap))
	export_cap = _dict_int(t.get("daily_export_cap", export_cap))
	import_markup = _dict_float(t.get("import_markup_pct", import_markup))
	export_discount = _dict_float(t.get("export_discount_pct", export_discount))
	fee_flat = float(t.get("trade_fee_flat", 0.0))
	fee_pct = float(t.get("trade_fee_pct", 0.0))
	use_rng = bool(t.get("trade_use_rng", true))
	daily_probability = float(t.get("trade_daily_probability", 0.80))
	rng_seed_val = int(t.get("trade_rng_seed", 12345))

	treasury_cash_start_cfg = float(t.get("treasury_cash_start", 0.0))
	treasury_income_pct = float(t.get("treasury_income_pct", 0.0))
	treasury_debug_logs = bool(t.get("treasury_debug_logs", true))

	if market:
		market.treasury_cash_start = treasury_cash_start_cfg
		market.treasury_cash = treasury_cash_start_cfg

	_init_rng()


func _init_rng() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = rng_seed_val


func _dict_int(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in d:
		out[k] = int(d[k])
	return out


func _dict_float(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in d:
		out[k] = float(d[k])
	return out


func on_day_changed(day: int) -> void:
	if not enabled or market == null:
		return

	var treasury_before: float = market.treasury_cash

	if check_interval <= 1 or day % check_interval == 0:
		# Reset daily caps and totals
		for g in GOODS:
			_import_rem[g] = import_cap.get(g, 0)
			_export_rem[g] = export_cap.get(g, 0)
			_imports_today[g] = 0
			_exports_today[g] = 0

		for g in GOODS:
			_process_good(day, g)

		_emit_status(day)

	if treasury_debug_logs:
		var delta: float = market.treasury_cash - treasury_before
		var msg := "[MARKET TREASURY] day=%d cash=%.2f net=%.2f" % [day, market.treasury_cash, delta]
		print(msg)
		if event_bus:
			event_bus.log(msg)


func _process_good(day: int, good: String) -> void:
	# RNG gate
	if use_rng:
		var roll: float = _rng.randf()
		if roll > daily_probability:
			var skip_msg := "[TRADE SKIP] day=%d reason=rng good=%s (roll=%.3f > %.2f)" % [
				day, good, roll, daily_probability]
			print(skip_msg)
			if event_bus:
				event_bus.log(skip_msg)
			return

	var inv: int = _get_inv(good)
	var threshold_import: int = import_threshold.get(good, 5)
	var threshold_export: int = export_threshold.get(good, 60)

	# Import check
	if inv <= threshold_import:
		_do_import(day, good, inv)

	# Re-read inventory after possible import
	inv = _get_inv(good)

	# Export check
	if inv >= threshold_export:
		_do_export(day, good, inv)


func _do_import(day: int, good: String, inv_before: int) -> void:
	var cap_rem: int = _import_rem.get(good, 0)
	var lot: int = import_lot.get(good, 20)
	var qty: int = mini(lot, cap_rem)
	if qty <= 0:
		return

	var local_price: float = _get_local_price(good)
	var markup: float = import_markup.get(good, 0.35)
	var price: float = local_price * (1.0 + markup) + fee_flat
	var import_cost: float = price * float(qty)

	if market.treasury_cash < import_cost:
		var msg := "[TRADE IMPORT BLOCKED] day=%d good=%s qty=%d cost=%.2f treasury=%.2f local=%.2f reason=insufficient_treasury" % [
			day, good, qty, import_cost, market.treasury_cash, local_price]
		print(msg)
		if event_bus:
			event_bus.log(msg)
		return

	_add_inv(good, qty)
	_import_rem[good] = cap_rem - qty
	_imports_today[good] += qty

	market.treasury_cash -= import_cost

	_recompute_hysteresis(good)

	var inv_after: int = _get_inv(good)
	var msg := "[TRADE IMPORT] day=%d good=%s qty=%d price=%.2f cost=%.2f treasury_after=%.2f local=%.2f inv_before=%d inv_after=%d" % [
		day, good, qty, price, import_cost, market.treasury_cash, local_price, inv_before, inv_after]
	print(msg)
	if event_bus:
		event_bus.log(msg)


func _do_export(day: int, good: String, inv_before: int) -> void:
	var cap_rem: int = _export_rem.get(good, 0)
	var lot: int = export_lot.get(good, 20)
	var threshold: int = export_threshold.get(good, 60)
	var exportable: int = inv_before - threshold
	var qty: int = mini(lot, mini(cap_rem, exportable))
	if qty <= 0:
		return

	var local_price: float = _get_local_price(good)
	var disc: float = export_discount.get(good, 0.20)
	var price: float = maxf(0.0, local_price * (1.0 - disc) - fee_flat)
	var export_revenue: float = price * float(qty)

	_remove_inv(good, qty)
	_export_rem[good] = cap_rem - qty
	_exports_today[good] += qty

	market.treasury_cash += export_revenue

	_recompute_hysteresis(good)

	var inv_after: int = _get_inv(good)
	var msg := "[TRADE EXPORT] day=%d good=%s qty=%d price=%.2f revenue=%.2f treasury_after=%.2f local=%.2f inv_before=%d inv_after=%d" % [
		day, good, qty, price, export_revenue, market.treasury_cash, local_price, inv_before, inv_after]
	print(msg)
	if event_bus:
		event_bus.log(msg)


func _emit_status(day: int) -> void:
	var msg := "[TRADE STATUS] day=%d treasury=%.2f imports(wheat=%d bread=%d) exports(wheat=%d bread=%d)" % [
		day,
		market.treasury_cash,
		_imports_today["wheat"], _imports_today["bread"],
		_exports_today["wheat"], _exports_today["bread"]]
	print(msg)
	if event_bus:
		event_bus.log(msg)


# ─── Market inventory helpers ────────────────────────────────────────────────

func _get_inv(good: String) -> int:
	match good:
		"wheat": return market.wheat
		"bread": return market.bread
		_: return 0


func _add_inv(good: String, qty: int) -> void:
	match good:
		"wheat": market.wheat += qty
		"bread": market.bread += qty


func _remove_inv(good: String, qty: int) -> void:
	match good:
		"wheat": market.wheat = maxi(0, market.wheat - qty)
		"bread": market.bread = maxi(0, market.bread - qty)


func _get_local_price(good: String) -> float:
	match good:
		"wheat": return market.wheat_price
		"bread": return market.bread_price
		_: return 1.0


func _recompute_hysteresis(good: String) -> void:
	match good:
		"wheat":
			market._update_producer_hysteresis("wheat", market.wheat, market.wheat_target)
		"bread":
			market._update_producer_hysteresis("bread", market.bread, market.bread_target)
