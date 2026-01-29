@tool
extends Node3D

## Ragdoll Auto-Fixer
## 1. Fixes scale issues (0.0254 -> 1.0)
## 2. Resizes collision shapes to be reasonable
## 3. Configures physical bones for stability

@export var run_fix_on_ready: bool = true

func _ready():
	if run_fix_on_ready:
		apply_fixes()

func apply_fixes():
	print("\n" + "=".repeat(60))
	print("Running Ragdoll Auto-Fixer...")
	print("=".repeat(60))
	
	var skeleton = _find_skeleton(self)
	if not skeleton:
		print("❌ No Skeleton3D found!")
		return
		
	# 1. FIX SCALE
	_fix_scale(skeleton)
	
	# 2. RESET BONE SCALES (Critical - Run always to ensure safety)
	_reset_physical_bone_scales(skeleton)
	
	# 3. FIX COLLISION SHAPES
	_fix_collision_shapes(skeleton)
	
	# 4. CONFIGURE PHYSICAL BONES
	_configure_physical_bones(skeleton)
	
	print("\n" + "=".repeat(60))
	print("✅ FIXES COMPLETE - PLEASE SAVE THE SCENE!")
	print("=".repeat(60))

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var result = _find_skeleton(child)
		if result:
			return result
	return null

func _fix_scale(skeleton: Skeleton3D):
	print("\n[1] Checking Parent Scale...")
	
	# Find the import container (node with ~0.0254 scale)
	var current = skeleton
	var import_container = null
	
	for i in range(5):
		var parent = current.get_parent()
		if not parent: break
		
		# Check for scale close to 0.0254 (allowing floating point variance)
		if abs(parent.scale.x - 0.0254) < 0.001:
			import_container = parent
			break
		# Also check for 100 scale (sometimes happens with cm conversion)
		if abs(parent.scale.x - 100.0) < 0.1:
			import_container = parent
			break
			
		current = parent
	
	if import_container:
		print("  Found import container: %s (Scale: %s)" % [import_container.name, import_container.scale])
		
		var old_scale = import_container.scale.x
		var target_scale = 1.0
		var scale_factor = target_scale / old_scale
		
		print("  Correcting scale to 1.0 (Factor: %.2f)" % scale_factor)
		
		# 1. Adjust Position to maintain world location
		# If we scale up by 39.37, the position also scales up by 39.37
		# So we divide the position by the same amount to counteract it
		import_container.position = import_container.position / scale_factor
		
		# 2. Set Scale
		import_container.scale = Vector3.ONE * target_scale
		
		print("  ✓ Scale fixed to 1.0")
		print("  ✓ Position compensated")
	else:
		print("  ✓ No improperly scaled import container found (or already fixed)")

func _reset_physical_bone_scales(skeleton: Skeleton3D):
	print("\n[2] Checking Physical Bone Scales...")
	var count = 0
	var reset_count = 0
	
	# Recursively find physical bones (they might be under PhysicalBoneSimulator3D)
	var bones = _find_nodes_of_type(skeleton, "PhysicalBone3D")
	
	for pb in bones:
		count += 1
		# Check if scale is massive (e.g. > 2.0)
		if pb.scale.length() > 2.0: # Vector3(1,1,1).length() is 1.73
			pb.scale = Vector3.ONE
			reset_count += 1
			
	print("  Scanned %d physical bones. Reset scales for %d bones." % [count, reset_count])
	if reset_count > 0:
		print("  ✓ Corrected massive bone scales (caused by parent fix)")

func _fix_collision_shapes(skeleton: Skeleton3D):
	print("\n[3] Inspection & Fixing Collision Shapes...")
	
	var count = 0
	var fixed = 0
	var bones = _find_nodes_of_type(skeleton, "PhysicalBone3D")
	
	for pb in bones:
		for subchild in pb.get_children():
			if subchild is CollisionShape3D:
				count += 1
				if _resize_shape_if_needed(subchild, pb.name):
					fixed += 1
						
	print("  Scanned %d shapes. Resized %d huge shapes." % [count, fixed])

func _find_nodes_of_type(root: Node, type_name: String) -> Array:
	var results = []
	if root.get_class() == type_name:
		results.append(root)
	for child in root.get_children():
		results.append_array(_find_nodes_of_type(child, type_name))
	return results

func _resize_shape_if_needed(col_shape: CollisionShape3D, bone_name: String) -> bool:
	var shape = col_shape.shape
	if not shape: return false
	
	var resized = false
	
	if shape is CapsuleShape3D:
		# STRATEGY:
		# 1. Huge Shapes (Original ~1m length) -> Shrink by 0.254 (Target ~25cm)
		# 2. Tiny Broken Shapes (Previously shrunk to ~4mm) -> Grow by 10.0 (Target ~4cm radius)
		# 3. Normal/Fingers (Radius ~1.5cm) -> Leave alone
		
		# Case 1: Huge (Radius > 5cm)
		# Note: Arms are ~10cm radius, 1m height.
		if shape.radius > 0.05: 
			print("  ⚠️ Shrinking HUGE Capsule on %s (R: %.4f -> %.4f)" % [bone_name, shape.radius, shape.radius * 0.254])
			shape.radius *= 0.254
			shape.height *= 0.254
			resized = true
			
		# Case 2: Broken Tiny (Radius < 5mm)
		# Note: The broken thighs are ~0.004 radius.
		elif shape.radius < 0.005:
			print("  ⚠️ Restoring TINY Capsule on %s (R: %.4f -> %.4f)" % [bone_name, shape.radius, shape.radius * 5.0])
			shape.radius *= 5.0
			shape.height *= 5.0
			resized = true
			
	elif shape is BoxShape3D:
		if shape.size.x > 0.3: # 30cm box -> Shrink
			shape.size *= 0.254
			resized = true
		elif shape.size.x < 0.01: # 1cm box -> Grow
			shape.size *= 5.0
			resized = true
			
	return resized

func _configure_physical_bones(skeleton: Skeleton3D):
	print("\n[4] Configuring Physical Bones...")
	
	var bones = _find_nodes_of_type(skeleton, "PhysicalBone3D")
	for child in bones:
		# Ensure mass is reasonable (default can be weird)
		if child.mass < 0.1: 
			child.mass = 1.0
		
		# Ensure reasonable bounce/friction
		child.bounce = 0.0
		child.friction = 0.8
