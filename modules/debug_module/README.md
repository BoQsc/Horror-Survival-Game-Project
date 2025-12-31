# Debug Module

Resource-based debug configuration system with saveable presets.

## Usage

1. **Select a preset**: In editor, assign a preset to `DebugManager.current_preset`
2. **Toggle at runtime**: Modify `DebugManager.current_preset` properties
3. **Create custom presets**: Right-click `presets/` → New Resource → DebugPreset

## Presets

- `default.tres` - All OFF (production)
- `terrain_inspection.tres` - Yellow marker + material UI
- `vegetation_debug.tres` - Collision shapes visible

## Files

- `debug_preset.gd` - Resource class definition
- `debug_manager.gd` - Autoload that reads/applies presets
- `presets/` - Saveable .tres preset files
