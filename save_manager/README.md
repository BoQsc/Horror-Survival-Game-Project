# Save Manager Documentation

The `save_manager.gd` autoload singleton handles all game state persistence.

## Quick Reference

| Action | Key |
|--------|-----|
| **Quick Save** | F5 |
| **Quick Load** | F8 |
| **Auto-save** | On game exit |

## Save File Location

```
%APPDATA%/Godot/app_userdata/GPUMarchingCubes/saves/
```

- `quicksave.json` - F5 quick save
- `autosave.json` - Auto-save on exit

## What Gets Saved

| Data | Source | Description |
|------|--------|-------------|
| Player | `character_body_3d.gd` | Position, rotation, fly mode |
| Terrain | `chunk_manager.gd` | All digs, fills, material edits |
| Buildings | `building_manager.gd` | Voxel blocks + placed objects |
| Vegetation | `vegetation_manager.gd` | Chopped trees, removed/placed grass & rocks |
| Roads | `road_manager.gd` | Player-placed road segments |
| Prefabs | `prefab_spawner.gd` | Which prefabs have been spawned |
| Entities | `entity_manager.gd` | Entity positions and types |
| Doors | `interactive_door.gd` | Open/closed state |

## Save File Format (JSON)

```json
{
  "version": 1,
  "timestamp": "2024-12-16T22:00:00",
  "game_seed": 12345,
  "player": { "position": [x,y,z], "rotation": [x,y,z], "is_flying": false },
  "terrain_modifications": { "0,0,0": [...modifications...] },
  "buildings": { "0,0,0": { "voxels": "base64...", "objects": [...] } },
  "vegetation": { "chopped_trees": [...], "removed_grass": [...] },
  "roads": { "segments": [...] },
  "prefabs": { "spawned_positions": [...] },
  "entities": { "entities": [...] },
  "doors": { "doors": [{ "position": [x,y,z], "is_open": true }] }
}
```

## API

```gdscript
# Quick save/load
SaveManager.quick_save()
SaveManager.quick_load()

# Manual save/load
SaveManager.save_game("user://saves/mysave.json")
SaveManager.load_game("user://saves/mysave.json")

# List available saves
var saves = SaveManager.get_save_files()

# Signals
SaveManager.save_completed.connect(func(success, path): ...)
SaveManager.load_completed.connect(func(success, path): ...)
```

## Adding New Saveable Data

1. Add a manager reference in `_find_managers()`
2. Add a `_get_*_data()` function to serialize
3. Add the data to `save_data` dict in `save_game()`
4. Add a `_load_*_data()` function to deserialize
5. Call the loader in `load_game()`

Or implement `get_save_data()` and `load_save_data()` in your manager and call those.
