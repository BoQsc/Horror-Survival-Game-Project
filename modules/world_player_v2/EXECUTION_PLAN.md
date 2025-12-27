# World Player V2 - Execution Plan

A step-by-step migration guide from `world_player` to `world_player_v2`.

---

## Table of Contents

1. [Overview](#overview)
2. [Phase 1: Foundation](#phase-1-foundation)
3. [Phase 2: Registries](#phase-2-registries)
4. [Phase 3: Core Player](#phase-3-core-player)
5. [Phase 4: Movement Feature](#phase-4-movement-feature)
6. [Phase 5: Inventory Feature](#phase-5-inventory-feature)
7. [Phase 6: First-Person Feature](#phase-6-first-person-feature)
8. [Phase 7: Combat Feature](#phase-7-combat-feature)
9. [Phase 8: Mining Feature](#phase-8-mining-feature)
10. [Phase 9: Grabbing Feature](#phase-9-grabbing-feature)
11. [Phase 10: Interaction Feature](#phase-10-interaction-feature)
12. [Phase 11: Modes (Thin Layer)](#phase-11-modes)
13. [Phase 12: Save/Load Integration](#phase-12-save-load)
14. [Phase 13: Migration & Testing](#phase-13-migration)

---

## Overview

### Current State Analysis

| Component | File | Lines | Issues |
|-----------|------|-------|--------|
| ModePlay | `modes/mode_play.gd` | 1533 | Handles 15+ concerns in one file |
| Hotbar | `systems/hotbar.gd` | 320 | Duplicates logic with Inventory |
| Inventory | `systems/inventory.gd` | ~150 | Separate from hotbar, no shared base |
| PlayerInteraction | `components/player_interaction.gd` | 397 | E key, barricade, doors, vehicles |
| FirstPerson* | `components/first_person_*.gd` | 3 files | Arms, Axe, Pistol separate |
| PlayerHUD | `ui/player_hud.gd` | 600+ | Durability, health, underwater, etc. |
| ItemDefinitions | `data/item_definitions.gd` | 216 | Static functions, returns dictionaries |

### mode_play.gd Function Breakdown (62 functions)

**Combat (12 functions):**
- `_do_punch()`, `_do_tool_attack()`, `_do_pistol_fire()`
- `_find_damageable()`, `_spawn_pistol_hit_effect()`
- `_on_punch_ready()`, `_on_pistol_fire_ready()`, `_on_axe_ready()`

**Mining/Harvesting (8 functions):**
- Terrain damage tracking, vegetation harvesting
- Object/block damage, durability signals

**Grabbing (8 functions):**
- `_try_grab_prop()`, `_grab_dropped_prop()`, `_drop_grabbed_prop()`
- `_update_held_prop()`, `_get_pickup_target()`
- `_enable/disable_preview_collisions()`

**Pickup (3 functions):**
- `_try_pickup_item()`, `_get_item_data_from_pickup()`

**Resource Placement (5 functions):**
- `_do_resource_place()`, `_do_bucket_place()`, `_do_bucket_collect()`
- `_do_vegetation_place()`

**Targeting (4 functions):**
- `_update_terrain_targeting()`, `_update_target_material()`
- `_check_durability_target()`, `_get_material_from_mesh()`

**Utility (8 functions):**
- Barycentric calculation, collection helpers, etc.

---

## Phase 1: Foundation

### 1.1 Create Directory Structure

```
mkdir modules/world_player_v2
mkdir modules/world_player_v2/core
mkdir modules/world_player_v2/registries
mkdir modules/world_player_v2/features
mkdir modules/world_player_v2/features/movement
mkdir modules/world_player_v2/features/movement/states
mkdir modules/world_player_v2/features/inventory
mkdir modules/world_player_v2/features/inventory/ui
mkdir modules/world_player_v2/features/first_person
mkdir modules/world_player_v2/features/first_person/arms
mkdir modules/world_player_v2/features/first_person/pistol
mkdir modules/world_player_v2/features/first_person/axe
mkdir modules/world_player_v2/features/combat
mkdir modules/world_player_v2/features/combat/states
mkdir modules/world_player_v2/features/mining
mkdir modules/world_player_v2/features/mining/ui
mkdir modules/world_player_v2/features/grabbing
mkdir modules/world_player_v2/features/interaction
mkdir modules/world_player_v2/features/interaction/handlers
mkdir modules/world_player_v2/features/modes
mkdir modules/world_player_v2/api
mkdir modules/world_player_v2/signals
mkdir modules/world_player_v2/data
mkdir modules/world_player_v2/data/items
```

### 1.2 Create Base Classes

**File: `features/feature_base.gd`**
```gdscript
extends Node
class_name FeatureBase

## Called when feature should save its state
func get_save_data() -> Dictionary:
    return {}

## Called when feature should load saved state
func load_save_data(data: Dictionary) -> void:
    pass

## Called when feature is registered
func on_registered() -> void:
    pass

## Called when feature is unregistered
func on_unregistered() -> void:
    pass
```

---

## Phase 2: Registries

### 2.1 Item Registry (Single Source of Truth)

**File: `registries/item_registry.gd`**

```gdscript
extends Node
class_name ItemRegistry

## Item storage - keyed by item_id
var _items: Dictionary = {}  # String -> ItemData

## ItemData structure (Resource-based, not Dictionary)
## See data/items/item_data.gd

func _ready() -> void:
    _register_default_items()

func register(item: ItemData) -> void:
    if item.id.is_empty():
        push_error("ItemRegistry: Cannot register item with empty ID")
        return
    _items[item.id] = item
    print("ItemRegistry: Registered '%s'" % item.id)

func get_item(id: String) -> ItemData:
    return _items.get(id)

func has_item(id: String) -> bool:
    return _items.has(id)

func get_all_ids() -> Array[String]:
    var ids: Array[String] = []
    for key in _items.keys():
        ids.append(key)
    return ids

## Register all default items
func _register_default_items() -> void:
    # Tools
    register(preload("res://modules/world_player_v2/data/items/tools/pickaxe_stone.tres"))
    register(preload("res://modules/world_player_v2/data/items/tools/axe_stone.tres"))
    
    # Weapons
    register(preload("res://modules/world_player_v2/data/items/weapons/heavy_pistol.tres"))
    
    # Resources
    register(preload("res://modules/world_player_v2/data/items/resources/dirt.tres"))
    register(preload("res://modules/world_player_v2/data/items/resources/stone.tres"))
    # ... etc
```

### 2.2 Item Data Resource

**File: `data/items/item_data.gd`**

```gdscript
extends Resource
class_name ItemData

@export var id: String = ""
@export var display_name: String = ""
@export var icon: Texture2D
@export var category: ItemCategory = ItemCategory.NONE
@export var max_stack: int = 1
@export var damage: int = 0
@export var mining_strength: float = 0.0
@export var is_firearm: bool = false

## Optional scene for world representation
@export_file("*.tscn") var world_scene: String = ""

## Optional scene for first-person view
@export_file("*.tscn") var first_person_scene: String = ""

enum ItemCategory {
    NONE,      # Fists
    TOOL,      # Pickaxe, Axe
    BUCKET,    # Water bucket
    RESOURCE,  # Dirt, Stone
    BLOCK,     # Building blocks
    OBJECT,    # Doors, furniture
    PROP       # Physics props, weapons
}
```

**Example Item: `data/items/weapons/heavy_pistol.tres`**
```tres
[gd_resource type="Resource" script_class="ItemData" load_steps=2 format=3]

[ext_resource type="Script" path="res://modules/world_player_v2/data/items/item_data.gd" id="1"]

[resource]
script = ExtResource("1")
id = "heavy_pistol"
display_name = "Heavy Pistol"
category = 6  # PROP
max_stack = 1
damage = 5
is_firearm = true
world_scene = "res://modules/world_player_v2/features/first_person/pistol/heavy_pistol_physics.tscn"
first_person_scene = "res://modules/world_player_v2/features/first_person/pistol/fp_pistol.tscn"
```

### 2.3 Feature Registry

**File: `registries/feature_registry.gd`**

```gdscript
extends Node
class_name FeatureRegistry

var _features: Dictionary = {}  # String -> FeatureBase

func register(feature: FeatureBase, id: String) -> void:
    _features[id] = feature
    feature.on_registered()
    print("FeatureRegistry: Registered '%s'" % id)

func unregister(id: String) -> void:
    if _features.has(id):
        _features[id].on_unregistered()
        _features.erase(id)

func get_feature(id: String) -> FeatureBase:
    return _features.get(id)

func get_all() -> Array[FeatureBase]:
    var result: Array[FeatureBase] = []
    for f in _features.values():
        result.append(f)
    return result

## Collect save data from all features
func collect_save_data() -> Dictionary:
    var data = {}
    for id in _features:
        data[id] = _features[id].get_save_data()
    return data

## Distribute save data to all features
func apply_save_data(data: Dictionary) -> void:
    for id in _features:
        if data.has(id):
            _features[id].load_save_data(data[id])
```

---

## Phase 3: Core Player

### 3.1 Player Script (Thin Coordinator)

**File: `core/player.gd`**

```gdscript
extends CharacterBody3D
class_name WorldPlayerV2

## Component references
var body: PlayerBody
var camera: PlayerCameraV2

## Feature references (populated by feature scripts)
var features: Dictionary = {}  # id -> FeatureBase

## Manager references (external)
var terrain_manager: Node
var building_manager: Node  
var vegetation_manager: Node

func _ready() -> void:
    body = $Components/Body
    camera = $Components/Camera
    
    # Find external managers
    terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
    building_manager = get_tree().get_first_node_in_group("building_manager")
    vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")

## API methods (delegates to features/components)
func get_look_direction() -> Vector3:
    return camera.get_look_direction() if camera else Vector3.FORWARD

func raycast(distance: float = 10.0, mask: int = 0xFFFFFFFF) -> Dictionary:
    return camera.raycast(distance, mask) if camera else {}

func take_damage(amount: int, source: Node = null) -> void:
    var combat = features.get("combat") as CombatFeature
    if combat:
        combat.take_damage(amount, source)
```

### 3.2 Player Scene Structure

**File: `core/player.tscn`**
```
WorldPlayerV2 (CharacterBody3D)
├── CollisionShape3D
├── Head (Node3D)
│   └── Camera3D
├── Components/
│   ├── Body (PlayerBody)
│   └── Camera (PlayerCameraV2)
└── Features/
    ├── Movement (MovementFeature)
    ├── Inventory (InventoryFeature)
    ├── FirstPerson (FirstPersonFeature)
    ├── Combat (CombatFeature)
    ├── Mining (MiningFeature)
    ├── Grabbing (GrabbingFeature)
    ├── Interaction (InteractionFeature)
    └── Modes (ModesFeature)
```

---

## Phase 4: Movement Feature

### 4.1 Movement Feature Main Script

**File: `features/movement/movement_feature.gd`**

```gdscript
extends FeatureBase
class_name MovementFeature

const WALK_SPEED = 5.0
const SPRINT_SPEED = 8.5
const SWIM_SPEED = 4.0
const JUMP_VELOCITY = 4.5

var player: WorldPlayerV2
var state_machine: MovementStateMachine

var is_sprinting: bool = false
var is_swimming: bool = false

func _ready() -> void:
    player = get_parent().get_parent() as WorldPlayerV2
    state_machine = $StateMachine
    state_machine.setup(self)
    
    FeatureRegistry.register(self, "movement")

func _physics_process(delta: float) -> void:
    state_machine.update(delta)
    player.move_and_slide()

func get_save_data() -> Dictionary:
    return {
        "position": player.global_position,
        "rotation": player.rotation
    }

func load_save_data(data: Dictionary) -> void:
    if data.has("position"):
        player.global_position = data["position"]
    if data.has("rotation"):
        player.rotation = data["rotation"]
```

### 4.2 Movement State Machine

**File: `features/movement/movement_state_machine.gd`**

```gdscript
extends Node
class_name MovementStateMachine

var current_state: MovementState
var states: Dictionary = {}
var movement: MovementFeature

func setup(feature: MovementFeature) -> void:
    movement = feature
    
    # Register states
    for child in get_children():
        if child is MovementState:
            states[child.name.to_lower()] = child
            child.setup(self, movement)
    
    # Start in walking state
    transition_to("walking")

func update(delta: float) -> void:
    if current_state:
        current_state.physics_update(delta)

func transition_to(state_name: String) -> void:
    if current_state:
        current_state.exit()
    
    current_state = states.get(state_name)
    if current_state:
        current_state.enter()
```

### 4.3 Movement States

**File: `features/movement/states/movement_state.gd`**

```gdscript
extends Node
class_name MovementState

var state_machine: MovementStateMachine
var movement: MovementFeature
var player: WorldPlayerV2

func setup(sm: MovementStateMachine, m: MovementFeature) -> void:
    state_machine = sm
    movement = m
    player = m.player

func enter() -> void:
    pass

func exit() -> void:
    pass

func physics_update(delta: float) -> void:
    pass

func transition_to(state_name: String) -> void:
    state_machine.transition_to(state_name)
```

**File: `features/movement/states/state_walking.gd`**

```gdscript
extends MovementState

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

func physics_update(delta: float) -> void:
    # Apply gravity
    if not player.is_on_floor():
        player.velocity.y -= gravity * delta
    
    # Handle jump
    if Input.is_action_just_pressed("ui_accept") and player.is_on_floor():
        player.velocity.y = movement.JUMP_VELOCITY
        PlayerSignals.player_jumped.emit()
    
    # Check for sprint
    var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
    var direction = (player.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
    
    if Input.is_action_pressed("sprint") and direction != Vector3.ZERO:
        transition_to("sprinting")
        return
    
    # Apply movement
    var speed = movement.WALK_SPEED
    if direction:
        player.velocity.x = direction.x * speed
        player.velocity.z = direction.z * speed
    else:
        player.velocity.x = move_toward(player.velocity.x, 0, speed)
        player.velocity.z = move_toward(player.velocity.z, 0, speed)
    
    # Check for swimming
    if movement.is_swimming:
        transition_to("swimming")
```

---

## Phase 5: Inventory Feature

### 5.1 Inventory Feature (Unified)

**File: `features/inventory/inventory_feature.gd`**

```gdscript
extends FeatureBase
class_name InventoryFeature

const HOTBAR_SIZE = 10
const MAIN_SIZE = 20
const MAX_STACK = 64

## Slots store item_id + count only (not full dictionaries)
var hotbar_slots: Array[SlotData] = []
var main_slots: Array[SlotData] = []
var selected_hotbar: int = 0

signal slot_changed(slot_type: String, index: int)
signal selection_changed(index: int)

func _ready() -> void:
    _initialize_slots()
    FeatureRegistry.register(self, "inventory")

func _initialize_slots() -> void:
    hotbar_slots.clear()
    main_slots.clear()
    
    for i in HOTBAR_SIZE:
        hotbar_slots.append(SlotData.new())
    for i in MAIN_SIZE:
        main_slots.append(SlotData.new())

## Get item at hotbar slot (returns ItemData from registry)
func get_hotbar_item(index: int) -> ItemData:
    if index < 0 or index >= hotbar_slots.size():
        return null
    var slot = hotbar_slots[index]
    if slot.item_id.is_empty():
        return null
    return ItemRegistry.get_item(slot.item_id)

## Add item to inventory (hotbar first, then main)
func add_item(item_id: String, count: int = 1) -> int:
    var remaining = count
    
    # Try stacking in hotbar
    remaining = _try_stack(hotbar_slots, item_id, remaining)
    if remaining <= 0:
        return 0
    
    # Try stacking in main
    remaining = _try_stack(main_slots, item_id, remaining)
    if remaining <= 0:
        return 0
    
    # Try empty slots in hotbar
    remaining = _try_empty(hotbar_slots, item_id, remaining, "hotbar")
    if remaining <= 0:
        return 0
    
    # Try empty slots in main
    remaining = _try_empty(main_slots, item_id, remaining, "main")
    
    return remaining  # Return overflow

func get_save_data() -> Dictionary:
    var hotbar_save = []
    for slot in hotbar_slots:
        hotbar_save.append({"id": slot.item_id, "count": slot.count})
    
    var main_save = []
    for slot in main_slots:
        main_save.append({"id": slot.item_id, "count": slot.count})
    
    return {
        "hotbar": hotbar_save,
        "main": main_save,
        "selected": selected_hotbar
    }

func load_save_data(data: Dictionary) -> void:
    if data.has("hotbar"):
        for i in min(data["hotbar"].size(), hotbar_slots.size()):
            hotbar_slots[i].item_id = data["hotbar"][i].get("id", "")
            hotbar_slots[i].count = data["hotbar"][i].get("count", 0)
    
    if data.has("main"):
        for i in min(data["main"].size(), main_slots.size()):
            main_slots[i].item_id = data["main"][i].get("id", "")
            main_slots[i].count = data["main"][i].get("count", 0)
    
    if data.has("selected"):
        selected_hotbar = data["selected"]
```

### 5.2 SlotData Class

**File: `features/inventory/slot_data.gd`**

```gdscript
extends RefCounted
class_name SlotData

var item_id: String = ""
var count: int = 0

func is_empty() -> bool:
    return item_id.is_empty() or count <= 0

func can_stack(other_id: String, max_stack: int) -> bool:
    if is_empty():
        return false
    return item_id == other_id and count < max_stack

func clear() -> void:
    item_id = ""
    count = 0
```

---

## Phase 6: First-Person Feature

### 6.1 First-Person Feature Coordinator

**File: `features/first_person/first_person_feature.gd`**

```gdscript
extends FeatureBase
class_name FirstPersonFeature

var current_view: FirstPersonView  # Abstract base for arms/pistol/axe

## View instances
var views: Dictionary = {}  # item_id -> FirstPersonView

func _ready() -> void:
    # Pre-instantiate views
    views["fists"] = $Views/Arms
    views["heavy_pistol"] = $Views/Pistol
    views["axe_stone"] = $Views/Axe
    
    # Connect to inventory selection changes
    var inventory = FeatureRegistry.get_feature("inventory") as InventoryFeature
    if inventory:
        inventory.selection_changed.connect(_on_selection_changed)
    
    FeatureRegistry.register(self, "first_person")

func _on_selection_changed(index: int) -> void:
    var inventory = FeatureRegistry.get_feature("inventory") as InventoryFeature
    var item = inventory.get_hotbar_item(index)
    
    _switch_to_view(item.id if item else "fists")

func _switch_to_view(item_id: String) -> void:
    # Hide current
    if current_view:
        current_view.deactivate()
    
    # Show new
    current_view = views.get(item_id, views["fists"])
    if current_view:
        current_view.activate()
```

### 6.2 Pistol Assets (Moved to Feature)

**Move from:** `models/pistol/`
**Move to:** `features/first_person/pistol/`

Files to move:
- `heavy_pistol_animated.glb`
- `heavy_pistol_animated_*.png` (textures)
- `heavy_pistol_physics.tscn`
- `heavy_pistol_without_hands.tscn`

Create new:
- `fp_pistol.gd` (from `components/first_person_pistol.gd`)
- `fp_pistol.tscn`

---

## Phase 7: Combat Feature

### 7.1 Combat Feature

**File: `features/combat/combat_feature.gd`**

Extracts from mode_play.gd:
- `_do_punch()` (lines 330-493)
- `_do_tool_attack()` (lines 566-731)
- `_do_pistol_fire()` (lines 263-304)
- `_spawn_pistol_hit_effect()` (lines 305-328)
- `_find_damageable()` (lines 512-531)
- Animation sync signals

**Signals to handle:**
- `punch_triggered`, `punch_ready`
- `pistol_fired`, `pistol_fire_ready`, `pistol_reload`
- `axe_fired`, `axe_ready`
- `damage_dealt`

---

## Phase 8: Mining Feature

### 8.1 Mining Feature

**File: `features/mining/mining_feature.gd`**

Extracts from mode_play.gd:
- Terrain damage tracking (`terrain_damage`, `TERRAIN_HP`)
- Block damage tracking (`block_damage`, `BLOCK_HP`)
- Object damage tracking (`object_damage`, `OBJECT_HP`)
- Tree damage tracking (`tree_damage`, `TREE_HP`)
- `_check_durability_target()`
- Durability signals

### 8.2 Durability Tracker

**File: `features/mining/durability_tracker.gd`**

```gdscript
extends RefCounted
class_name DurabilityTracker

## Tracks damage dealt to various targets
## Key types: RID (objects), Vector3i (blocks/terrain)

var damage_map: Dictionary = {}  # Variant -> int

func add_damage(key: Variant, amount: int) -> int:
    damage_map[key] = damage_map.get(key, 0) + amount
    return damage_map[key]

func get_damage(key: Variant) -> int:
    return damage_map.get(key, 0)

func clear(key: Variant) -> void:
    damage_map.erase(key)

func get_save_data() -> Dictionary:
    # Convert keys to saveable format
    var data = {}
    for key in damage_map:
        if key is Vector3i:
            data["v3i:%d,%d,%d" % [key.x, key.y, key.z]] = damage_map[key]
        # Skip RID keys (runtime only, not persistable)
    return data

func load_save_data(data: Dictionary) -> void:
    damage_map.clear()
    for key_str in data:
        if key_str.begins_with("v3i:"):
            var parts = key_str.substr(4).split(",")
            var v = Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
            damage_map[v] = data[key_str]
```

---

## Phase 9: Grabbing Feature

### 9.1 Grabbing Feature

**File: `features/grabbing/grabbing_feature.gd`**

Extracts from mode_play.gd:
- `_try_grab_prop()` (lines 933-993)
- `_grab_dropped_prop()` (lines 994-1019)
- `_drop_grabbed_prop()` (lines 1020-1122)
- `_get_pickup_target()` (lines 874-931)
- `_update_held_prop()` (lines 847-873)
- `_enable/disable_preview_collisions()` (lines 1125-1143)
- `is_grabbing_prop()` (lines 1145-1146)
- Held prop state (`held_prop_instance`, `held_prop_id`, `held_prop_rotation`)

**Input handling:** T key (or hold E in v2)

---

## Phase 10: Interaction Feature

### 10.1 Interaction Feature

**File: `features/interaction/interaction_feature.gd`**

Extracts from player_interaction.gd:
- E key handling
- Door interaction
- Vehicle interaction
- Barricade interaction
- Pickup interaction

### 10.2 Interaction Handlers

```
features/interaction/handlers/
├── door_handler.gd
├── vehicle_handler.gd
├── barricade_handler.gd
└── pickup_handler.gd
```

Each handler implements:
```gdscript
func can_interact(target: Node) -> bool
func get_prompt(target: Node) -> String
func do_interact(target: Node) -> void
```

---

## Phase 11: Modes

### 11.1 Thin Mode Layer

**File: `features/modes/mode_manager.gd`**

Modes become routing only:
- PLAY mode → routes to Combat, Mining, Grabbing, Interaction
- BUILD mode → routes to Building API
- EDITOR mode → routes to Terrain editing

mode_play.gd shrinks from 1533 lines to ~100 lines.

---

## Phase 12: Save/Load

### 12.1 Save API

**File: `api/save_api.gd`**

```gdscript
extends Node

func save_player() -> Dictionary:
    return FeatureRegistry.collect_save_data()

func load_player(data: Dictionary) -> void:
    FeatureRegistry.apply_save_data(data)

func save_to_file(path: String) -> void:
    var data = save_player()
    var file = FileAccess.open(path, FileAccess.WRITE)
    file.store_var(data)
    file.close()

func load_from_file(path: String) -> void:
    if not FileAccess.file_exists(path):
        return
    var file = FileAccess.open(path, FileAccess.READ)
    var data = file.get_var()
    file.close()
    load_player(data)
```

---

## Phase 13: Migration & Testing

### 13.1 Parallel Operation

1. Keep `world_player` functional during development
2. Create `world_player_v2` alongside
3. Add scene switch (F12?) to toggle between v1 and v2
4. Test each feature incrementally

### 13.2 Testing Checklist

**Movement:**
- [ ] WASD movement
- [ ] Sprint with Shift
- [ ] Jump (Space)
- [ ] Swimming
- [ ] Footstep sounds

**Inventory:**
- [ ] Hotbar selection (1-0 keys)
- [ ] Item stacking
- [ ] Drop item (G key)
- [ ] Inventory panel (I key)

**First Person:**
- [ ] Arms visibility (fists)
- [ ] Pistol visibility + animations
- [ ] Axe visibility + animations

**Combat:**
- [ ] Punch damage
- [ ] Tool damage
- [ ] Pistol shooting
- [ ] Animation sync

**Mining:**
- [ ] Terrain breaking
- [ ] Block breaking
- [ ] Durability UI
- [ ] Resource collection

**Grabbing:**
- [ ] T key grab
- [ ] Prop follows camera
- [ ] T release drops prop
- [ ] Works on dropped items

**Interaction:**
- [ ] E key pickup
- [ ] Door open/close
- [ ] Vehicle enter/exit

**Save/Load:**
- [ ] Position saves
- [ ] Inventory saves
- [ ] Damage progress saves
- [ ] Load restores all state

---

## Estimated Timeline

| Phase | Effort | Dependencies |
|-------|--------|--------------|
| 1. Foundation | 1 day | None |
| 2. Registries | 1 day | Phase 1 |
| 3. Core Player | 1 day | Phase 2 |
| 4. Movement | 2 days | Phase 3 |
| 5. Inventory | 2 days | Phase 2 |
| 6. First-Person | 2 days | Phase 5 |
| 7. Combat | 2 days | Phase 4,6 |
| 8. Mining | 2 days | Phase 7 |
| 9. Grabbing | 1 day | Phase 3 |
| 10. Interaction | 1 day | Phase 5,9 |
| 11. Modes | 1 day | All features |
| 12. Save/Load | 1 day | All features |
| 13. Testing | 2 days | All phases |

**Total: ~19 days**

---

## Appendix A: Complete V1 Audit

### A.1 All V1 Files (Complete Inventory)

| V1 Path | Lines | Purpose | V2 Destination | Status |
|---------|-------|---------|----------------|--------|
| **Core** |
| `player.gd` | 60 | Thin coordinator | `core/player.gd` | 🔲 |
| `player.tscn` | 92 | Scene structure | `core/player.tscn` | 🔲 |
| **Components (7 files)** |
| `components/player_movement.gd` | 190 | Walk, sprint, jump, swim | `features/movement/` | 🔲 |
| `components/player_camera.gd` | 150 | Camera control, raycast | `core/player_camera.gd` | 🔲 |
| `components/player_interaction.gd` | 397 | E key, doors, vehicles | `features/interaction/` | 🔲 |
| `components/player_combat.gd` | 100 | Health/damage interface | `features/combat/` | 🔲 |
| `components/first_person_arms.gd` | 240 | Fist visuals | `features/first_person/arms/` | 🔲 |
| `components/first_person_pistol.gd` | 290 | Pistol visuals | `features/first_person/pistol/` | 🔲 |
| `components/first_person_axe.gd` | 210 | Axe visuals | `features/first_person/axe/` | 🔲 |
| **Systems (3 files)** |
| `systems/hotbar.gd` | 320 | Hotbar slots | `features/inventory/` | 🔲 |
| `systems/inventory.gd` | 150 | Main inventory | `features/inventory/` | 🔲 |
| `systems/item_use_router.gd` | 120 | Routes LMB/RMB | `features/modes/input_router.gd` | 🔲 |
| **Modes (4 files)** |
| `modes/mode_manager.gd` | 170 | Mode switching | `features/modes/mode_manager.gd` | 🔲 |
| `modes/mode_play.gd` | 1533 | Combat, mining, grab | Split to features | 🔲 |
| `modes/mode_build.gd` | 400 | Block/object placement | `features/modes/mode_build.gd` | 🔲 |
| `modes/mode_editor.gd` | 350 | Terrain editing | `features/modes/mode_editor.gd` | 🔲 |
| **UI (5 files)** |
| `ui/player_hud.gd` | 622 | HUD display | `features/hud/player_hud.gd` | 🔲 |
| `ui/player_hud.tscn` | 140 | HUD scene | `features/hud/player_hud.tscn` | 🔲 |
| `ui/inventory_panel.gd` | 200 | Inventory UI | `features/inventory/ui/` | 🔲 |
| `ui/inventory_slot.gd` | 130 | Slot UI | `features/inventory/ui/` | 🔲 |
| `ui/inventory_*.tscn` | - | UI scenes | `features/inventory/ui/` | 🔲 |
| **Autoloads (2 files)** |
| `autoload/player_signals.gd` | 55 | Signal hub | `signals/player_signals.gd` | 🔲 |
| `autoload/player_stats.gd` | 67 | Health/stamina | `features/stats/player_stats.gd` | 🔲 |
| **API (2 files)** |
| `api/building_api.gd` | 750 | Building system API | `api/building_api.gd` | 🔲 |
| `api/terrain_api.gd` | 200 | Terrain API | `api/terrain_api.gd` | 🔲 |
| **Data (1 file)** |
| `data/item_definitions.gd` | 216 | Item dictionaries | `data/items/*.tres` | 🔲 |
| **Pickups (2 files)** |
| `pickups/pickup_item.gd` | 220 | Physics pickup | `features/interaction/pickup_item.gd` | 🔲 |
| `pickups/pickup_item.tscn` | - | Pickup scene | `features/interaction/pickup_item.tscn` | 🔲 |
| **Utils (1 file)** |
| `utils/debug_draw.gd` | 50 | Debug visualization | `utils/debug_draw.gd` | 🔲 |

### A.2 External Dependencies

| External Resource | Location | V2 Action |
|-------------------|----------|-----------|
| Pistol model | `models/pistol/heavy_pistol_animated.glb` | Copy to `features/first_person/pistol/` |
| Pistol textures | `models/pistol/heavy_pistol_animated_*.png` | Copy to `features/first_person/pistol/` |
| Pistol physics scene | `models/pistol/heavy_pistol_physics.tscn` | Recreate in feature |
| Footstep sounds | `sound/st1-footstep-sfx-*.mp3` | Reference from `features/movement/sounds/` |
| Door model | `models/door/` | Referenced by interaction feature |
| Arm animations | Various | Embedded in first_person feature |

### A.3 Player Signals Audit (23 signals)

All signals must be preserved for v2 compatibility:

| Signal | Current Emitters | V2 Feature |
|--------|------------------|------------|
| `item_used` | - | inventory |
| `item_changed` | hotbar | inventory |
| `hotbar_slot_selected` | hotbar | inventory |
| `mode_changed` | mode_manager | modes |
| `editor_submode_changed` | mode_manager | modes |
| `damage_dealt` | mode_play | combat |
| `damage_received` | player_stats | stats |
| `punch_triggered` | mode_play | combat |
| `punch_ready` | first_person_arms | first_person |
| `player_died` | player_stats | stats |
| `pistol_fired` | mode_play | combat |
| `pistol_fire_ready` | first_person_pistol | first_person |
| `pistol_reload` | first_person_pistol | first_person |
| `axe_fired` | mode_play | combat |
| `axe_ready` | first_person_axe | first_person |
| `interaction_available` | player_interaction | interaction |
| `interaction_unavailable` | player_interaction | interaction |
| `interaction_performed` | player_interaction | interaction |
| `durability_hit` | mode_play | mining |
| `durability_cleared` | mode_play | mining |
| `inventory_changed` | hotbar, inventory | inventory |
| `inventory_toggled` | player_hud | hud |
| `game_menu_toggled` | player_hud | hud |
| `target_material_changed` | mode_play | mining |
| `player_jumped` | player_movement | movement |
| `player_landed` | player_movement | movement |
| `underwater_toggled` | player_movement | movement |
| `camera_underwater_toggled` | player_camera | movement |

### A.4 Input Actions Required

| Action | Key | Used By |
|--------|-----|---------|
| `move_forward` | W | movement |
| `move_backward` | S | movement |
| `move_left` | A | movement |
| `move_right` | D | movement |
| `sprint` | Shift | movement |
| `ui_accept` | Space | movement (jump) |
| 1-0 keys | - | inventory (hotbar) |
| G | - | inventory (drop) |
| I | - | inventory (toggle) |
| E | - | interaction |
| T | - | grabbing |
| LMB | - | combat/modes |
| RMB | - | modes |
| Escape | - | HUD (menu) |

### A.5 External Manager Dependencies

V2 player must still interface with these external systems:

| Manager | Group Name | Methods Used |
|---------|------------|--------------|
| TerrainManager | `terrain_manager` | `modify_terrain()`, `get_water_density()`, `get_material_at()` |
| BuildingManager | `building_manager` | `set_voxel()`, `get_voxel()`, `place_object()` |
| VegetationManager | `vegetation_manager` | `chop_tree_by_collider()`, `harvest_grass_by_collider()` |
| ObjectRegistry | autoload | `get_object()` |

### A.6 Collision Layers

| Layer | Bit | Used For |
|-------|-----|----------|
| 1 | Terrain | Player collides with ground |
| 2 | Player | Player body |
| 3 | Buildings | Player collides with voxel buildings |
| 4 | Water | Used for water detection (not collision) |
| 8 | Entities | Zombies, NPCs |

Player collision settings:
- `collision_layer = 3` (bits 1+2)
- `collision_mask = 137` (bits 1, 4, 8, 128)

---

## Appendix B: V1 → V2 API Compatibility

### B.1 WorldPlayer Public API

The following methods must exist on `WorldPlayerV2` for drop-in replacement:

```gdscript
# Must implement (used by external systems)
func get_look_direction() -> Vector3
func get_camera_position() -> Vector3
func raycast(distance: float, mask: int, areas: bool, exclude_water: bool) -> Dictionary
func take_damage(amount: int, source: Node)
func heal(amount: int)

# Properties (accessed by external systems)
var terrain_manager: Node
var building_manager: Node
var vegetation_manager: Node
```

### B.2 Autoload Requirements

These autoloads must remain registered in `project.godot`:

```ini
[autoload]
PlayerSignals="*res://modules/world_player_v2/signals/player_signals.gd"
PlayerStats="*res://modules/world_player_v2/features/stats/player_stats.gd"
# ItemRegistry and FeatureRegistry are NEW autoloads for v2
ItemRegistry="*res://modules/world_player_v2/registries/item_registry.gd"
FeatureRegistry="*res://modules/world_player_v2/registries/feature_registry.gd"
```

### B.3 Scene Swap Procedure

To swap v1 for v2 in a scene:

1. Change player scene path in `main_game_scene.tscn`
2. Update autoload paths in `project.godot`
3. Keep same node name ("WorldPlayer" or update all references)
4. Verify groups: player must be in `player` group

---

## Appendix C: Validation Checklist

Before declaring v2 complete, verify:

### C.1 Functional Parity
- [ ] All 23 signals emit correctly
- [ ] All input actions work
- [ ] All manager integrations work
- [ ] Collision layers match v1

### C.2 Save/Load
- [ ] Player position saves/loads
- [ ] Inventory contents save/load (by ID)
- [ ] Health/stamina save/load
- [ ] Mode state saves/loads

### C.3 External Integration
- [ ] Zombies can damage player
- [ ] Player can damage zombies
- [ ] Terrain digging works
- [ ] Building placement works
- [ ] Vegetation harvesting works
- [ ] Doors open/close
- [ ] Vehicles work (if implemented)

### C.4 Visual Parity
- [ ] First-person arms visible
- [ ] First-person pistol visible
- [ ] First-person axe visible
- [ ] HUD displays correctly
- [ ] Underwater overlay works
- [ ] Durability bar works

