extends Node

# Active tool assignment map: item_id (String) -> Resource (TerrainToolBehavior)
var _tool_assignments: Dictionary = {}

# Default resources (loaded on demand)
const PRESET_PATH = "res://modules/world_player_v2/features/tool_combat/presets/"

func _ready() -> void:
    # Ensure presets folder exists (conceptually)
    # Default assignments
    call_deferred("_load_defaults")

func _load_defaults() -> void:
	# Load default presets
	var classic = load(PRESET_PATH + "pickaxe_classic.tres")
	var enhanced = load(PRESET_PATH + "pickaxe_enhanced.tres")
	var terra_dig = load(PRESET_PATH + "terraformer_dig.tres")
	var terra_place = load(PRESET_PATH + "terraformer_place.tres")
	
	if classic: register_tool("pickaxe_classic", classic)
	if enhanced: register_tool("pickaxe_enhanced", enhanced)
	if terra_dig: register_tool("terraformer_dig", terra_dig)
	if terra_place: register_tool("terraformer_place", terra_place)
	
	# Set default assignments (can be overridden by configs later)
	# Default: Use Enhanced because that's what user has currently enabled
	if enhanced: register_tool("pickaxe", enhanced)
	if terra_dig: register_tool("shovel_primary", terra_dig)
	if terra_place: register_tool("shovel_secondary", terra_place)

func register_tool(item_id: String, active_behavior: TerrainToolBehavior) -> void:
    _tool_assignments[item_id] = active_behavior

func get_tool_behavior(item_id: String) -> TerrainToolBehavior:
    # Check flexible matches (e.g., "pickaxe_iron" matches "pickaxe")
    for key in _tool_assignments:
        if key in item_id:
            return _tool_assignments[key]
    return null
