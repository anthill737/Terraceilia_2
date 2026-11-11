class_name LogPanelController
extends Node

# ── State ──────────────────────────────────────────────────────────────────────
var event_log: RichTextLabel = null
var export_log_button: Button = null
var jump_to_bottom_button: Button = null
var log_lines: Array[String] = []
## Town news: the lines a player cares about (who was hired, what was built, who arrived or
## left, what the merchants sold, what trouble struck), in plain words. The panel shows these
## by default; L switches to everything (the full debug log, which is also what Export saves).
var news_lines: Array[String] = []
var show_everything: bool = false
var log_buffer: Array[String] = []
var user_at_bottom: bool = true
const MAX_LOG_LINES: int = 200
## The export buffer keeps this many of the newest lines; older ones are dropped.
const MAX_BUFFER_LINES: int = 20000
## The buffer is cut back only once it is this far over the cap, so the cut is not per line.
const BUFFER_TRIM_SLACK: int = 2000
## Set when the text on show changed. The panel is rewritten at most REDRAW_EVERY_MS of real
## time apart, and only while it is on screen. It used to be rewritten every frame a message
## came in, which at high speed was every frame: three quarters of the game's frame time went
## on laying out the same 200 lines again.
var _log_dirty: bool = false
const REDRAW_EVERY_MS: int = 250
var _last_redraw_ms: int = -100000
## How many times the text was rewritten (tests).
var redraws: int = 0
const SCROLL_THRESHOLD: int = 50


## Wire the controller to the log panel UI nodes found under log_vbox.
## Call this once from main._ready() after the UI tree is built.
func setup(log_vbox: Node) -> void:
	if log_vbox == null:
		push_warning("LogPanelController.setup: log_vbox is null — log panel disabled")
		return

	event_log = log_vbox.get_node_or_null("EventLog")
	export_log_button = log_vbox.get_node_or_null("ExportLogButton")
	if export_log_button:
		export_log_button.pressed.connect(export_log)

	if log_vbox.has_node("JumpToBottomButton"):
		jump_to_bottom_button = log_vbox.get_node("JumpToBottomButton")
		jump_to_bottom_button.pressed.connect(_on_jump_to_bottom)

	if event_log:
		var vscroll = event_log.get_v_scroll_bar()
		if vscroll:
			vscroll.value_changed.connect(_on_log_scroll)


## Connect a village's EventBus so its messages appear in the log panel.
## Safe to call multiple times — duplicate connections are skipped.
func connect_village_bus(event_bus: Node) -> void:
	if event_bus == null:
		return
	if not event_bus.event_logged.is_connected(_on_event_logged):
		event_bus.event_logged.connect(_on_event_logged)


# ── Handlers ───────────────────────────────────────────────────────────────────

func _on_event_logged(msg: String) -> void:
	log_lines.append(msg)
	log_buffer.append(msg)
	var news: String = news_line(msg)
	if news != "":
		news_lines.append(news)
		while news_lines.size() > MAX_LOG_LINES:
			news_lines.pop_front()
		_log_dirty = true

	while log_lines.size() > MAX_LOG_LINES:
		log_lines.pop_front()
	if log_buffer.size() > MAX_BUFFER_LINES + BUFFER_TRIM_SLACK:
		log_buffer.assign(log_buffer.slice(log_buffer.size() - MAX_BUFFER_LINES))

	# Town news only changes when a news line comes in; the full log changes with every message.
	if show_everything:
		_log_dirty = true


## Rewrite the visible log when its text changed, at most every REDRAW_EVERY_MS of real time
## (whatever the game speed) and only while it is on screen.
func _process(_delta: float) -> void:
	if not _log_dirty or event_log == null:
		return
	if not event_log.is_visible_in_tree():
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_redraw_ms < REDRAW_EVERY_MS:
		return
	_last_redraw_ms = now
	_log_dirty = false
	redraws += 1
	event_log.clear()
	if show_everything:
		event_log.append_text("Everything (press L for town news)\n\n" + "\n".join(log_lines) + "\n")
	else:
		event_log.append_text("Town news (press L for everything)\n\n" + "\n".join(news_lines) + "\n")
	if user_at_bottom:
		event_log.scroll_to_line(event_log.get_line_count())


## Switch the panel between town news and the full log.
func toggle_everything() -> void:
	show_everything = not show_everything
	user_at_bottom = true
	_log_dirty = true
	_last_redraw_ms = -100000   # show the switch at once


