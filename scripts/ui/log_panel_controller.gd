class_name LogPanelController
extends Node

# ── State ──────────────────────────────────────────────────────────────────────
var event_log: RichTextLabel = null
var export_log_button: Button = null
var jump_to_bottom_button: Button = null
var log_lines: Array[String] = []
var log_buffer: Array[String] = []
var user_at_bottom: bool = true
const MAX_LOG_LINES: int = 200
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

	while log_lines.size() > MAX_LOG_LINES:
		log_lines.pop_front()

	if event_log:
		event_log.clear()
		for line in log_lines:
			event_log.append_text(line + "\n")
		if user_at_bottom:
			event_log.scroll_to_line(event_log.get_line_count())


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
