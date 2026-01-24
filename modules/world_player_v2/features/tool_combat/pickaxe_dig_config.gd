extends Node
## PickaxeDigConfig - Global configuration for enhanced pickaxe digging mode
## Autoload singleton that stores pickaxe digging mode state

## When enabled, pickaxes use blocky grid-snapped terrain removal (like editor mode)
## with block durability requiring multiple hits.
## When disabled, pickaxes use sphere-based instant terrain removal.
var enabled: bool = true

## Attack cooldown in seconds (time between swings)
## Range: 0.1 - 1.0, Default: 0.3
var attack_cooldown: float = 0.3

## Mining radius for terrain removal
## Range: 0.5 - 3.0, Default: 1.0
var mining_radius: float = 1.0
