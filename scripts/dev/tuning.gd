class_name Tuning
extends RefCounted
## Dev mode settings (docs/DEV_MODE.md).
##
## One table of the numbers and switches the town runs on (INPUTS) and of the town a game
## starts with (START). Nothing here changes the game until a value is set: every place in
## the code asks Tuning for its number and hands over the built-in one to fall back on.
##
## Values come from a scenario file (--scenario=name after "--"), from single settings
## (--set key=value), or from the in-game dev menu (F1), which restarts the town with them.

## "d" is the built-in value (TestDevMode checks each one against the code).
const INPUTS: Array = [
	{"k": "day_seconds", "g": "Time", "t": "Length of a day at normal speed (seconds)", "d": 26.67, "lo": 5.0, "hi": 600.0, "st": 0.5},

	{"k": "baker_loaves_per_day", "g": "Production", "t": "Loaves one baker bakes a day, working alone", "d": 12, "lo": 1, "hi": 200, "st": 1},
	{"k": "woodworker_logs_per_day", "g": "Production", "t": "Logs one woodworker cuts a day, working alone", "d": 12, "lo": 1, "hi": 200, "st": 1},
	{"k": "farmer_harvest_percent", "g": "Production", "t": "Wheat from each harvest (percent of normal)", "d": 100.0, "lo": 5.0, "hi": 500.0, "st": 5.0},
	{"k": "hand_output_1", "g": "Production", "t": "Output with one hired hand (1.5 = half again)", "d": 1.5, "lo": 1.0, "hi": 10.0, "st": 0.05},
	{"k": "hand_output_2", "g": "Production", "t": "Output with two hired hands", "d": 1.75, "lo": 1.0, "hi": 10.0, "st": 0.05},
	{"k": "max_hands_per_shop", "g": "Production", "t": "Most hired hands in one shop", "d": 2, "lo": 0, "hi": 10, "st": 1},

	{"k": "household_start_coins", "g": "Money", "t": "Coins a newcomer arrives with", "d": 60.0, "lo": 0.0, "hi": 100000.0, "st": 5.0},
	{"k": "owner_start_coins", "g": "Money", "t": "Coins a new shop owner is set up with", "d": 150.0, "lo": 0.0, "hi": 100000.0, "st": 5.0},
	{"k": "merchant_start_coins", "g": "Money", "t": "Coins the merchant is set up with", "d": 150.0, "lo": 0.0, "hi": 100000.0, "st": 5.0},
	{"k": "market_start_coins", "g": "Money", "t": "Coins in a new market's purse", "d": 3000.0, "lo": 0.0, "hi": 1000000.0, "st": 100.0},
	{"k": "wage_markup", "g": "Money", "t": "A day's wage = (a loaf + a log) times this", "d": 1.25, "lo": 0.1, "hi": 20.0, "st": 0.05},
	{"k": "shop_savings_needed", "g": "Money", "t": "Coins saved before someone may open a shop", "d": 100.0, "lo": 0.0, "hi": 100000.0, "st": 5.0},
	{"k": "shop_opening_fee", "g": "Money", "t": "Fee paid to the market to open a shop", "d": 50.0, "lo": 0.0, "hi": 100000.0, "st": 5.0},
	{"k": "upkeep_farmer", "g": "Money", "t": "Farm upkeep a day (coins)", "d": 0.2, "lo": 0.0, "hi": 1000.0, "st": 0.1},
	{"k": "upkeep_baker", "g": "Money", "t": "Bakery upkeep a day (coins)", "d": 0.3, "lo": 0.0, "hi": 1000.0, "st": 0.1},
	{"k": "upkeep_woodworker", "g": "Money", "t": "Lumber yard upkeep a day (coins)", "d": 0.2, "lo": 0.0, "hi": 1000.0, "st": 0.1},

	{"k": "price_daily_limit", "g": "Prices", "t": "Most a price may move in one day (0.05 = 5%)", "d": 0.05, "lo": 0.01, "hi": 1.0, "st": 0.01},

	{"k": "arrival_prosperity_bar", "g": "Newcomers", "t": "Prosperity needed for a newcomer (0 to 1)", "d": 0.7, "lo": 0.0, "hi": 1.0, "st": 0.05},
	{"k": "arrival_wait_days", "g": "Newcomers", "t": "Fewest days between two newcomers", "d": 3, "lo": 0, "hi": 365, "st": 1},
	{"k": "arrival_max_idle", "g": "Newcomers", "t": "Newcomers come only if this many or fewer lack work", "d": 1, "lo": 0, "hi": 999, "st": 1},
	{"k": "arrival_needs_free_house", "g": "Newcomers", "t": "A newcomer needs an empty house", "d": true},
	{"k": "town_size_limit", "g": "Newcomers", "t": "Most people in one town", "d": 50, "lo": 1, "hi": 500, "st": 1},

	{"k": "house_logs", "g": "Houses", "t": "Logs it takes to build a house", "d": 20, "lo": 1, "hi": 500, "st": 1},
	{"k": "house_build_days", "g": "Houses", "t": "Days of work to build a house", "d": 5, "lo": 1, "hi": 365, "st": 1},
	{"k": "houses_spare_at_start", "g": "Houses", "t": "Empty houses when the town starts", "d": 2, "lo": 0, "hi": 100, "st": 1},

	{"k": "gardens", "g": "Switches", "t": "Garden plots feed people without work", "d": true},
	{"k": "servants", "g": "Switches", "t": "Well-off owners keep servants", "d": true},
	{"k": "home_improvements", "g": "Switches", "t": "Owners improve their homes", "d": true},
	{"k": "merchants", "g": "Switches", "t": "Each town has a travelling merchant", "d": true},
	{"k": "troubles", "g": "Switches", "t": "Blight, fire, frost and rats can strike", "d": true},
]

