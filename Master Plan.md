
Every feature, refactor, and decision must be evaluated against this document.

---

# 🎯 Core Vision

Terraceilia is a **mechanics-first medieval economic simulation** where:

- Agents act autonomously
- Prices emerge from real supply and demand
- Labor allocation is driven by profit and survival
- The system self-corrects through incentives, not rules

The goal is to create a **living economy**, not a scripted one.

---

# 🧱 System Architecture

## Hierarchy


World → Villages → Agents → Systems


---

## 🌍 World Layer
Responsibilities:
- Own all villages
- Advance time (ticks/days)
- Maintain deterministic ordering
- (Future) handle trade + transport

Constraints:
- No shared economy
- No global pricing
- No hidden coordination

---

## 🏘 Village Layer
Each village is a **fully isolated economy node**:

Owns:
- Market
- Agents (households, farmers, bakers)
- Inventory (wheat, bread)
- Land (fields)
- Pricing state
- Logs

Rules:
- No cross-village interaction (until trade system exists)
- No shared references
- Fully deterministic

---

## 👥 Agent Layer

### Households
- Consume bread
- Provide labor pool
- Convert into professions

### Farmers
- Produce wheat
- Require land
- Upstream dependency for entire economy

### Bakers
- Convert wheat → bread
- Profit-driven

---

## ⚙️ Core Systems

- Market System (price formation)
- Production System
- Consumption System
- Career / Labor System
- Inventory + Scarcity System
- Hysteresis System (production throttling)

---

# ⚠️ Non-Negotiable Design Rules

## 1. Strict Locality
- All actions must be village-scoped
- No global node searches
- No name-based targeting
- All references must come from `village_ref`

---

## 2. Determinism
- Same seed → same outcome
- No hidden randomness
- Fixed update ordering

---

## 3. No Artificial Fixes
- No emergency imports
- No invisible stabilizers
- No hidden supply/demand injections

---

## 4. Incentive-Driven Behavior
- No hard quotas
- No forced roles
- Agents respond only to:
  - profit
  - scarcity
  - survival

---

## 5. Systems Must Explain Outcomes
Every result must be traceable through:
- logs
- prices
- inventory
- agent decisions

---

# 📊 Core Economic Model

## Flow


Farmer → Wheat → Baker → Bread → Household → Survival


---

## Key Drivers

### Scarcity
- Primary signal
- Drives pricing
- Drives labor shifts

---

### Profit
- Determines career switching
- Must reflect real system health

---

### Inventory
- Physical constraint
- Prevents artificial equilibrium

---

### Time Lag
- Production delays
- Movement delays (future)
- Critical for realism

---

# 📉 Known System Behaviors

## 1. Oscillation
- Overproduction → shutdown → scarcity → recovery

## 2. Sector Collapse
- Farmers can reach zero
- Causes full economic breakdown

## 3. Profit Illusions
- Bakers appear profitable during instability

## 4. Hysteresis Overreaction
- System responds too late or too strongly

---

# 🧭 Development Roadmap

---

## Phase 1 — Structural Integrity (CURRENT)

### Goals
- Eliminate bugs
- Enforce architecture
- Ensure isolation

### Tasks
- Fix ALL cross-village targeting
- Remove global lookups
- Ensure village-local spawning
- Validate deterministic behavior

---

## Phase 2 — Anti-Extinction Layer

### Goal
Prevent irreversible collapse BEFORE trade exists

### Approach (soft, not forced)
- Resist last-farmer exit
- Increase farmer attractiveness under wheat scarcity
- Speed up recovery response

---

## Phase 3 — Trade System

### Introduce:
- Trader agents
- Arbitrage logic
- Transport delay
- Transport cost

### Rules:
- No global market
- No instant transfers
- Trade only occurs if profitable

---

## Phase 4 — Regional Specialization

Add:
- Soil fertility differences
- Production efficiency differences

Result:
- Trade routes
- Comparative advantage

---

## Phase 5 — Advanced Simulation

Future systems:
- Migration between villages
- Wealth inequality
- Storage logistics
- Infrastructure
- Governance (optional)

---

# 🖥 UI Philosophy

## Goal
Expose system state clearly and immediately.

---

## Top Bar Must Always Show:

- Wheat (inventory + scarcity)
- Bread (inventory + scarcity)
- Population breakdown (H/F/B)
- Profit per role
- Land usage

---

## Alerts Must Surface:

- Bread shortage
- No farmers
- Production pauses
- Starvation risk

---

## Design Principles

- Minimal
- Readable
- Comparable across villages
- No clutter
- No hidden state

---

# 🧪 Testing Philosophy

Every change must answer:

1. Is the system still deterministic?
2. Can a village survive without intervention?
3. Are outcomes driven by incentives?
4. Are failures explainable through logs?

---

# 🚫 Explicit Non-Goals

Do NOT implement:

- Global market
- Instant trade
- Hard-coded balancing
- Hidden stabilizers
- UI-driven logic decisions

---

# 📌 Current Priority

1. Eliminate ALL cross-village targeting
2. Enforce strict village ownership
3. Validate multi-village isolation
4. THEN address anti-extinction

---

# 🧠 Guiding Principles

## Principle 1
> If the system needs intervention, the system is wrong.

---

## Principle 2
> Prices must come from trades, not formulas.

---

## Principle 3
> Stability must emerge, not be imposed.

---

## Principle 4
> Failure is data, not a bug.

---

# 🔁 Usage

Before implementing ANY change, ask:

- Does this preserve locality?
- Does this improve emergent behavior?
- Does this avoid artificial correction?
- Does this keep the system explainable?

If the answer is “no”, do not implement.

---

# 🏁 End State Vision

A system where:

- Multiple villages evolve independently
- Trade naturally connects them
- Labor flows based on opportunity
- Prices stabilize through interaction
- Collapse and recovery are both possible and understandable

---

**This document governs all development decisions.**