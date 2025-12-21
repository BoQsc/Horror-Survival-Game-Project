# World Player Modes

This directory contains mode-specific behavior scripts.

## Files (planned)

- `mode_manager.gd` - Tracks current mode, handles transitions
- `mode_play.gd` - PLAY mode: combat, mining, harvesting
- `mode_build.gd` - BUILD mode: blocks, objects, props
- `mode_editor.gd` - EDITOR mode: terrain sculpting, prefabs, fly

## Mode System

- **PLAY**: Default gameplay mode, item-driven behavior
- **BUILD**: Triggered by holding building items (blocks, objects, props)
- **EDITOR**: Hidden creative mode, toggled with backtick (`)
