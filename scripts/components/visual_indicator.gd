extends Node
class_name VisualIndicator

## Renders a health bar and wealth-tier border on the parent agent.
## Reads from HungerNeed + Wallet components -- no economy side-effects.

var _parent_node: Node2D = null
var _hunger_ref: HungerNeed = null
var _wallet_ref: Wallet = null

var _health_bar_fg: ColorRect = null
var _wealth_indicator: ColorRect = null

const WEALTH_POOR_THRESHOLD: float = 1000.0
const WEALTH_WEALTHY_THRESHOLD: float = 4000.0


func setup(parent_node: Node2D, hunger: HungerNeed, wallet: Wallet, bar_y: float = -22.0) -> void:
	_parent_node = parent_node
	_hunger_ref = hunger
	_wallet_ref = wallet
	_create_health_bar(bar_y)
	_create_wealth_indicator()


func _process(_delta: float) -> void:
	_update_visuals()


func _create_health_bar(bar_y: float) -> void:
	if _parent_node == null:
		return
	var bg: ColorRect = ColorRect.new()
	bg.name = "HealthBarBG"
	bg.position = Vector2(-10.0, bar_y)
	bg.size = Vector2(20.0, 4.0)
	bg.color = Color(0.18, 0.05, 0.05, 0.85)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_parent_node.add_child(bg)

	_health_bar_fg = ColorRect.new()
	_health_bar_fg.name = "HealthBar"
	_health_bar_fg.position = Vector2(-10.0, bar_y)
	_health_bar_fg.size = Vector2(20.0, 4.0)
	_health_bar_fg.color = Color(0.85, 0.12, 0.12, 1.0)
	_health_bar_fg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_parent_node.add_child(_health_bar_fg)


func _create_wealth_indicator() -> void:
	if _parent_node == null:
		return
	_wealth_indicator = ColorRect.new()
	_wealth_indicator.name = "WealthIndicator"
	_wealth_indicator.position = Vector2(-15.0, -15.0)
	_wealth_indicator.size = Vector2(30.0, 30.0)
	_wealth_indicator.color = Color(0.45, 0.45, 0.45, 0.88)
	_wealth_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_parent_node.add_child(_wealth_indicator)
	_parent_node.move_child(_wealth_indicator, 0)


func _get_wealth_tier() -> String:
	var cash: float = _wallet_ref.money if _wallet_ref else 0.0
	if cash >= WEALTH_WEALTHY_THRESHOLD:
		return "Wealthy"
	if cash >= WEALTH_POOR_THRESHOLD:
		return "Working"
	return "Poor"


func _update_visuals() -> void:
	if _health_bar_fg == null or _hunger_ref == null or _hunger_ref.hunger_max_days <= 0:
		return
	var ratio: float = clamp(float(_hunger_ref.hunger_days) / float(_hunger_ref.hunger_max_days), 0.0, 1.0)
	_health_bar_fg.size.x = 20.0 * ratio
	if ratio > 0.25:
		_health_bar_fg.color = Color(0.85, 0.12, 0.12, 1.0)
	else:
		_health_bar_fg.color = Color(0.50, 0.06, 0.06, 1.0)
	if _wealth_indicator != null:
		match _get_wealth_tier():
			"Poor":    _wealth_indicator.color = Color(0.45, 0.45, 0.45, 0.88)
			"Working": _wealth_indicator.color = Color(0.90, 0.72, 0.04, 0.88)
			"Wealthy": _wealth_indicator.color = Color(0.08, 0.80, 0.08, 0.88)
