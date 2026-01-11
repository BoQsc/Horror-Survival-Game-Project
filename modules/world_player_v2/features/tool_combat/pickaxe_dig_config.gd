extends Node
## PickaxeDigConfig - Global configuration for enhanced pickaxe digging mode
## Autoload singleton that stores pickaxe digging mode state

## When enabled, pickaxes use blocky grid-snapped terrain removal (like editor mode)
## with block durability requiring multiple hits.
## When disabled, pickaxes use sphere-based instant terrain removal.
var enabled: bool = true
