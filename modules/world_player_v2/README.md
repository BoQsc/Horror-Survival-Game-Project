# World Player v2 - Architecture Document

A complete rewrite of the player module using modern architecture patterns.

## Design Principles

### 1. Package by Feature (Vertical Slices)
Each feature is self-contained with its own models, scripts, scenes, and UI.

### 2. Single Source of Truth
- Items stored once in `ItemRegistry`, referenced by ID everywhere
- No dictionary copying - only references
- Clear ownership of each piece of data

### 3. Feature Registry
- Features self-register on load
- Each feature implements `get_save_data()` and `load_save_data()`
- Automatic save/load without central coordination

### 4. State Machine for Complex Behaviors
- Replace giant if/else chains with state classes
- Each state handles its own input, update, and transitions

---

## Directory Structure

```
world_player_v2/
├── README.md                    # This document
├── core/                        # Essential player foundation
│   ├── player.gd               # Main player script (thin coordinator)
│   ├── player.tscn             # Player scene
│   ├── player_body.gd          # CharacterBody3D movement only
│   └── player_camera.gd        # Camera control only
│
├── registries/                  # Data singletons
│   ├── item_registry.gd        # Single source of truth for items
│   └── feature_registry.gd     # Tracks active features
│
├── features/                    # Self-contained feature modules
│   ├── movement/               # Walk, sprint, jump, swim
│   │   ├── movement.gd
│   │   ├── states/
│   │   │   ├── state_walking.gd
│   │   │   ├── state_sprinting.gd
│   │   │   ├── state_swimming.gd
│   │   │   └── state_falling.gd
│   │   └── sounds/
│   │       └── footsteps/
│   │
│   ├── inventory/              # Hotbar + main inventory
│   │   ├── inventory_manager.gd
│   │   ├── slot_data.gd        # Shared slot logic
│   │   ├── ui/
│   │   │   ├── hotbar_ui.tscn
│   │   │   └── inventory_panel.tscn
│   │   └── README.md
│   │
│   ├── first_person/           # All first-person visuals
│   │   ├── first_person_view.gd  # Coordinator
│   │   ├── arms/
│   │   │   ├── arms.gd
│   │   │   ├── arms.tscn
│   │   │   └── arms_model.glb
│   │   ├── pistol/
│   │   │   ├── fp_pistol.gd
│   │   │   ├── fp_pistol.tscn
│   │   │   ├── heavy_pistol.glb
│   │   │   └── sounds/
│   │   └── axe/
│   │       ├── fp_axe.gd
│   │       └── ...
│   │
│   ├── combat/                 # Melee + ranged combat
│   │   ├── combat_manager.gd
│   │   ├── damage_dealer.gd
│   │   └── states/
│   │
│   ├── mining/                 # Terrain/block breaking
│   │   ├── mining_manager.gd
│   │   ├── durability_tracker.gd
│   │   └── ui/
│   │       └── durability_bar.tscn
│   │
│   ├── grabbing/               # Physics prop grabbing
│   │   ├── grab_manager.gd
│   │   └── grab_preview.gd
│   │
│   ├── interaction/            # E key interactions
│   │   ├── interaction_manager.gd
│   │   ├── interactables/
│   │   │   ├── door_interaction.gd
│   │   │   ├── vehicle_interaction.gd
│   │   │   └── pickup_interaction.gd
│   │   └── ui/
│   │       └── interaction_prompt.tscn
│   │
│   └── modes/                  # Game mode routing (thin)
│       ├── mode_manager.gd
│       ├── mode_play.gd        # Thin - delegates to features
│       ├── mode_build.gd
│       └── mode_editor.gd
│
├── api/                        # External access points
│   ├── player_api.gd          # Get player position, state, etc.
│   ├── inventory_api.gd       # Add/remove/query items
│   └── save_api.gd            # Unified save/load
│
├── signals/                    # All signals in one place
│   └── player_signals.gd
│
└── data/                       # Item definitions, configs
    ├── items/
    │   ├── tools.gd
    │   ├── resources.gd
    │   └── weapons.gd
    └── config.gd
```

---

## Key Patterns

### Item Registry (Single Source of Truth)

```gdscript
# registries/item_registry.gd
extends Node

var _items: Dictionary = {}  # id -> ItemData

func register(id: String, data: ItemData) -> void:
    _items[id] = data

func get_item(id: String) -> ItemData:
    return _items.get(id)

# Inventory stores only IDs
# Hotbar: ["pistol", "axe", "", "dirt"]
# NOT: [{full dict}, {full dict}, ...]
```

### Feature Interface

```gdscript
# Each feature implements this interface
class_name Feature extends Node

func get_feature_id() -> String:
    return ""  # Override: "inventory", "combat", etc.

func get_save_data() -> Dictionary:
    return {}  # Override: return feature state

func load_save_data(data: Dictionary) -> void:
    pass  # Override: restore feature state

func _ready():
    FeatureRegistry.register(self)
```

### State Machine

```gdscript
# features/movement/states/state_sprinting.gd
class_name StateSprinting extends MovementState

func enter():
    player.is_sprinting = true

func physics_update(delta: float):
    handle_movement(SPRINT_SPEED)
    if not Input.is_action_pressed("sprint"):
        transition_to("walking")

func exit():
    player.is_sprinting = false
```

---

## Migration Plan

### Phase 1: Core + Registries
- [ ] Create directory structure
- [ ] Implement ItemRegistry
- [ ] Implement FeatureRegistry
- [ ] Port player core (body, camera)

### Phase 2: Inventory Feature
- [ ] Combine Hotbar + Inventory into one feature
- [ ] Use item IDs instead of dictionary copies
- [ ] Port UI

### Phase 3: First-Person Feature
- [ ] Move models from `/models/` to feature folder
- [ ] Combine arms/axe/pistol under one coordinator

### Phase 4: Combat + Mining
- [ ] Extract from mode_play.gd
- [ ] Implement durability as separate feature

### Phase 5: Interaction + Grabbing
- [ ] Split E key logic into sub-handlers
- [ ] Port T key grab system

### Phase 6: Modes (Thin Layer)
- [ ] Mode scripts become routers only
- [ ] All logic lives in features

---

## Save System Integration

```gdscript
# api/save_api.gd
func save_player_state() -> Dictionary:
    var data = {}
    for feature in FeatureRegistry.get_all():
        data[feature.get_feature_id()] = feature.get_save_data()
    return data

func load_player_state(data: Dictionary) -> void:
    for feature in FeatureRegistry.get_all():
        var id = feature.get_feature_id()
        if data.has(id):
            feature.load_save_data(data[id])
```

---

## Benefits

| Benefit | How Achieved |
|---------|--------------|
| Easy to add features | Just create new folder in `features/` |
| Easy to remove features | Delete folder, update registry |
| Easy to save/load | Each feature handles its own state |
| Easy to find code | Folder name matches feature name |
| No duplicate data | ItemRegistry is single source |
| Testable | Features have clear boundaries |
