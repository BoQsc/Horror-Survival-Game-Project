extends RigidBody3D
class_name PickupItem
## PickupItem - Physics-based item pickup in the world
## Bounces/rolls when dropped, collected on player contact

signal collected(item_data: Dictionary, count: int)

@export var item_data: Dictionary = {}
@export var item_count: int = 1
@export var pickup_delay: float = 0.5 # Delay before can be picked up

@onready var mesh: MeshInstance3D = $Mesh
@onready var collision: CollisionShape3D = $Collision

@onready var pickup_area: Area3D = $PickupArea

var preferred_slot: int = -1 # Slot index to return to if possible

var can_pickup: bool = false
var time_spawned: float = 0.0

const ItemDefs = preload("res://modules/world_player/data/item_definitions.gd")

func _ready() -> void:
	time_spawned = Time.get_ticks_msec() / 1000.0
	
	# Set up physics
	mass = 1.0
	gravity_scale = 1.0
	linear_damp = 0.5
	angular_damp = 0.5
	
	# Set collision layers
	collision_layer = 256 # Pickups layer (Layer 9)
	collision_mask = 512 # Collide with terrain special layer (Layer 10)
	
	# Connect pickup area
	if pickup_area:
		#pickup_area.body_entered.connect(_on_body_entered)
		pass
	
	# Update visual
	_update_visual()

func _process(_delta: float) -> void:
	if not can_pickup:
		var current_time = Time.get_ticks_msec() / 1000.0
		if current_time - time_spawned >= pickup_delay:
			can_pickup = true

## Returns the interaction prompt for this pickup
func get_interaction_prompt() -> String:
	var name = item_data.get("name", "Item")
	return "[E] Pick up %s" % name

## Returns the item data dictionary for pickup
func get_item_data() -> Dictionary:
	return item_data.duplicate()

## Set item data for this pickup
func set_item(data: Dictionary, count: int = 1) -> void:
	item_data = data.duplicate()
	item_count = count
	_update_visual()

## Update visual based on item type
func _update_visual() -> void:
	if not mesh:
		return
	
	# Check if item has a scene path for custom 3D model
	var scene_path = item_data.get("scene", "")
	if scene_path != "":
		var custom_scene = load(scene_path)
		if custom_scene:
			# Clear existing mesh children
			for child in mesh.get_children():
				child.queue_free()
			
			# Instance the custom model as a child of mesh
			var model_instance = custom_scene.instantiate()
			
			# If it's a RigidBody3D (physics prop), disable physics and hide collisions
			if model_instance is RigidBody3D:
				# Disable physics on it since parent handles that
				model_instance.freeze = true
				model_instance.collision_layer = 0
				model_instance.collision_mask = 0
				# Disable and hide all collision shapes
				_hide_collision_shapes(model_instance)
			
			# Scale down for pickup appearance and center at origin
			model_instance.scale = Vector3(0.6, 0.6, 0.6)
			model_instance.position = Vector3.ZERO  # Center at mesh origin
			mesh.add_child(model_instance)
			mesh.mesh = null  # Hide the default box mesh
			return
	
	# Fallback: Color-coded cube based on item category
	if not mesh.mesh:
		mesh.mesh = BoxMesh.new()
		mesh.mesh.size = Vector3(0.3, 0.3, 0.3)
	
	var mat = StandardMaterial3D.new()
	var category = item_data.get("category", ItemDefs.ItemCategory.NONE)
	
	match category:
		ItemDefs.ItemCategory.RESOURCE:
			mat.albedo_color = Color(0.6, 0.5, 0.3) # Brown for resources
		ItemDefs.ItemCategory.TOOL:
			mat.albedo_color = Color(0.7, 0.7, 0.8) # Metallic for tools
		ItemDefs.ItemCategory.BLOCK:
			mat.albedo_color = Color(0.5, 0.5, 0.5) # Gray for blocks
		ItemDefs.ItemCategory.OBJECT:
			mat.albedo_color = Color(0.8, 0.6, 0.4) # Wood tone for objects
		_:
			mat.albedo_color = Color.WHITE
	
	mesh.material_override = mat

## Recursively hide and disable all collision shapes in a node tree
func _hide_collision_shapes(node: Node) -> void:
	if node is CollisionShape3D:
		node.disabled = true
		node.visible = false
	elif node is CollisionPolygon3D:
		node.disabled = true
	for child in node.get_children():
		_hide_collision_shapes(child)

## Handle body entering pickup area
func _on_body_entered(body: Node3D) -> void:
	if not can_pickup:
		return
	
	if body.is_in_group("player"):
		_try_collect(body)

## Try to collect the item
func _try_collect(player: Node3D) -> void:
	var hotbar = player.get_node_or_null("Systems/Hotbar")
	var inventory = player.get_node_or_null("Systems/Inventory")
	var remaining = item_count
	
	# First, try to add to hotbar (prioritize hotbar for quick access)
	if hotbar:
		# Try preferred slot first if set
		if preferred_slot >= 0 and remaining > 0:
			var slot_count = hotbar.get_count_at(preferred_slot)
			if slot_count == 0:
				# Slot is empty - fill it
				hotbar.set_item_at(preferred_slot, item_data, 1)
				remaining -= 1
				# If we have more, try to stack in same slot (if stackable)
				# But set_item_at overwrites. We need to increment.
				# hotbar doesn't expose "add to slot".
				# But add_item handles generic adding.
				# Let's just trust that filling the empty slot is enough for the first item.
				# If the user dropped a whole stack, they might want all back in same slot.
				# But drop_selected_item currently drops 1 at a time.
			elif hotbar.get_item_at(preferred_slot).get("id") == item_data.get("id"):
				# Slot has same item - try to stack
				# hotbar doesn't expose public "increment slot".
				# We can rely on generic add_item logic for stacking, causing it to likely pick this slot if it's the first stackable one.
				pass
	
	if hotbar and hotbar.has_method("add_item"):
		while remaining > 0:
			if hotbar.add_item(item_data):
				remaining -= 1
			else:
				break  # Hotbar is full or can't stack
	
	# Then, add overflow to inventory
	if remaining > 0 and inventory and inventory.has_method("add_item"):
		var leftover = inventory.add_item(item_data, remaining)
		remaining = leftover
	
	var collected_count = item_count - remaining
	if collected_count > 0:
		# Some or all collected
		collected.emit(item_data, collected_count)
		
		if remaining <= 0:
			# All collected, remove pickup
			queue_free()
		else:
			# Partial collection
			item_count = remaining

## Spawn a pickup at position with velocity
static func spawn_pickup(parent: Node, data: Dictionary, count: int, pos: Vector3, velocity: Vector3 = Vector3.ZERO) -> PickupItem:
	var scene = load("res://modules/world_player/pickups/pickup_item.tscn")
	var instance = scene.instantiate() as PickupItem
	
	parent.add_child(instance)
	instance.global_position = pos
	instance.set_item(data, count)
	
	if velocity != Vector3.ZERO:
		instance.linear_velocity = velocity
	else:
		# Random small toss
		instance.linear_velocity = Vector3(
			randf_range(-2, 2),
			randf_range(2, 4),
			randf_range(-2, 2)
		)
	
	return instance
