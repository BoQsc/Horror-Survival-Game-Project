# World Player Module

A modular, signal-driven player system for the GPU Marching Cubes project.

## Structure

```
modules/world_player/
├── player.tscn              # Main player scene
├── player.gd                # Coordinator script
├── components/              # Player behavior components
│   ├── player_movement.gd   # Walk, jump, gravity
│   ├── player_camera.gd     # Mouse look, targeting
│   ├── player_interaction.gd # E key interactions (planned)
│   └── player_combat.gd     # Melee combat (planned)
├── systems/                 # Game systems
│   ├── hotbar.gd           # 10-slot hotbar (planned)
│   ├── inventory.gd        # Item storage (planned)
│   └── item_use_router.gd  # Routes item actions (planned)
├── modes/                   # Mode behaviors
│   ├── mode_manager.gd     # Mode transitions (planned)
│   ├── mode_play.gd        # Gameplay mode (planned)
│   ├── mode_build.gd       # Construction mode (planned)
│   └── mode_editor.gd      # Creative mode (planned)
├── ui/                      # HUD components (planned)
├── autoload/                # Global singletons
│   ├── player_signals.gd   # Event bus
│   └── player_stats.gd     # Health, stamina
├── data/
│   └── item_definitions.gd # Item categories
└── reference/               # Legacy code archive
```

## Usage

1. Add the `WorldPlayer` scene to your main scene
2. Ensure autoloads are registered (done automatically in project.godot)
3. Managers should be in groups: `terrain_manager`, `building_manager`, `vegetation_manager`

## Modes

| Mode | Trigger | Description |
|------|---------|-------------|
| PLAY | Default / gameplay items | Combat, mining, harvesting |
| BUILD | Holding building items | Block/object/prop placement |
| EDITOR | Backtick (`) key | Creative tools, fly mode |

## Signals (PlayerSignals autoload)

- `item_used`, `item_changed`, `hotbar_slot_selected`
- `mode_changed`
- `damage_dealt`, `damage_received`, `player_died`
- `interaction_available`, `interaction_unavailable`, `interaction_performed`
- `inventory_changed`, `inventory_toggled`
- `game_menu_toggled`
- `player_jumped`, `player_landed`
