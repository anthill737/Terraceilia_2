extends RefCounted
class_name Shocks
## Troubles that hit a village now and then, so the economy has something to answer to:
##   blight     harvests drop to 40% for 6 days
##   oven_fire  the bakery's oven bakes 30% for 4 days while it is rebuilt
##   frost      every hearth burns twice the firewood for 5 days
##   rats       the market store loses 60% of its wheat and bread at once
##
## Nothing here fixes the damage. Recovery is the economy's own work: stock runs down, the
## price climbs (a little each day), producers earn more and take on hands, the merchant
## carries goods in from the other village, and when the trouble ends the price settles back.
## scenes/TestShocks.tscn sets these off on purpose and checks exactly that.
##
## One trouble at a time per village, none in the first GRACE_DAYS, at least MIN_GAP_DAYS
## between them, then DAILY_CHANCE each day. A test or a quiet game turns them off with
## `enabled = false` or the World meta "no_shocks".

const GRACE_DAYS: int = 20
const MIN_GAP_DAYS: int = 18
const DAILY_CHANCE: float = 0.06
const KINDS: Dictionary = {
	"blight": {"days": 6, "text": "Blight in the fields: harvests are down"},
	"oven_fire": {"days": 4, "text": "Fire at the bakery: the oven is being rebuilt"},
	"frost": {"days": 5, "text": "Hard frost: every hearth burns twice the wood"},
	"rats": {"days": 1, "text": "Rats in the market store: wheat and bread were lost"},
}

var village = null
var market = null
var event_bus = null
var rng := RandomNumberGenerator.new()
var enabled: bool = true
var active: Dictionary = {}      # {"kind", "days_left", "text", "start"} or empty
var last_end_day: int = -999
var history: Array = []          # [{"kind", "start", "end"}]


func _log(msg: String) -> void:
	print(msg)
	if event_bus:
		event_bus.emit_log(msg)


func _off_by_world() -> bool:
	var w = village.get_parent() if village != null else null
	return w != null and w.get_meta("no_shocks", false)


## Once a day, first thing.
func on_day(day: int) -> void:
	if market == null:
		return
	if not active.is_empty():
		active.days_left = int(active.days_left) - 1
		if int(active.days_left) <= 0:
			end(day)
		return
	if not enabled or not Tuning.on("troubles", true) or _off_by_world() or day < GRACE_DAYS or day - last_end_day < MIN_GAP_DAYS:
		return
	if rng.randf() < DAILY_CHANCE:
		var kinds: Array = KINDS.keys()
		start(str(kinds[rng.randi() % kinds.size()]), day)


## Set a trouble off (tests call this directly).
func start(kind: String, day: int) -> void:
	if not KINDS.has(kind) or market == null:
		return
	if not active.is_empty():
		end(day)
	active = {"kind": kind, "days_left": int(KINDS[kind].days), "text": str(KINDS[kind].text), "start": day}
	var extra: String = ""
	match kind:
		"blight":
			market.shock_harvest_mult = 0.4
		"oven_fire":
			market.shock_oven_mult = 0.3
		"frost":
			market.shock_extra_burn = 1
		"rats":
			var lost_w: int = int(float(market.wheat) * 0.6)
			var lost_b: int = int(float(market.bread) * 0.6)
			market.wheat -= lost_w
			market.bread -= lost_b
			extra = " (%d wheat and %d bread gone)" % [lost_w, lost_b]
	history.append({"kind": kind, "start": day, "end": -1})
	_log("[SHOCK] day=%d %s: %s%s" % [day, village.village_name if village else "?", active.text, extra])


func end(day: int) -> void:
	if active.is_empty():
		return
	market.shock_harvest_mult = 1.0
	market.shock_oven_mult = 1.0
	market.shock_extra_burn = 0
	if not history.is_empty():
		history[history.size() - 1].end = day
	_log("[SHOCK] day=%d %s: over (%s)" % [day, village.village_name if village else "?", str(active.kind)])
	active = {}
	last_end_day = day


## One line for the HUD; empty when all is well.
func describe() -> String:
	if active.is_empty():
		return ""
	var d: int = int(active.days_left)
	return "%s (%d more day%s)" % [str(active.text), d, "" if d == 1 else "s"]
