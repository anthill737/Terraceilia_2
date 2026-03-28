extends Node
class_name EventBus

signal event_logged(msg: String)

## Village label prepended to every log message when non-empty.
## Set this once in Village.initialize() — e.g. "[Village 1]".
var village_label: String = ""


func log(msg: String) -> void:
	if village_label.is_empty():
		event_logged.emit(msg)
	else:
		event_logged.emit(village_label + " " + msg)
