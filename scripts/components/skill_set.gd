extends Node
class_name SkillSet

## A person's skill in each trade (docs/SKILL.md), 0 to 1. Skill grows in the trade someone
## works in, as the owner of a shop or as a hired hand in one, and fades slowly in the others.
## It stays with the person when they change what they do. Any trade can be asked for; one
## nobody has worked in starts at START.

const START: float = 0.25
const GAIN_RATE: float = 0.02      # of the way still to go, per day worked
const DECAY_RATE: float = 0.002    # of what one has, per day not worked
const LOW: float = 0.85            # what an unskilled person makes, as a share of the standard
const HIGH: float = 1.25           # what a master makes

var levels: Dictionary = {"Farmer": START, "Baker": START}
var days_in_role: int = 0

# The two skills the older code reads by name.
var farmer: float:
	get: return get_skill("Farmer")
	set(v): levels["Farmer"] = clampf(v, 0.0, 1.0)
var baker: float:
	get: return get_skill("Baker")
	set(v): levels["Baker"] = clampf(v, 0.0, 1.0)


func get_skill(trade: String) -> float:
	return float(levels.get(trade, START))


func set_skill(trade: String, v: float) -> void:
	levels[trade] = clampf(v, 0.0, 1.0)


## One day goes by. `worked` is the trade worked in today ("" or a role with no trade, such as
## "Household", for none): it gains, every other trade fades.
func progress(worked: String) -> void:
	if worked != "" and worked != "Household" and worked != "Merchant" and not levels.has(worked):
		levels[worked] = START
	for trade in levels.keys():
		var s: float = float(levels[trade])
		if trade == worked:
			levels[trade] = clampf(s + GAIN_RATE * (1.0 - s), 0.0, 1.0)
		else:
			levels[trade] = clampf(s - DECAY_RATE * s, 0.0, 1.0)
	days_in_role += 1


## How much someone makes in `role`, as a share of the standard: LOW with no skill, HIGH as
## a master.
func productivity_for(role: String) -> float:
	return factor(get_skill(role))


static func factor(skill: float) -> float:
	return clampf(lerpf(LOW, HIGH, skill), LOW, HIGH)


func reset_days() -> void:
	days_in_role = 0
