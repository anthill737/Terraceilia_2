# Village Ownership Contract

> **Reference document for Phase 4 (Godot-native signals refactor).**
> Any change that touches village ownership state MUST satisfy every invariant in this doc.

---

## 1. The Three Ownership Variables

Every agent (`Agent` base class, `scripts/agent.gd`) carries three distinct pieces of
village-identity information:

| Variable | Type | Purpose |
|---|---|---|
| `home_village_id` | `int` | Numeric ID of the village the agent was **born in**. Used only for cross-village guard checks. Never changes after spawn. |
| `home_village_ref` | `Node` (Village) | Direct node reference to the birth village. Used for return-trip targeting and snapshot queries about "home" conditions. Never changes after spawn. |
| `current_village_ref` | `Node` (Village) | The village the agent is **operating in right now**. Changes **only** on confirmed arrival. All market operations (buy, sell, eval) use this ref. |

### Set at spawn / conversion

`village.gd` sets all three during `spawn_farmer_at()`, `spawn_baker_at()`,
`spawn_household_at()`, and `convert_agent_to_role()`:

```gdscript
# village.gd ~line 590-592, 673-675, 743, 937
agent.home_village_id    = village_id      # int, immutable after this point
agent.home_village_ref   = self            # node ref, immutable after this point
agent.current_village_ref = self           # starts equal to home; changes on arrival
```

---

## 2. The Canonical Rule: `current_village_ref` Changes ONLY in `_on_trade_arrival()`

```
INVARIANT: current_village_ref = arrived_village
           is written ONCE, at the TOP of _on_trade_arrival(),
           and NOWHERE else in the codebase.
```

**FarmerJob** (`scripts/jobs/farmer_job.gd`, `_on_trade_arrival()` ~line 728):
```gdscript
# Canonical village context switch — ONLY here, never at eval or departure
agent.current_village_ref = arrived_village
market = arrived_village.market
agent.market  = arrived_village.market
```

**BakerJob** (`scripts/jobs/baker_job.gd`, `_on_trade_arrival()` ~line 1078):
```gdscript
# Switch village context: ONLY point where current_village_ref may change.
agent.current_village_ref = arrived_village
```

Both jobs rebind `market`, `event_bus`, and routing helpers immediately after the
assignment so every downstream call in the same tick sees the new context.

---

## 3. `home_village_id` and the Cross-Village Guard (`_validate_target`)

`BakerJob._validate_target(target: Node2D)` blocks any target assignment that
would silently wire a baker to infrastructure belonging to another village:

```gdscript
# baker_job.gd ~line 221
var target_vid: int = target.get_meta("village_id", -1)
var agent_vid: int  = agent.home_village_id
if target_vid != -1 and target_vid != agent_vid:
    push_error("[ERROR] CROSS-VILLAGE TARGET BLOCKED ...")
```

This guard fires in `set_locations()`. It uses `home_village_id` (not
`current_village_ref`) so the check is immune to in-flight travel state:
the agent's home id never changes, so `_validate_target` always enforces
birth-village locality for permanent infrastructure (bakery, market node).

Cross-village travel bypasses this guard deliberately via the flag
`_intentional_cross_village = true` which is set in `_start_trade_travel()`
and cleared at the top of `_on_trade_arrival()`.

---

## 4. The `village_id` Meta — Node Tagging

All location nodes (home plots, bakery spots, market nodes) receive a meta tag
so the guard can identify which village owns them:

```gdscript
# village.gd — set during spawn and conversion
node.set_meta("village_id", village_id)   # int, matches Village.village_id
```

Locations tagged this way:
- `_Home` nodes created in `spawn_farmer_at()` (~line 619)
- `_Bakery` spots created in `spawn_baker_at()` (~line 702)
- `_Home` nodes created in `spawn_household_at()` (~line 766)
- Replacement nodes created in `convert_agent_to_role()` (~lines 965, 998)

Market nodes are **not** tagged (they are the Village node's own child and are
looked up via `village.market_node` directly). The guard reads `-1` if the meta
is absent and treats that as "no village restriction".

---

## 5. What Breaks if `current_village_ref` Changes Elsewhere

`current_village_ref` is the sole context pointer for:

- **Trade evaluation** — `_run_trade_evaluation()` calls
  `agent.current_village_ref.get_trade_snapshot()` to price the local market.
  If changed during transit the eval prices the *destination* before arrival,
  producing a false "I'm already at the cheap market" result and blocking the
  outbound trip.