## The town a game starts with. Left alone, the game starts the way it always has: one farmer,
## one baker, one woodworker, one more person and the merchant.
const START: Array = [
	{"k": "people", "t": "People in the town (0 = use the four counts)", "d": 0, "lo": 0, "hi": 500, "st": 1},
	{"k": "farmers", "t": "Farmers", "d": 1, "lo": 0, "hi": 9, "st": 1},
	{"k": "bakers", "t": "Bakers", "d": 1, "lo": 0, "hi": 100, "st": 1},
	{"k": "woodworkers", "t": "Woodworkers", "d": 1, "lo": 0, "hi": 100, "st": 1},
	{"k": "others", "t": "People with no shop (merchant is extra)", "d": 1, "lo": 0, "hi": 500, "st": 1},
	{"k": "coins_others", "t": "Coins each person with no shop holds", "d": 60.0, "lo": 0.0, "hi": 100000.0, "st": 5.0},
	{"k": "coins_owners", "t": "Coins each shop owner holds", "d": 150.0, "lo": 0.0, "hi": 100000.0, "st": 5.0},
	{"k": "market_coins", "t": "Coins in the market's purse", "d": 3000.0, "lo": 0.0, "hi": 1000000.0, "st": 100.0},
	{"k": "market_wheat", "t": "Wheat on the market shelf", "d": 40, "lo": 0, "hi": 10000, "st": 5},
	{"k": "market_bread", "t": "Loaves on the market shelf", "d": 20, "lo": 0, "hi": 10000, "st": 5},
	{"k": "market_firewood", "t": "Logs in the market's woodpile", "d": 30, "lo": 0, "hi": 10000, "st": 5},
	{"k": "bread_price", "t": "Price of a loaf", "d": 3.2, "lo": 0.01, "hi": 100000.0, "st": 0.1},
	{"k": "wheat_price", "t": "Price of wheat", "d": 1.0, "lo": 0.01, "hi": 100000.0, "st": 0.1},
	{"k": "firewood_price", "t": "Price of a log", "d": 1.5, "lo": 0.01, "hi": 100000.0, "st": 0.1},
	{"k": "prosperity", "t": "Prosperity index (0 to 1)", "d": 0.5, "lo": 0.0, "hi": 1.0, "st": 0.05},
]

