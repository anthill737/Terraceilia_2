# AGENTS.md

## Cursor Cloud specific instructions

### Project overview

Terraceilia is a Godot 4.5 GDScript economic simulation game. There are no external dependencies, package managers, or build tools — the only runtime is the Godot engine binary.

### Running the game

- **GUI mode:** `DISPLAY=:99 godot --path /workspace res://scenes/Main.tscn`
  - Requires Xvfb: `Xvfb :99 -screen 0 1920x1080x24 &`
  - Vulkan is unavailable in the VM; Godot automatically falls back to OpenGL (llvmpipe software renderer). ALSA audio is also unavailable; Godot falls back to a dummy audio driver. Both fallbacks are harmless.

- **Headless test:** `godot --headless --path /workspace res://scenes/TestCareer.tscn`
  - Runs a 36-day career-switching validation. Exits with code 0 on PASS, 1 on FAIL.

### Key caveats

- No linter or type-checker is available for GDScript outside the Godot editor. Static analysis is done via `godot --headless --check-only` on individual scripts if needed.
- The project uses Godot 4.5 (`config/features=PackedStringArray("4.5", "Forward Plus")` in `project.godot`). The engine binary must match this version.
- Entry point is `scenes/Main.tscn` (set in `project.godot` under `run/main_scene`).
- See `README.md` for feature overview and `DEV_NOTES.md` for architecture details.
