extends Node
## PickaxeDurabilityConfig - Global configuration for pickaxe durability system
## Autoload singleton that controls whether pickaxe requires multiple hits

## When enabled (default), pickaxes require multiple hits to break terrain blocks
## When disabled, pickaxes break terrain instantly (like terraformer)
## This setting works for BOTH enhanced mode (box) and sphere mode
var enabled: bool = true