## "[TAG] day=12 text" -> "Day 12: text".
static func _day_line(rest: String, tag: String) -> String:
	var body: String = rest.substr(tag.length())
	var sp: int = body.find(" ")
	if not body.begins_with("day=") or sp < 0:
		return body
	return "Day %s: %s" % [body.substr(4, sp - 4), body.substr(sp + 1)]


## The plain-words version of a log message if it is town news, else "".
static func news_line(msg: String) -> String:
	var label: String = ""
	var rest: String = msg
	if msg.begins_with("[Village"):
		var i: int = msg.find("] ")
		if i > 0:
			label = msg.substr(1, i - 1)
			rest = msg.substr(i + 2)
	var out: String = ""
	if rest.begins_with("[HOUSING] day="):
		if rest.contains(" houses=") or rest.contains("started with"):
			return ""
		out = _day_line(rest, "[HOUSING] ")
	elif rest.begins_with("[HANDS] day="):
		if rest.contains(" employed="):
			return ""
		out = _day_line(rest, "[HANDS] ")
	elif rest.begins_with("[SERVANT] day="):
		out = _day_line(rest, "[SERVANT] ")
	elif rest.begins_with("[SHOCK] day="):
		out = _day_line(rest, "[SHOCK] ")
	elif rest.begins_with("[DEATH] day="):
		out = _day_line(rest, "[DEATH] ")
	elif rest.begins_with("[MERCHANT] "):
		out = rest.substr(11)
	elif rest.begins_with("POP GROWTH: spawning "):
		out = "A newcomer arrives: " + rest.substr(21).get_slice(" ", 0)
	elif rest.begins_with("[MIGRATION] ") and rest.contains(" leaving (reason: "):
		out = rest.substr(12).replace(" leaving (reason: ", " leaves town (")
		for pair in [["no_food", "no food"], ["no_rent", "rent unpaid"], ["no_firewood", "no firewood"], ["survival", "no food"]]:
			out = out.replace(pair[0], pair[1])
	elif rest.begins_with("[LaborMkt] ") and rest.contains("closing shop"):
		out = rest.substr(11)
	elif rest.begins_with("[MOBILITY] ") and rest.contains("conversion to "):
		var who: String = rest.substr(11).get_slice(" ", 0)
		var role: String = rest.get_slice("conversion to ", 1).get_slice(" ", 0)
		if role == "household":
			out = "%s gives up the business and looks for work" % who
		else:
			out = "%s sets up as a %s" % [who, role]
	elif rest.contains("bought a loaf and ate it"):
		out = rest
	if out == "":
		return ""
	if label != "":
		return "%s: %s" % [label, out]
	return out


func _on_log_scroll(_value: float) -> void:
	if event_log:
		var vscroll = event_log.get_v_scroll_bar()
		if vscroll:
			var max_scroll = vscroll.max_value - vscroll.page
			user_at_bottom = (max_scroll - vscroll.value) <= SCROLL_THRESHOLD


func _on_jump_to_bottom() -> void:
	user_at_bottom = true
	if event_log:
		event_log.scroll_to_line(event_log.get_line_count())


func export_log() -> void:
	print("export_log() called - buffer size: ", log_buffer.size())

	var log_snapshot = log_buffer.duplicate()

	var dir = DirAccess.open("user://")
	if not dir:
		print("ERROR: Could not open user:// directory")
		if event_log:
			event_log.append_text("[ERROR] Could not access user directory\n")
		return

	if not dir.dir_exists("logs"):
		var err = dir.make_dir("logs")
		if err != OK:
			if event_log:
				event_log.append_text("[ERROR] Failed to create logs directory\n")
			return

	var datetime = Time.get_datetime_dict_from_system()
	var filename = "economy_log_%04d-%02d-%02d_%02d-%02d-%02d.txt" % [
		datetime.year, datetime.month, datetime.day,
		datetime.hour, datetime.minute, datetime.second
	]
	var path = "user://logs/" + filename

	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		for line in log_snapshot:
			file.store_line(line)
		file.close()
		var abs_path = ProjectSettings.globalize_path(path)
		if event_log:
			event_log.append_text("[EXPORT] Log saved to: %s\n" % abs_path)
			event_log.append_text("[EXPORT] (%d lines written)\n" % log_snapshot.size())
	else:
		var err = FileAccess.get_open_error()
		if event_log:
			event_log.append_text("[ERROR] Failed to export log (Error: %d)\n" % err)