## Inputs that were set (key -> value). Empty means the game runs on its built-in numbers.
static var values: Dictionary = {}
## Starting town for every village, and for one village only (village id -> fields).
static var start: Dictionary = {}
static var start_by_village: Dictionary = {}
## Problems found while loading (unknown keys, unreadable files). Shown in the dev menu.
static var errors: Array = []
## Where the current values came from ("", a scenario name, "command line", "dev menu").
static var source: String = ""
## Set by the dev menu before it restarts the town, so the restart keeps the menu's values
## instead of reading the command line again.
static var keep_on_restart: bool = false


static func _row(table: Array, key: String) -> Dictionary:
	for r in table:
		if str(r.k) == key:
			return r
	return {}


static func is_input(key: String) -> bool:
	return not _row(INPUTS, key).is_empty()


static func is_start(key: String) -> bool:
	return not _row(START, key).is_empty()


static func default_of(key: String) -> Variant:
	var r: Dictionary = _row(INPUTS, key)
	if r.is_empty():
		r = _row(START, key)
	return r.get("d", null)


## A number input: the set value, or `fallback` (the code's own constant) when it is not set.
static func f(key: String, fallback: float) -> float:
	return float(values[key]) if values.has(key) else fallback


static func i(key: String, fallback: int) -> int:
	return int(round(float(values[key]))) if values.has(key) else fallback


static func on(key: String, fallback: bool) -> bool:
	return bool(values[key]) if values.has(key) else fallback


static func has_start() -> bool:
	return not start.is_empty() or not start_by_village.is_empty()


## The starting-town fields that apply to one village (its own on top of the shared ones).
static func start_for(village_id: int) -> Dictionary:
	var out: Dictionary = start.duplicate()
	var own: Dictionary = start_by_village.get(village_id, {})
	for k in own:
		out[k] = own[k]
	return out


static func clear() -> void:
	values = {}
	start = {}
	start_by_village = {}
	errors = []
	source = ""


static func _coerce(table: Array, key: String, value: Variant) -> Variant:
	var d: Variant = _row(table, key).get("d", null)
	if typeof(d) == TYPE_BOOL:
		if typeof(value) == TYPE_STRING:
			return str(value).to_lower() in ["1", "true", "yes", "on"]
		return bool(value)
	if typeof(d) == TYPE_INT:
		return int(round(float(value)))
	return float(value)


## Set one value by name. Input names set an input; start names set the starting town for
## every village; "v1.people" or "v2.market_coins" set it for one village. Returns false and
## records the problem when the name is not known.
static func set_value(key: String, value: Variant) -> bool:
	var k: String = key.strip_edges()
	if k.begins_with("v") and k.contains(".") and k.substr(1, k.find(".") - 1).is_valid_int():
		var vid: int = int(k.substr(1, k.find(".") - 1))
		var field: String = k.substr(k.find(".") + 1)
		if not is_start(field):
			errors.append("Unknown starting-town setting: %s" % key)
			return false
		if not start_by_village.has(vid):
			start_by_village[vid] = {}
		start_by_village[vid][field] = _coerce(START, field, value)
		return true
	if is_input(k):
		values[k] = _coerce(INPUTS, k, value)
		return true
	if is_start(k):
		start[k] = _coerce(START, k, value)
		return true
	errors.append("Unknown setting: %s" % key)
	return false


## Everything that is set, as one dictionary (the scenario file format).
static func to_dict() -> Dictionary:
	var out: Dictionary = {"inputs": values.duplicate(), "start": start.duplicate()}
	for vid in start_by_village:
		out["village_%d" % int(vid)] = (start_by_village[vid] as Dictionary).duplicate()
	return out


