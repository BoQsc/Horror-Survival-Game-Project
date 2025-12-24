extends Node
## Debug logging settings autoload.
## Toggle categories to enable/disable debug output for performance.
## All flags are OFF by default for production builds.

# === LOGGING CATEGORY TOGGLES ===
# Set to true to enable debug prints for each category

## Chunk generation and loading
var LOG_CHUNK := false

## Vegetation (trees, grass, rocks) placement and cleanup
var LOG_VEGETATION := false

## Entity spawning and management (zombies, NPCs)
var LOG_ENTITIES := false

## Building and prefab systems
var LOG_BUILDING := false

## Save/Load operations (recommended to keep enabled)
var LOG_SAVE := true

## Vehicle spawning and management
var LOG_VEHICLES := false

## Player interactions
var LOG_PLAYER := false

## Roads and paths
var LOG_ROADS := false

## Water system
var LOG_WATER := false

## Performance spikes and timing
var LOG_PERFORMANCE := false


# === HELPER FUNCTIONS ===

## Log a debug message if the category is enabled
func log_chunk(message: String) -> void:
	if LOG_CHUNK:
		print("[Chunk] ", message)

func log_vegetation(message: String) -> void:
	if LOG_VEGETATION:
		print("[Vegetation] ", message)

func log_entities(message: String) -> void:
	if LOG_ENTITIES:
		print("[Entities] ", message)

func log_building(message: String) -> void:
	if LOG_BUILDING:
		print("[Building] ", message)

func log_save(message: String) -> void:
	if LOG_SAVE:
		print("[Save] ", message)

func log_vehicles(message: String) -> void:
	if LOG_VEHICLES:
		print("[Vehicles] ", message)

func log_player(message: String) -> void:
	if LOG_PLAYER:
		print("[Player] ", message)

func log_roads(message: String) -> void:
	if LOG_ROADS:
		print("[Roads] ", message)

func log_water(message: String) -> void:
	if LOG_WATER:
		print("[Water] ", message)

func log_performance(message: String) -> void:
	if LOG_PERFORMANCE:
		print(message)


# === ENABLE ALL FOR DEBUGGING ===

func enable_all() -> void:
	LOG_CHUNK = true
	LOG_VEGETATION = true
	LOG_ENTITIES = true
	LOG_BUILDING = true
	LOG_SAVE = true
	LOG_VEHICLES = true
	LOG_PLAYER = true
	LOG_ROADS = true
	LOG_WATER = true
	LOG_PERFORMANCE = true

func disable_all() -> void:
	LOG_CHUNK = false
	LOG_VEGETATION = false
	LOG_ENTITIES = false
	LOG_BUILDING = false
	LOG_SAVE = false
	LOG_VEHICLES = false
	LOG_PLAYER = false
	LOG_ROADS = false
	LOG_WATER = false
	LOG_PERFORMANCE = false
