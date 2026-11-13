extends Node
## Event Log test: runs the real game (Main.tscn) at 10x. The Event Log is not shown in play;
## the game keeps it in the background, and L brings it up for debugging.
##
##   1. Hidden: the panel is not on screen and is never drawn, while the game keeps recording
##      every message, the town news and the export buffer.
##   2. L shows town news at once, with the newest news line.
##   3. L again shows everything, rewritten at most 4 times a second, with the newest log line.
##   4. L again hides it.
##
##   godot --headless --path . res://scenes/TestLogPanel.tscn
## Exit code 0 when every check passes.

const HIDDEN_SECONDS := 6.0
const ALL_SECONDS := 3.0


class Probe extends Node:
	var stage := 0
	var t0 := 0
	var results := []
	var done := false
	var busy := false
	var lp: LogPanelController = null
	var main_node: Node = null
	var redraws_at_start := 0
	var buffer_at_start := 0
	var messages := 0
	var news := 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _check(label: String, ok: bool, detail: String = "") -> void:
		results.append(ok)
		print("[LOGPANEL] %s %s%s" % ["PASS" if ok else "FAIL", label, "" if detail == "" else " (" + detail + ")"])

	func _on_msg(m: String) -> void:
		messages += 1
		if LogPanelController.news_line(m) != "":
			news += 1

	func _shown() -> String:
		return lp.event_log.get_parsed_text() if lp and lp.event_log else ""

	## Press L the way the player does.
	func _press_l() -> void:
		var ev := InputEventKey.new()
		ev.keycode = KEY_L
		ev.pressed = true
		main_node._input(ev)

	## Stop the game (nothing new is logged), let the panel catch up, and return what it shows.
	func _settled_text() -> String:
		lp.process_mode = Node.PROCESS_MODE_ALWAYS
		get_tree().paused = true
		await get_tree().create_timer(0.35, true, false, true).timeout
		var text: String = _shown()
		get_tree().paused = false
		lp.process_mode = Node.PROCESS_MODE_INHERIT
		return text

	func _process(_d: float) -> void:
		if done or busy:
			return
		var main := get_tree().current_scene
		if main == null or main == self:
			return
		var clock = main.get("clock")
		if clock != null and clock.speed_multiplier < 10.0:
			clock.set_speed(10.0)
		if lp == null:
			lp = main.get("_log_panel_ctrl")
			if lp == null or lp.event_log == null:
				return
			main_node = main
			for v in main.get_node("World").villages:
				v.event_bus.event_logged.connect(_on_msg)
			t0 = Time.get_ticks_msec()
			redraws_at_start = lp.redraws
			buffer_at_start = lp.log_buffer.size()
			stage = 1
			return
		var secs: float = float(Time.get_ticks_msec() - t0) / 1000.0
		busy = true
		match stage:
			1:
				if secs >= HIDDEN_SECONDS:
					_check("the Event Log is not on screen", not lp.is_shown() and lp.panel_root != null and not lp.panel_root.visible)
					_check("it was never drawn while hidden", lp.redraws == redraws_at_start, "%d rewrites while %d messages came in" % [lp.redraws - redraws_at_start, messages])
					_check("the game kept recording every message in the background", messages > 200 and lp.log_buffer.size() >= buffer_at_start + mini(messages, 1000),
						"%d messages, export buffer %d -> %d" % [messages, buffer_at_start, lp.log_buffer.size()])
					_check("and the town news", news > 0 and not lp.news_lines.is_empty(), "%d news lines" % news)
					_press_l()
					var shown: String = await _settled_text()
					var newest: String = lp.news_lines[lp.news_lines.size() - 1] if not lp.news_lines.is_empty() else ""
					_check("L shows town news at once, with the newest line", lp.is_shown() and shown.begins_with("Town news") and newest != "" and shown.contains(newest), newest)
					_press_l()
					t0 = Time.get_ticks_msec()
					redraws_at_start = lp.redraws
					stage = 2
			2:
				if secs >= ALL_SECONDS:
					var redraws2: int = lp.redraws - redraws_at_start
					_check("L again shows everything, rewritten at most 4 times a second", _shown().begins_with("Everything") and redraws2 <= int(ceil(secs * 4.0)) + 1,
						"%d rewrites in %.1f s" % [redraws2, secs])
					var shown2: String = await _settled_text()
					var last: String = lp.log_lines[lp.log_lines.size() - 1]
					# The start of the line is enough: the panel may wrap or cut a long one.
					_check("with the newest log line", shown2.contains(last.substr(0, 40)), last.substr(0, 80))
					_press_l()
					await get_tree().process_frame
					_check("L a third time hides it again", not lp.is_shown())
					_finish()
		busy = false

	func _finish() -> void:
		done = true
		var fails: int = results.count(false)
		print("[LOGPANEL] COMPLETE checks=%d failures=%d" % [results.size(), fails])
		get_tree().quit(0 if fails == 0 else 1)


func _ready() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 64
	var probe := Probe.new()
	probe.name = "LogPanelProbe"
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred("res://scenes/Main.tscn")
