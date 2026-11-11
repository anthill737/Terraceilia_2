extends Node
## Event Log test: runs the real game (Main.tscn) at 10x and checks that the Event Log panel
## shows the right text without being rewritten every frame (it used to be, which took most
## of the frame time at high speed):
##
##   1. Town news (the default): the panel is rewritten at most 4 times a second of real time
##      and never more often than news lines come in, and it shows the newest news line.
##   2. L (everything): the switch shows at once, the panel is rewritten at most 4 times a
##      second, and it shows the newest log line.
##   3. L again: back to town news.
##
##   godot --headless --path . res://scenes/TestLogPanel.tscn
## Exit code 0 when every check passes.

const NEWS_SECONDS := 8.0
const ALL_SECONDS := 3.0


class Probe extends Node:
	var stage := 0
	var t0 := 0
	var results := []
	var done := false
	var busy := false
	var lp: LogPanelController = null
	var redraws_at_start := 0
	var messages := 0
	var news := 0
	var messages_at_start := 0
	var news_at_start := 0

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
			for v in main.get_node("World").villages:
				v.event_bus.event_logged.connect(_on_msg)
			t0 = Time.get_ticks_msec()
			redraws_at_start = lp.redraws
			stage = 1
			return
		var secs: float = float(Time.get_ticks_msec() - t0) / 1000.0
		busy = true
		match stage:
			1:
				if secs >= NEWS_SECONDS:
					var redraws: int = lp.redraws - redraws_at_start
					_check("town news is rewritten at most 4 times a second", redraws <= int(ceil(secs * 4.0)) + 1, "%d rewrites in %.1f s while %d messages came in" % [redraws, secs, messages])
					_check("town news is not rewritten more often than news comes in", redraws <= news + 1, "%d rewrites, %d news lines" % [redraws, news])
					_check("the game logged plenty while it ran", messages > 200, "%d messages" % messages)
					var shown: String = await _settled_text()
					var newest: String = lp.news_lines[lp.news_lines.size() - 1] if not lp.news_lines.is_empty() else ""
					_check("the panel shows the newest town news", newest != "" and shown.begins_with("Town news") and shown.contains(newest), newest)
					lp.toggle_everything()
					t0 = Time.get_ticks_msec()
					stage = 2
			2:
				if _shown().begins_with("Everything") or secs > 1.0:
					_check("L shows everything at once", _shown().begins_with("Everything"), "after %.2f s" % secs)
					redraws_at_start = lp.redraws
					t0 = Time.get_ticks_msec()
					stage = 3
			3:
				if secs >= ALL_SECONDS:
					var redraws2: int = lp.redraws - redraws_at_start
					_check("everything is rewritten at most 4 times a second", redraws2 <= int(ceil(secs * 4.0)) + 1, "%d rewrites in %.1f s" % [redraws2, secs])
					var shown2: String = await _settled_text()
					var last: String = lp.log_lines[lp.log_lines.size() - 1]
					_check("the panel shows the newest log line", shown2.contains(last), last.substr(0, 80))
					lp.toggle_everything()
					t0 = Time.get_ticks_msec()
					stage = 4
			4:
				if _shown().begins_with("Town news") or secs > 1.0:
					_check("L goes back to town news", _shown().begins_with("Town news"), "after %.2f s" % secs)
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
