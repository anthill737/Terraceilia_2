# Terraceilia 2

An economic simulation game built with Godot 4, featuring agent-based modeling of a small economy with farmers, bakers, and households.

## Features

- **Component-Based Architecture**: Modular systems using Wallet, Inventory, HungerNeed, and FoodStockpile components
- **Calendar System**: Global day tracking with event-driven hunger depletion
- **Agent Behaviors**: 
  - Farmer: Plants seeds, harvests wheat, sells to market, manages food buffer
  - Baker: Buys wheat, grinds flour, bakes bread, sells to market while preserving personal stockpile
  - Household: Buys bread from market, consumes daily
- **Market Economy**: Dynamic pricing and trading system
- **Hunger System**: Agents must eat 1 bread per day or face starvation (3-day buffer)
- **Real-time Simulation**: Watch agents move between locations and make economic decisions

## Technical Details

- **Engine**: Godot 4.x
- **Language**: GDScript
- **Architecture**: Event-driven with signal-based communication
- **Audit System**: Economy validation to prevent invariant violations

## Project Structure

- `scripts/` - Core game logic
  - `components/` - Reusable component systems (Wallet, Inventory, HungerNeed, FoodStockpile)
  - `calendar.gd` - Global day tracking system
  - Agent scripts (farmer, baker, household_agent)
  - Market and simulation systems
- `scenes/` - Godot scene files

## Running the Project

1. Open the project in Godot 4.x
2. Run the Main scene
3. Watch the simulation unfold in real-time with UI updates

## License

All rights reserved.
