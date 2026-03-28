class_name Village
extends Node2D

# ── Village identity ───────────────────────────────────────────────────────────
var village_id: int = 0
var village_name: String = "Village"

# ── RNG (per-village, seeded via initialize()) ────────────────────────────────
var rng: RandomNumberGenerator = null

# ── Core references ───────────────────────────────────────────────────────────
var market: Market = null
var farmer: Agent = null
var baker: Agent = null
var household_agent: Agent = null

# ── Managers ──────────────────────────────────────────────────────────────────
var pop_mgr = null       # PopulationManager
var field_mgr = null     # FieldManager
var econ_stats = null    # EconomyStatsManager

# ── Convenience arrays (populated by managers) ────────────────────────────────
var all_farmers: Array = []
var all_bakers: Array = []
var households: Array = []
var all_fields: Array = []
var all_field_nodes: Array = []

# ── Economy state ─────────────────────────────────────────────────────────────
var economy_config: Dictionary = {}
var event_bus: EventBus = null

# ── Logging ───────────────────────────────────────────────────────────────────
var log_prefix: String = "[Village]"

# ── Configuration ─────────────────────────────────────────────────────────────
var _seed: int = 0
var _config: Dictionary = {}


# ── Public API ────────────────────────────────────────────────────────────────

func initialize(seed: int, config: Dictionary) -> void:
	pass


func tick(delta: float) -> void:
	pass


func get_market() -> Market:
	return null


func get_population_summary() -> Dictionary:
	return {}


func get_econ_snapshot() -> Dictionary:
	return {}