static func load_dict(d: Dictionary) -> void:
	var inputs: Dictionary = d.get("inputs", {})
	for k in inputs:
		if is_input(str(k)):
			values[str(k)] = _coerce(INPUTS, str(k), inputs[k])
		else:
			errors.append("Unknown input in scenario: %s" % str(k))
	var st: Dictionary = d.get("start", {})
	for k in st:
		if is_start(str(k)):
			start[str(k)] = _coerce(START, str(k), st[k])
		else:
			errors.append("Unknown starting-town setting in scenario: %s" % str(k))
	for key in d:
		var name: String = str(key)
		if not name.begins_with("village_"):
			continue
		var vid: int = int(name.substr(8))
		var own: Dictionary = d[key]
		for k in own:
			if is_start(str(k)):
				if not start_by_village.has(vid):
					start_by_village[vid] = {}
				start_by_village[vid][str(k)] = _coerce(START, str(k), own[k])
			else:
				errors.append("Unknown starting-town setting in %s: %s" % [name, str(k)])


## Scenario files live in res://scenarios (shipped) and user://scenarios (saved from the menu).
static func scenario_path(name_or_path: String) -> String:
	if name_or_path.contains("/") or name_or_path.contains("\\"):
		return name_or_path
	var file: String = name_or_path if name_or_path.ends_with(".json") else name_or_path + ".json"
	for dir in ["user://scenarios/", "res://scenarios/"]:
		if FileAccess.file_exists(dir + file):
			return dir + file
	return "res://scenarios/" + file


static func list_scenarios() -> Array:
	var out: Array = []
	for dir in ["res://scenarios", "user://scenarios"]:
		var da: DirAccess = DirAccess.open(dir)
		if da == null:
			continue
		for fname in da.get_files():
			if fname.ends_with(".json") and not out.has(fname.get_basename()):
				out.append(fname.get_basename())
	out.sort()
	return out


static func load_file(name_or_path: String) -> bool:
	var path: String = scenario_path(name_or_path)
	if not FileAccess.file_exists(path):
		errors.append("Scenario not found: %s" % path)
		return false
	var fa: FileAccess = FileAccess.open(path, FileAccess.READ)
	if fa == null:
		errors.append("Could not open scenario: %s" % path)
		return false
	var parsed: Variant = JSON.parse_string(fa.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("Scenario is not valid JSON: %s" % path)
		return false
	load_dict(parsed)
	source = name_or_path.get_file().get_basename()
	return true


static func save_file(scenario_name: String) -> String:
	var clean: String = scenario_name.strip_edges().validate_filename()
	if clean == "":
		return ""
	DirAccess.make_dir_recursive_absolute("user://scenarios")
	var path: String = "user://scenarios/%s.json" % clean
	var fa: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if fa == null:
		return ""
	var d: Dictionary = to_dict()
	d["name"] = clean
	fa.store_string(JSON.stringify(d, "  "))
	return path


## Read --scenario=name and --set key=value (or --set=key=value) from the arguments after "--".
## Called once when the world starts. A restart from the dev menu keeps the menu's values.
static func load_cmdline() -> void:
	if keep_on_restart:
		return
	clear()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var n: int = 0
	while n < args.size():
		var arg: String = args[n]
		if arg.begins_with("--scenario="):
			load_file(arg.substr(11))
		elif arg.begins_with("--set="):
			_set_pair(arg.substr(6))
		elif arg == "--set" and n + 1 < args.size():
			n += 1
			_set_pair(args[n])
		n += 1
	if source == "" and (not values.is_empty() or has_start()):
		source = "command line"
	for e in errors:
		push_warning("[DEV MODE] " + str(e))
	if not values.is_empty() or has_start():
		print("[DEV MODE] %s: inputs %s start %s %s" % [source, str(values), str(start), str(start_by_village)])


static func _set_pair(pair: String) -> void:
	var eq: int = pair.find("=")
	if eq <= 0:
		errors.append("Expected key=value, got: %s" % pair)
		return
	set_value(pair.substr(0, eq), pair.substr(eq + 1))
