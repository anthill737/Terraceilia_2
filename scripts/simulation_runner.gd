extends Node
class_name SimulationRunner

# SimulationRunner
# Responsible for managing the tick-based simulation loop
# Will control when farmers act, markets update, and time progresses

# ── Global simulation timing constants ──────────────────────────────────────
## Days at the start of a fresh simulation during which migration is suppressed.
## Prevents households from leaving before the bread supply chain has had a chance
## to bootstrap (farmer → wheat → baker → bread → market).
const STARTUP_GRACE_DAYS: int = 5
