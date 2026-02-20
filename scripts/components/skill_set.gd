extends Node
class_name SkillSet

## Tracks per-agent skill levels and handles daily progression/decay.
## Skills persist across role changes and affect production multipliers.

var farmer: float = 0.25
var baker: float = 0.25
var days_in_role: int = 0

const GAIN_RATE: float = 0.02
const DECAY_RATE: float = 0.002


func progress(current_role: String) -> void:
	match current_role:
		"Farmer":
			farmer = clamp(farmer + GAIN_RATE * (1.0 - farmer), 0.0, 1.0)
			baker  = clamp(baker  - DECAY_RATE * baker,         0.0, 1.0)
		"Baker":
			baker  = clamp(baker  + GAIN_RATE * (1.0 - baker),  0.0, 1.0)
			farmer = clamp(farmer - DECAY_RATE * farmer,        0.0, 1.0)
		_:
			farmer = clamp(farmer - DECAY_RATE * farmer, 0.0, 1.0)
			baker  = clamp(baker  - DECAY_RATE * baker,  0.0, 1.0)
	days_in_role += 1


func productivity_for(role: String) -> float:
	match role:
		"Farmer":
			return clamp(lerpf(0.85, 1.25, farmer), 0.85, 1.25)
		"Baker":
			return clamp(lerpf(0.85, 1.25, baker), 0.85, 1.25)
	return 1.0


func reset_days() -> void:
	days_in_role = 0
