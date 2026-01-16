extends Node
class_name EventBus

signal event_logged(msg: String)


func log(msg: String) -> void:
	event_logged.emit(msg)
