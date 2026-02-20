extends CharacterBody2D
class_name Agent

## Base class for all pop agents (Farmer, Baker, Household).
## Owns identity, input handling, and role management via JobBase components.
## Delegates cashflow, skills, and visuals to component nodes.

signal pop_clicked(pop: Node)
signal agent_died(agent: Node)

# -- Identity (persistent across role changes) ---------------------------------
var person_id: int = 0
var person_name: String = ""
var life_events: Array[String] = []
var _person_day: int = 0

# -- Role management -----------------------------------------------------------
var current_role: String = ""
var current_job: JobBase = null

# -- Phase 2 component refs (created in _ready) --------------------------------
var cashflow: CashflowTracker = null
var skills: SkillSet = null
var visuals: VisualIndicator = null

# -- Cashflow forwarding (backward compat -> CashflowTracker) ------------------
var cashflow_today_income: float:
	get:
		return cashflow.today_income if cashflow else 0.0
	set(v):
		if cashflow:
			cashflow.today_income = v

var cashflow_today_expense: float:
	get:
		return cashflow.today_expense if cashflow else 0.0
	set(v):
		if cashflow:
			cashflow.today_expense = v

var cashflow_7d: Array[float]:
	get:
		if cashflow:
			return cashflow.history_7d
		return []
	set(v):
		if cashflow:
			cashflow.history_7d = v

# -- Skills forwarding (backward compat -> SkillSet) ---------------------------
var skill_farmer: float:
	get:
		return skills.farmer if skills else 0.25
	set(v):
		if skills:
			skills.farmer = v

var skill_baker: float:
	get:
		return skills.baker if skills else 0.25
	set(v):
		if skills:
			skills.baker = v

var days_in_role: int:
	get:
		return skills.days_in_role if skills else 0
	set(v):
		if skills:
			skills.days_in_role = v

# -- Wealth thresholds (visual-only) ------------------------------------------
const WEALTH_POOR_THRESHOLD: float = 1000.0
const WEALTH_WEALTHY_THRESHOLD: float = 4000.0

# -- Visual overlay config (set before super() in subclass to override) --------
var _health_bar_y: float = -22.0

# -- Travel / idle watchdog ----------------------------------------------------
var travel_ticks: int = 0
const MAX_TRAVEL_TICKS: int = 300
var idle_ticks: int = 0
const MAX_IDLE_TICKS: int = 10

# -- Shared component refs (resolved via scene tree) ---------------------------
@onready var wallet: Wallet = $Wallet
@onready var inv: Inventory = $Inventory
@onready var hunger: HungerNeed = $HungerNeed
@onready var food_stockpile: FoodStockpile = $FoodStockpile
@onready var route: RouteRunner = $RouteRunner
@onready var cap: InventoryCapacity = $InventoryCapacity
@onready var food_reserve: FoodReserve = $FoodReserve

# -- Sprite ref (null-safe: only Agent.tscn has AgentSprite; old scenes don't)
var sprite: ColorRect = null

# -- External references -------------------------------------------------------
var market: Market = null
var event_bus: EventBus = null
var current_tick: int = 0
var pending_target: Node2D = null


# ==============================================================================
#  Lifecycle
# ==============================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	sprite = get_node_or_null("AgentSprite") as ColorRect

	cashflow = CashflowTracker.new()
	cashflow.name = "CashflowTracker"
	add_child(cashflow)

	skills = SkillSet.new()
	skills.name = "SkillSet"
	add_child(skills)

	visuals = VisualIndicator.new()
	visuals.name = "VisualIndicator"
	add_child(visuals)
	visuals.setup(self, hunger, wallet, _health_bar_y)


# ==============================================================================
#  Role management
# ==============================================================================

const ROLE_COLORS: Dictionary = {
	"Farmer":    Color(0.2, 1, 0.2, 1),
	"Baker":     Color(0.8, 0.6, 0.2, 1),
	"Household": Color(1, 0.4, 1, 1),
}

const ROLE_GROUPS: Dictionary = {
	"Farmer":    "farmers",
	"Baker":     "bakers",
	"Household": "households",
}


func set_role(role: String) -> void:
	if current_job != null:
		current_job.deactivate()
		current_job.queue_free()
		current_job = null

	if current_role != "" and ROLE_GROUPS.has(current_role):
		remove_from_group(ROLE_GROUPS[current_role])

	current_role = role

	if ROLE_GROUPS.has(role):
		add_to_group(ROLE_GROUPS[role])

	if sprite and ROLE_COLORS.has(role):
		sprite.color = ROLE_COLORS[role]

	if role == "Household":
		_health_bar_y = -24.0

	match role:
		"Farmer":
			current_job = FarmerJob.new()
		"Baker":
			current_job = BakerJob.new()
		"Household":
			current_job = HouseholdJob.new()

	if current_job:
		current_job.name = role + "Job"
		add_child(current_job)
		current_job.setup(self)
		current_job.activate()

	if skills:
		skills.days_in_role = 0


# ==============================================================================
#  Tick + physics delegation
# ==============================================================================

func set_tick(t: int) -> void:
	current_tick = t
	if current_job:
		current_job.set_tick(t)


func _physics_process(delta: float) -> void:
	if current_job:
		current_job.physics_tick(delta)


func on_day_changed(day: int) -> void:
	_person_day = day
	_roll_cashflow()
	_progress_skills(current_role)
	if current_job:
		current_job.on_day_changed(day)


# ==============================================================================
#  Identity & logging
# ==============================================================================

