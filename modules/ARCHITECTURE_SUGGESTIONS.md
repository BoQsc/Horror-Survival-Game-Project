# Game Architecture - Complete Design Document

A future-proof, modular architecture for a survival/sandbox/story game.

---

## Core Principles

1. **Organize by Feature** - Group by meaning, not file type
2. **Self-Contained Modules** - Each folder has everything it needs
3. **Signals for Communication** - Decoupled components
4. **Custom Resources for Data** - Items, recipes, stats as Resources
5. **Autoloads for Global Access** - Game manager, event bus, save system

---

## Master Structure

```
game/
│
├── player/                          # Everything about the player
│   │
│   ├── body/                       # Physical player
│   │   ├── player.gd              # Main CharacterBody3D script
│   │   ├── player.tscn            # Player scene
│   │   ├── camera.gd              # Mouse look, raycasting
│   │   ├── movement.gd            # Walk, sprint, jump, swim, climb
│   │   ├── footsteps.gd           # Footstep sounds
│   │   └── arms/                  # Default fist visuals
│   │       ├── arms.gd
│   │       ├── arms.tscn
│   │       └── arms.glb
│   │
│   ├── stats/                      # Player state
│   │   ├── health.gd              # HP, damage, death
│   │   ├── hunger.gd              # Food need
│   │   ├── thirst.gd              # Water need
│   │   ├── stamina.gd             # Energy
│   │   ├── temperature.gd         # Hot/cold
│   │   └── effects.gd             # Buffs, debuffs, poison, bleeding
│   │
│   ├── skills/                     # Progression
│   │   ├── skill_tree.gd          # Unlockable abilities
│   │   ├── experience.gd          # XP, levels
│   │   └── perks.gd               # Passive bonuses
│   │
│   ├── items/                      # What player holds and uses
│   │   │
│   │   ├── inventory/             # Storage system
│   │   │   ├── inventory.gd       # Manager
│   │   │   ├── slot.gd            # Single slot logic
│   │   │   └── ui/
│   │   │       ├── hotbar.tscn
│   │   │       ├── hotbar_slot.tscn
│   │   │       ├── inventory_panel.tscn
│   │   │       └── inventory_slot.tscn
│   │   │
│   │   ├── weapons/               # Combat items
│   │   │   ├── pistol/
│   │   │   │   ├── pistol.gd      # Item data + behavior
│   │   │   │   ├── pistol_fp.gd   # First-person view
│   │   │   │   ├── pistol.tscn    # Scene
│   │   │   │   ├── pistol.glb     # Model
│   │   │   │   └── sounds/
│   │   │   ├── rifle/
│   │   │   ├── shotgun/
│   │   │   └── melee/
│   │   │       ├── axe/
│   │   │       ├── knife/
│   │   │       └── sword/
│   │   │
│   │   ├── tools/                 # Utility items
│   │   │   ├── pickaxe/
│   │   │   ├── hammer/
│   │   │   ├── fishing_rod/
│   │   │   └── flashlight/
│   │   │
│   │   ├── consumables/           # Food, medicine
│   │   │   ├── food/
│   │   │   ├── drinks/
│   │   │   └── medicine/
│   │   │
│   │   └── resources/             # Crafting materials
│   │       ├── stone.gd
│   │       ├── wood.gd
│   │       ├── metal.gd
│   │       └── cloth.gd
│   │
│   ├── actions/                    # What player does
│   │   ├── combat.gd              # Attack, shoot, reload
│   │   ├── mining.gd              # Break terrain, trees, blocks
│   │   ├── durability.gd          # Target HP tracking
│   │   ├── interaction.gd         # E key - doors, NPCs, pickups
│   │   ├── grabbing.gd            # T key - physics props
│   │   ├── placement.gd           # Place blocks, resources
│   │   ├── crafting.gd            # Make items
│   │   ├── farming.gd             # Plant, water, harvest
│   │   ├── fishing.gd             # Fishing minigame
│   │   ├── trading.gd             # Buy/sell with NPCs
│   │   └── driving.gd             # Vehicle control
│   │
│   ├── exploration/                # World discovery
│   │   ├── map.gd                 # World map, fog of war
│   │   ├── markers.gd             # Points of interest
│   │   ├── compass.gd             # Direction indicator
│   │   └── discoveries.gd         # Found locations
│   │
│   ├── modes/                      # Game mode behavior
│   │   ├── mode_manager.gd        # Mode switching
│   │   ├── play/                  # PLAY mode
│   │   │   └── play.gd
│   │   ├── build/                 # BUILD mode
│   │   │   ├── build.gd
│   │   │   └── preview.gd
│   │   └── editor/                # EDITOR mode
│   │       ├── editor.gd
│   │       └── fly.gd
│   │
│   └── hud/                        # Player UI overlay
│       ├── hud.gd
│       ├── hud.tscn
│       ├── crosshair.gd
│       ├── prompts.gd             # "Press E to..."
│       └── notifications.gd       # Pop-up messages
│
├── world/                           # The environment
│   │
│   ├── terrain/                    # Voxel terrain system
│   │   ├── chunk_manager.gd
│   │   ├── density/               # Density generation
│   │   ├── meshing/               # Mesh generation
│   │   ├── collision/             # Collision generation
│   │   └── materials/             # Terrain textures
│   │
│   ├── water/                      # Water system
│   │   ├── water_manager.gd
│   │   ├── ocean/
│   │   ├── rivers/
│   │   └── lakes/
│   │
│   ├── weather/                    # Weather system
│   │   ├── weather_manager.gd
│   │   ├── rain/
│   │   ├── snow/
│   │   ├── fog/
│   │   ├── storms/
│   │   └── wind/
│   │
│   ├── time/                       # Day/night, seasons
│   │   ├── time_manager.gd
│   │   ├── day_night.gd
│   │   ├── seasons.gd
│   │   └── sky/
│   │       ├── sky.gd
│   │       └── skybox/
│   │
│   ├── biomes/                     # World areas
│   │   ├── biome_manager.gd
│   │   ├── forest/
│   │   ├── desert/
│   │   ├── snow/
│   │   ├── swamp/
│   │   └── beach/
│   │
│   ├── dungeons/                   # Generated structures
│   │   ├── dungeon_generator.gd
│   │   ├── caves/
│   │   ├── ruins/
│   │   └── bunkers/
│   │
│   ├── vegetation/                 # Plants
│   │   ├── vegetation_manager.gd
│   │   ├── trees/
│   │   ├── grass/
│   │   ├── bushes/
│   │   └── crops/
│   │
│   └── destruction/                # Breakable environment
│       ├── destruction.gd
│       └── debris/
│
├── entities/                        # Living things (not player)
│   │
│   ├── enemies/                    # Hostile
│   │   ├── spawner.gd
│   │   ├── zombies/
│   │   │   ├── zombie.gd
│   │   │   ├── zombie.tscn
│   │   │   ├── ai/
│   │   │   └── variants/
│   │   ├── mutants/
│   │   └── bosses/
│   │       ├── boss_manager.gd
│   │       └── boss_types/
│   │
│   ├── animals/                    # Wildlife
│   │   ├── passive/               # Deer, rabbits
│   │   ├── hostile/               # Wolves, bears
│   │   └── tameable/              # Dogs, horses
│   │
│   ├── npcs/                       # Non-hostile humans
│   │   ├── npc_base.gd
│   │   ├── merchants/
│   │   ├── quest_givers/
│   │   ├── survivors/
│   │   └── dialogue/
│   │
│   └── companions/                 # Followers
│       ├── companion_manager.gd
│       ├── pets/
│       ├── allies/
│       └── ai/
│
├── buildings/                       # Construction system
│   │
│   ├── building_manager.gd
│   │
│   ├── blocks/                     # Building blocks
│   │   ├── block_manager.gd
│   │   ├── wall/
│   │   ├── floor/
│   │   ├── roof/
│   │   ├── stairs/
│   │   └── ramps/
│   │
│   ├── objects/                    # Placeable objects
│   │   ├── doors/
│   │   ├── windows/
│   │   ├── furniture/
│   │   ├── storage/               # Chests, containers
│   │   └── decorations/
│   │
│   ├── electricity/                # Power system
│   │   ├── power_manager.gd
│   │   ├── generators/
│   │   ├── wires/
│   │   ├── switches/
│   │   └── lights/
│   │
│   ├── plumbing/                   # Water pipes
│   │   ├── pipe_manager.gd
│   │   ├── pumps/
│   │   └── irrigation/
│   │
│   ├── traps/                      # Defense
│   │   ├── spikes/
│   │   ├── turrets/
│   │   └── alarms/
│   │
│   └── blueprints/                 # Saved structures
│       ├── blueprint_manager.gd
│       └── prefabs/
│
├── vehicles/                        # Transportation
│   │
│   ├── vehicle_manager.gd
│   │
│   ├── land/
│   │   ├── car/
│   │   ├── truck/
│   │   ├── motorcycle/
│   │   └── bicycle/
│   │
│   ├── water/
│   │   ├── boat/
│   │   └── raft/
│   │
│   ├── air/
│   │   └── helicopter/
│   │
│   └── fuel/
│       ├── fuel_system.gd
│       └── gas_stations/
│
├── story/                           # Narrative content
│   │
│   ├── quests/
│   │   ├── quest_manager.gd
│   │   ├── main_story/
│   │   ├── side_quests/
│   │   └── daily_quests/
│   │
│   ├── dialogue/
│   │   ├── dialogue_manager.gd
│   │   └── conversations/
│   │
│   ├── lore/
│   │   ├── notes/                 # Collectible documents
│   │   ├── audio_logs/
│   │   └── terminals/
│   │
│   ├── cinematics/
│   │   ├── cutscene_manager.gd
│   │   └── scenes/
│   │
│   └── events/
│       ├── event_manager.gd
│       ├── raids/                 # Base defense waves
│       ├── airdrops/
│       └── world_events/
│
├── crafting/                        # Item creation system
│   │
│   ├── crafting_manager.gd
│   │
│   ├── recipes/
│   │   ├── recipe.gd             # Base recipe resource
│   │   ├── weapons/
│   │   ├── tools/
│   │   ├── building/
│   │   ├── food/
│   │   └── medicine/
│   │
│   ├── stations/
│   │   ├── workbench/
│   │   ├── forge/
│   │   ├── chemistry/
│   │   ├── kitchen/
│   │   └── sewing/
│   │
│   └── ui/
│       └── crafting_panel.tscn
│
├── multiplayer/                     # Online features
│   │
│   ├── networking/
│   │   ├── network_manager.gd
│   │   ├── client.gd
│   │   └── server.gd
│   │
│   ├── sync/
│   │   ├── player_sync.gd
│   │   ├── world_sync.gd
│   │   └── entity_sync.gd
│   │
│   ├── lobby/
│   │   ├── lobby_manager.gd
│   │   └── matchmaking.gd
│   │
│   ├── coop/
│   │   ├── coop_manager.gd
│   │   └── shared_inventory.gd
│   │
│   └── pvp/
│       ├── pvp_manager.gd
│       └── damage_rules.gd
│
├── ui/                              # Global UI (not player HUD)
│   │
│   ├── main_menu/
│   │   ├── main_menu.gd
│   │   └── main_menu.tscn
│   │
│   ├── pause_menu/
│   │   ├── pause_menu.gd
│   │   └── pause_menu.tscn
│   │
│   ├── settings/
│   │   ├── settings.gd
│   │   ├── video_settings.tscn
│   │   ├── audio_settings.tscn
│   │   ├── controls_settings.tscn
│   │   └── gameplay_settings.tscn
│   │
│   ├── loading/
│   │   ├── loading_screen.gd
│   │   └── loading_screen.tscn
│   │
│   ├── death_screen/
│   │   └── death_screen.tscn
│   │
│   ├── photo_mode/
│   │   └── photo_mode.gd
│   │
│   ├── tutorial/
│   │   ├── tutorial_manager.gd
│   │   └── tips/
│   │
│   └── themes/
│       └── default_theme.tres
│
├── audio/                           # Sound system
│   │
│   ├── audio_manager.gd
│   │
│   ├── music/
│   │   ├── main_menu/
│   │   ├── gameplay/
│   │   ├── combat/
│   │   └── ambient/
│   │
│   ├── ambience/
│   │   ├── forest/
│   │   ├── cave/
│   │   ├── rain/
│   │   └── night/
│   │
│   ├── sfx/
│   │   ├── footsteps/
│   │   ├── weapons/
│   │   ├── ui/
│   │   └── impacts/
│   │
│   └── voice/
│       ├── player/
│       └── npcs/
│
├── save/                            # Persistence
│   │
│   ├── save_manager.gd
│   │
│   ├── serializers/
│   │   ├── player_serializer.gd
│   │   ├── world_serializer.gd
│   │   ├── building_serializer.gd
│   │   └── entity_serializer.gd
│   │
│   └── cloud/
│       └── cloud_save.gd
│
├── input/                           # Controls
│   │
│   ├── input_manager.gd
│   ├── keyboard.gd
│   ├── controller.gd
│   ├── touch.gd
│   └── rebinding.gd
│
├── accessibility/                   # Inclusive features
│   │
│   ├── accessibility_manager.gd
│   ├── colorblind/
│   ├── subtitles/
│   ├── text_size/
│   └── difficulty/
│
├── localization/                    # Languages
│   │
│   ├── localization_manager.gd
│   ├── en/
│   ├── es/
│   ├── fr/
│   ├── de/
│   └── ...
│
├── performance/                     # Optimization
│   │
│   ├── lod/
│   │   └── lod_manager.gd
│   │
│   ├── streaming/
│   │   └── chunk_streaming.gd
│   │
│   └── pooling/
│       └── object_pool.gd
│
├── mods/                            # Mod support
│   │
│   ├── mod_loader.gd
│   ├── mod_api.gd
│   └── installed/
│
├── debug/                           # Development tools
│   │
│   ├── debug_menu.gd
│   ├── console.gd
│   ├── teleporter.gd
│   └── item_spawner.gd
│
└── autoloads/                       # Global singletons
    │
    ├── game_manager.gd            # Game state, scene transitions
    ├── event_bus.gd               # Global signal hub
    ├── player_signals.gd          # Player-specific signals
    ├── debug_settings.gd          # Debug toggles
    └── config.gd                  # Game configuration
```