- **`is_at_home` flag** — computed as
  `agent.current_village_ref == agent.home_village_ref`. A premature switch
  makes a traveling agent appear "at home" mid-transit, which can trigger the
  idle guard and re-route it backwards.

- **Idle guard suppression** — when `current_village_ref != home_village_ref`
  the idle guard is silenced so the agent waits at the foreign village during
  the commit window. A premature switch re-arms the guard and causes immediate
  re-routing.

- **Return-trip logic** — the return eval reads
  `agent.home_village_ref.get_trade_snapshot()` and compares against
  `current_village_ref`. A premature context switch collapses both to the
  same village, making every return look unprofitable.

- **`trade_arrival_count`** — incremented only inside `_on_trade_arrival()`.
  Tests use this counter as the canonical "trip completed" signal. Changing
  context outside this function doesn't increment the counter, breaking test
  assertions.

---

## 6. Correct Ownership State by Phase

| Phase | `home_village_id` | `home_village_ref` | `current_village_ref` | `trade_route_active` |
|---|---|---|---|---|
| **(a) Agent at home** | home int | home node | **= home node** | false |
| **(b) Agent traveling (in-transit)** | home int | home node | **still = home node** | true |
| **(c) Agent at foreign village** | home int | home node | **= foreign node** | false (cleared in `_on_trade_arrival`) |
| **(d) Agent returning home** | home int | home node | **= foreign node** (return trip in progress) | true |

Key insight: **`current_village_ref` does NOT change when the agent departs.**
It reflects the last *arrived* village. During transit (b and d) it still
points to the village the agent physically left. Only confirmed arrival switches it.

---

## 7. State Transition Diagram (ASCII)

```
                          spawn / convert
                               │
                               ▼
                     ┌─────────────────┐
                     │   AT HOME (a)   │
                     │ cur = home      │
                     │ trade_active=F  │
                     └────────┬────────┘
                              │
                  _start_travel_to(foreign)
                  trade_route_active = true
                  current_village_ref unchanged (still home)
                              │
                              ▼
                     ┌─────────────────┐
                     │  TRAVELING (b)  │
                     │ cur = home      │  ← still home!
                     │ trade_active=T  │
                     └────────┬────────┘
                              │
                  RouteRunner arrives at
                  _trade_target_market_node
                  → _on_trade_arrival() fires
                  → current_village_ref = foreign
                  → trade_route_active = false
                              │
                              ▼
                     ┌─────────────────┐
                     │  AT FOREIGN (c) │
                     │ cur = foreign   │
                     │ trade_active=F  │
                     └────────┬────────┘
                              │
              sell bread/wheat, wait commit window
              _run_trade_evaluation() decides to return
              _start_travel_to(home_village_ref)
              trade_route_active = true
              current_village_ref unchanged (still foreign)
                              │
                              ▼
                     ┌─────────────────┐
                     │  RETURNING (d)  │
                     │ cur = foreign   │  ← still foreign!
                     │ trade_active=T  │
                     └────────┬────────┘
                              │
                  RouteRunner arrives at home market_node
                  → _on_trade_arrival() fires
                  → current_village_ref = home
                  → trade_route_active = false
                  → trade_arrival_count++
                              │
                              ▼
                     ┌─────────────────┐
                     │   AT HOME (a)   │  ← cycle complete
                     │ cur = home      │
                     │ trade_active=F  │
                     └─────────────────┘
```

---

## 8. Phase 4 Checklist (Godot-Native Signals)

When refactoring to signals, verify:

- [ ] `trade_departed` signal emitted **before** any state change —
  `current_village_ref` is still origin at emission time (both jobs already do this).
- [ ] `trade_arrived` signal emitted **inside** `_on_trade_arrival()`, **after**
  `current_village_ref = arrived_village` is written.
- [ ] No signal handler outside `_on_trade_arrival()` writes `current_village_ref`.
- [ ] `home_village_id` and `home_village_ref` are never modified by signal handlers.
- [ ] `_validate_target` still uses `home_village_id` (int), not `current_village_ref`,
  so it is unaffected by in-flight state.
- [ ] `trade_arrival_count` is incremented only inside `_on_trade_arrival()`.
- [ ] Tests assert on `trade_arrival_count > 0` (completed arrival), not on departure
  or `current_village_ref` changes mid-transit.