func log_event(msg: String) -> void:
	life_events.append("Day %d: %s" % [_person_day, msg])
	if life_events.size() > 5000:
		life_events.pop_front()


# ==============================================================================
#  Cashflow forwarding methods (delegate to CashflowTracker)
# ==============================================================================

func cashflow_rolling_7d_sum() -> float:
	return cashflow.rolling_7d_sum() if cashflow else 0.0


func cashflow_rolling_7d_avg() -> float:
	return cashflow.rolling_7d_avg() if cashflow else 0.0


func _roll_cashflow() -> void:
	if cashflow:
		cashflow.roll_daily()


# ==============================================================================
#  Skills forwarding methods (delegate to SkillSet)
# ==============================================================================

func _progress_skills(role_name: String) -> void:
	if skills:
		skills.progress(role_name)


# ==============================================================================
#  Wallet / wealth
# ==============================================================================

func get_cash() -> float:
	return wallet.money if wallet else 0.0


func get_wealth_tier() -> String:
	var cash: float = get_cash()
	if cash >= WEALTH_WEALTHY_THRESHOLD:
		return "Wealthy"
	if cash >= WEALTH_POOR_THRESHOLD:
		return "Working"
	return "Poor"


# ==============================================================================
#  Display name / status (delegate to job)
# ==============================================================================

func get_display_name() -> String:
	if current_job:
		return current_job.get_display_name()
	return "Agent"


func get_status_text() -> String:
	if current_job:
		return current_job.get_status_text()
	return "idle"


# ==============================================================================
#  Click / selection
# ==============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			if get_local_mouse_position().length() <= 15.0:
				pop_clicked.emit(self)
				get_viewport().set_input_as_handled()


# ==============================================================================
#  Forwarding properties — expose job-specific data to external systems
# ==============================================================================

var consecutive_days_negative_cashflow: int:
	get:
		if current_job and current_job.get("consecutive_days_negative_cashflow") != null:
			return int(current_job.consecutive_days_negative_cashflow)
		return 0
	set(v):
		if current_job:
			current_job.set("consecutive_days_negative_cashflow", v)

var switch_cooldown_days: int:
	get:
		if current_job and current_job.get("switch_cooldown_days") != null:
			return int(current_job.switch_cooldown_days)
		return 0
	set(v):
		if current_job:
			current_job.set("switch_cooldown_days", v)

var training_days_remaining: int:
	get:
		if current_job and current_job.get("training_days_remaining") != null:
			return int(current_job.training_days_remaining)
		return 0
	set(v):
		if current_job:
			current_job.set("training_days_remaining", v)

var days_in_survival_mode: int:
	get:
		if current_job and current_job.get("days_in_survival_mode") != null:
			return int(current_job.days_in_survival_mode)
		return 0
	set(v):
		if current_job:
			current_job.set("days_in_survival_mode", v)

var consecutive_failed_food_days: int:
	get:
		if current_job and current_job.get("consecutive_failed_food_days") != null:
			return int(current_job.consecutive_failed_food_days)
		return 0
	set(v):
		if current_job:
			current_job.set("consecutive_failed_food_days", v)


# ==============================================================================
#  Forwarding methods — allow main.gd to call role-specific APIs generically
# ==============================================================================

func set_route_nodes(house: Node2D, market_pos: Node2D) -> void:
	if current_job and current_job is FarmerJob:
		(current_job as FarmerJob).set_route_nodes(house, market_pos)


func set_fields(field_plots: Array, nodes: Array) -> void:
	if current_job and current_job is FarmerJob:
		(current_job as FarmerJob).set_fields(field_plots, nodes)


func add_field(field_node: Node2D, field_plot) -> void:
	if current_job and current_job is FarmerJob:
		(current_job as FarmerJob).add_field(field_node, field_plot as FieldPlot)


func remove_field(field_node: Node2D) -> void:
	if current_job and current_job is FarmerJob:
		(current_job as FarmerJob).remove_field(field_node)


func set_locations(loc1: Node2D, loc2: Node2D) -> void:
	if current_job and current_job is BakerJob:
		(current_job as BakerJob).set_locations(loc1, loc2)
	elif current_job and current_job is HouseholdJob:
		(current_job as HouseholdJob).set_locations(loc1, loc2)


# ==============================================================================
#  Inspector (shared keys -- job adds role-specific keys)
# ==============================================================================

func _base_inspector_data() -> Dictionary:
	return {
		"name": name,
		"person_name": person_name if person_name != "" else name,
		"cash": get_cash(),
		"wealth_tier": get_wealth_tier(),
		"hunger": "%d/%d" % [hunger.hunger_days, hunger.hunger_max_days] if hunger else "?/?",
		"starving": hunger.is_starving if hunger else false,
		"bread": inv.get_qty("bread") if inv else 0,
		"survival": food_reserve.is_survival_mode if food_reserve else false,
		"cashflow_income": cashflow_today_income,
		"cashflow_expense": cashflow_today_expense,
		"cashflow_7d_sum": cashflow_rolling_7d_sum(),
		"cashflow_7d_avg": cashflow_rolling_7d_avg(),
		"cashflow_7d_len": cashflow_7d.size(),
		"skill_farmer": skill_farmer,
		"skill_baker": skill_baker,
		"days_in_role": days_in_role,
	}


func get_inspector_data() -> Dictionary:
	var d: Dictionary = _base_inspector_data()
	if current_job:
		d.merge(current_job.get_job_inspector_data())
	return d
