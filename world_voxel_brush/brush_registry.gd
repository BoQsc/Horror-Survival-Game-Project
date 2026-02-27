extends Node
## BrushRegistry - Centralized management for voxel materials and brush configurations

# Material display names (Centralized from TerrainInteraction)
const MATERIAL_NAMES = {
	-1: "Unknown",
	0: "Grass",
	1: "Stone",
	2: "Ore",
	3: "Sand",
	4: "Gravel",
	5: "Snow",
	6: "Road",
	9: "Granite",
	100: "[P] Grass",
	101: "[P] Stone",
	102: "[P] Sand",
	103: "[P] Snow"
}

# Standard materials list (Centralized from FirstPersonShovel)
const STANDARD_MATERIALS = [
	{"id": 0, "name": "Grass", "key": KEY_1},
	{"id": 1, "name": "Stone", "key": KEY_2},
	{"id": 2, "name": "Ore", "key": KEY_3},
	{"id": 3, "name": "Sand", "key": KEY_4},
	{"id": 4, "name": "Gravel", "key": KEY_5},
	{"id": 5, "name": "Snow", "key": KEY_6},
	{"id": 9, "name": "Granite", "key": KEY_7}
]

# Active tool assignment map: item_id (String) -> VoxelBrush
var _tool_assignments: Dictionary = {}

# Default resources
const PRESET_PATH = "res://world_voxel_brush/presets/"

func _ready() -> void:
	call_deferred("_load_defaults")

func _load_defaults() -> void:
	# Load default presets
	var classic = load(PRESET_PATH + "pickaxe_classic.tres")
	var block_mode = load(PRESET_PATH + "pickaxe_block.tres")
	var terra_dig = load(PRESET_PATH + "terraformer_dig.tres")
	var terra_place = load(PRESET_PATH + "terraformer_place.tres")
	var fist = load(PRESET_PATH + "fist_punch.tres")
	var bucket = load(PRESET_PATH + "bucket.tres")
	var api_block = load(PRESET_PATH + "api_block.tres")
	var api_sphere = load(PRESET_PATH + "api_sphere.tres")
	
	if classic: register_tool("pickaxe_classic", classic)
	if block_mode: register_tool("pickaxe_block", block_mode)
	if terra_dig: register_tool("terraformer_dig", terra_dig)
	if terra_place: register_tool("terraformer_place", terra_place)
	if fist: register_tool("fist_punch", fist)
	if bucket: register_tool("bucket", bucket)
	if api_block: register_tool("api_block", api_block)
	if api_sphere: register_tool("api_sphere", api_sphere)
	
	# Set default assignments
	if block_mode: 
		register_tool("pickaxe", block_mode)
		register_tool("shovel", block_mode)
	if terra_dig: register_tool("terraformer_dig", terra_dig)
	if terra_place: register_tool("terraformer_place", terra_place)
	if fist: register_tool("fist", fist)

func register_tool(item_id: String, active_brush: VoxelBrush) -> void:
	_tool_assignments[item_id] = active_brush

func get_tool_brush(item_id: String) -> VoxelBrush:
	for key in _tool_assignments:
		if key in item_id:
			return _tool_assignments[key]
	return null

func get_material_name(mat_id: int) -> String:
	return MATERIAL_NAMES.get(mat_id, "Unknown (%d)" % mat_id)