---

## Key Architectural Patterns

### 1. Signals for Decoupling
```gdscript
# autoloads/event_bus.gd
signal player_died
signal item_picked_up(item_id: String)
signal quest_completed(quest_id: String)

# Usage anywhere:
EventBus.player_died.emit()
EventBus.item_picked_up.connect(_on_item_picked_up)
```

### 2. Custom Resources for Data
```gdscript
# player/items/weapons/weapon_data.gd
class_name WeaponData extends Resource

@export var id: String
@export var name: String
@export var damage: int
@export var fire_rate: float
@export var ammo_type: String
@export var model: PackedScene
@export var sounds: Dictionary
```

### 3. Self-Contained Features
Each folder contains:
- Scripts (`.gd`)
- Scenes (`.tscn`)
- Models (`.glb`)
- Textures (`.png`)
- Sounds (`.mp3`, `.wav`)
- UI (subfolder)

### 4. Autoloads for Global Access
```gdscript
# project.godot
[autoload]
GameManager="*res://game/autoloads/game_manager.gd"
EventBus="*res://game/autoloads/event_bus.gd"
PlayerSignals="*res://game/autoloads/player_signals.gd"
DebugSettings="*res://game/autoloads/debug_settings.gd"
```

---

## Migration Strategy

1. **Start with what exists** - Don't delete working code
2. **Move one feature at a time** - Complete each before starting next
3. **Test after each move** - Verify functionality
4. **Update references** - Fix paths as you go
5. **Delete old code only after new works** - Never lose functionality

---

## Future Expansion

This structure supports adding:
- New weapons → `player/items/weapons/new_weapon/`
- New enemies → `entities/enemies/new_enemy/`
- New biomes → `world/biomes/new_biome/`
- New vehicles → `vehicles/land|water|air/new_vehicle/`
- New quest lines → `story/quests/new_questline/`

Each addition is isolated and doesn't affect existing code.
