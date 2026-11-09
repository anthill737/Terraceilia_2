extends Node
class_name EventBus

signal event_logged(msg: String)

## Emitted after each completed trade trip with structured telemetry data.
## data keys: agent, from_village, to_village, good, qty, profit, tick
signal trade_flow(data: Dictionary)

## Village label prepended to every log message when non-empty.
## Set this once in Village.initialize() — e.g. "[Village 1]".
var village_label: String = ""


func emit_log(msg: String) -> void:
	if village_label.is_empty():
		event_logged.emit(msg)
	else:
		event_logged.emit(village_label + " " + msg)


## Emit trade_flow signal with structured data and write a [TRADE FLOW] log entry.
## data must contain: agent, from_village, to_village, good, qty, profit, tick
func log_trade_flow(data: Dictionary) -> void:
	trade_flow.emit(data)
	var _msg: String = "[TRADE FLOW] agent=%s from=%s to=%s good=%s qty=%d profit=%.2f" % [
		data.get("agent", "?"),
		data.get("from_village", "?"),
		data.get("to_village", "?"),
		data.get("good", "?"),
		data.get("qty", 0),
		data.get("profit", 0.0),
	]
	if village_label.is_empty():
		event_logged.emit(_msg)
	else:
		event_logged.emit(village_label + " " + _msg)
