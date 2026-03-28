# AGENTS.md

## Cursor Cloud specific instructions

### Project overview

Terraceilia is a Godot 4.5 GDScript economic simulation game. There are no external dependencies, package managers, or build tools — the only runtime is the Godot engine binary.

### Running the game

- **GUI mode:** `DISPLAY=:99 godot --path /workspace res://scenes/Main.tscn`
  - Requires Xvfb: `Xvfb :99 -screen 0 1920x1080x24 &`
  - Vulkan is unavailable in the VM; Godot automatically falls back to OpenGL (llvmpipe software renderer). ALSA audio is also unavailable; Godot falls back to a dummy audio driver. Both fallbacks are harmless.

- **Headless tests (exit 0 = pass, 1 = fail):**
  - **Career / log cadence:** `godot --headless --path /workspace res://scenes/TestCareer.tscn` — 36-day career log validation (partial pass if town goes extinct early).
  - **Economy invariants:** `godot --headless --path /workspace res://scenes/TestEconomy.tscn` — runs **three** RNG seeds per process (`42`, `99999`, `1337`); each run checks market + every pop each tick (up to 60 days or `sim_failed`). Optional args after `--`: `--min-survival-days N` (fail if extinction before calendar day `N`), `--max-days N`, `--seeds 1,2,3` or `--seeds=1,2,3`.

- **Windows full suite:** `powershell -ExecutionPolicy Bypass -File tools/run_all_tests.ps1` (set `$env:GODOT` if the engine is not at the default path in the script).

### Key caveats

- No standalone GDScript linter outside the editor. Parse-check each file with: `godot --headless --path /workspace --check-only --script res://scripts/example.gd`
- The project uses Godot 4.5 (`config/features=PackedStringArray("4.5", "Forward Plus")` in `project.godot`). The engine binary must match this version.
- Entry point is `scenes/Main.tscn` (set in `project.godot` under `run/main_scene`).
- See `README.md` for feature overview and `DEV_NOTES.md` for architecture details.
