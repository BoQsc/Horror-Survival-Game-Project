extends Resource
class_name VegetationRegistry

const VegetationType = preload("res://world_vegetation/types/vegetation_type.gd")

@export var types: Array[VegetationType] = []

var _types_by_id: Dictionary = {}


func _init() -> void:
	_rebuild_index()


func _rebuild_index() -> void:
	_types_by_id.clear()
	for vegetation_type in types:
		if vegetation_type == null:
			continue
		var type_id := vegetation_type.id
		if String(type_id).strip_edges().is_empty():
			continue
		_types_by_id[type_id] = vegetation_type


func add_type(vegetation_type: VegetationType) -> void:
	if vegetation_type == null:
		return
	if String(vegetation_type.id).strip_edges().is_empty():
		return
	if not types.has(vegetation_type):
		types.append(vegetation_type)
	_types_by_id[vegetation_type.id] = vegetation_type


func get_type(type_id: Variant) -> VegetationType:
	var key := StringName(str(type_id))
	if _types_by_id.has(key):
		return _types_by_id[key] as VegetationType
	return null


func has_type(type_id: Variant) -> bool:
	return _types_by_id.has(StringName(str(type_id)))


func get_types_by_category(category: int) -> Array[VegetationType]:
	var matches: Array[VegetationType] = []
	for vegetation_type in types:
		if vegetation_type and vegetation_type.category == category:
			matches.append(vegetation_type)
	return matches


func get_first_type_by_category(category: int) -> VegetationType:
	for vegetation_type in types:
		if vegetation_type and vegetation_type.category == category:
			return vegetation_type
	return null


func _make_type(
		type_id: StringName,
		display_name: String,
		category: int,
		source_path: String,
		render_mode: int,
		harvest_mode: int,
		required_tool: StringName,
		health: float,
		regrow_seconds: float,
		support_rule: int,
		is_targetable: bool,
		is_choppable: bool,
		is_harvestable: bool
) -> VegetationType:
	var vegetation_type := VegetationType.new()
	vegetation_type.id = type_id
	vegetation_type.display_name = display_name
	vegetation_type.category = category
	vegetation_type.source_path = source_path
	vegetation_type.render_mode = render_mode
	vegetation_type.harvest_mode = harvest_mode
	vegetation_type.required_tool = required_tool
	vegetation_type.health = health
	vegetation_type.regrow_seconds = regrow_seconds
	vegetation_type.support_rule = support_rule
	vegetation_type.is_targetable = is_targetable
	vegetation_type.is_choppable = is_choppable
	vegetation_type.is_harvestable = is_harvestable
	return vegetation_type


static func _make_simple_grass_mesh(
		material: Material,
		half_width: float = 0.08,
		height: float = 0.36,
		vertex_color: Color = Color(0.28, 0.48, 0.18, 1.0)
) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices := PackedVector3Array([
		# Two crossed quads. Culling is disabled on the material, so duplicate
		# back faces only add vertices and triangles without changing the look.
		Vector3(-half_width, 0.0, 0.0),
		Vector3(half_width, 0.0, 0.0),
		Vector3(half_width, height, 0.0),
		Vector3(-half_width, height, 0.0),
		Vector3(0.0, 0.0, -half_width),
		Vector3(0.0, 0.0, half_width),
		Vector3(0.0, height, half_width),
		Vector3(0.0, height, -half_width)
	])

	var normals := PackedVector3Array([
		Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 1.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0)
	])

	var uvs := PackedVector2Array([
		Vector2(0.0, 1.0),
		Vector2(1.0, 1.0),
		Vector2(1.0, 0.0),
		Vector2(0.0, 0.0),
		Vector2(0.0, 1.0),
		Vector2(1.0, 1.0),
		Vector2(1.0, 0.0),
		Vector2(0.0, 0.0)
	])
	var colors := PackedColorArray()
	colors.resize(vertices.size())
	for i in range(colors.size()):
		colors[i] = vertex_color

	var indices := PackedInt32Array([
		0, 1, 2, 0, 2, 3,
		4, 5, 6, 4, 6, 7
	])

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material != null:
		mesh.surface_set_material(0, material)
	return mesh


static func _make_simple_grass_material(albedo_color: Color = Color(0.28, 0.48, 0.18, 1.0)) -> Material:
	var shader := load("res://world_vegetation/shaders/vegetation_chunk.gdshader") as Shader
	if shader != null:
		var shader_material := ShaderMaterial.new()
		shader_material.shader = shader
		shader_material.set_shader_parameter("alpha_scissor_threshold", 0.35)
		return shader_material
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = albedo_color
	material.vertex_color_use_as_albedo = true
	return material


static func _make_foliage_material(albedo_color: Color) -> Material:
	return _make_opaque_vertex_material(albedo_color)


static func _make_opaque_vertex_material(albedo_color: Color) -> Material:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.albedo_color = albedo_color
	material.vertex_color_use_as_albedo = true
	return material


static func _make_grounded_source_transform(source_path: String, center_xz: bool = true) -> Transform3D:
	return _make_grounded_source_transform_impl(source_path, center_xz, false)


static func _make_imported_grounded_source_transform(source_path: String, center_xz: bool = true) -> Transform3D:
	return _make_grounded_source_transform_impl(source_path, center_xz, true)


static func _make_imported_source_transform(source_path: String) -> Transform3D:
	var probe := VegetationType.new()
	probe.source_path = source_path
	var geometry := probe.get_source_geometry()
	return geometry.get("transform", Transform3D.IDENTITY)


static func _make_grounded_source_transform_impl(source_path: String, center_xz: bool, use_imported_transform: bool) -> Transform3D:
	var probe := VegetationType.new()
	probe.source_path = source_path
	var geometry := probe.get_source_geometry()
	var mesh: Mesh = geometry.get("mesh", null)
	if mesh == null:
		return Transform3D.IDENTITY
	var source_transform: Transform3D = geometry.get("transform", Transform3D.IDENTITY) if use_imported_transform else Transform3D.IDENTITY
	var source_aabb := mesh.get_aabb()
	var transformed_aabb := _transform_aabb(source_aabb, source_transform)
	var min_v := transformed_aabb.position
	var max_v := transformed_aabb.position + transformed_aabb.size
	var offset := Vector3(0.0, -min_v.y, 0.0)
	if center_xz:
		offset.x = -((min_v.x + max_v.x) * 0.5)
		offset.z = -((min_v.z + max_v.z) * 0.5)
	return Transform3D.IDENTITY.translated(offset) * source_transform


static func _make_fast_source_material(source_path: String, alpha_scissor_threshold: float, double_sided: bool, force_unshaded: bool = true) -> Material:
	var probe := VegetationType.new()
	probe.source_path = source_path
	var source_material := probe.get_material_for_surface(0)
	if source_material is BaseMaterial3D:
		var material := (source_material as BaseMaterial3D).duplicate() as BaseMaterial3D
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR if alpha_scissor_threshold > 0.0 else BaseMaterial3D.TRANSPARENCY_DISABLED
		material.alpha_scissor_threshold = clampf(alpha_scissor_threshold, 0.0, 1.0)
		material.cull_mode = BaseMaterial3D.CULL_DISABLED if double_sided else BaseMaterial3D.CULL_BACK
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
		material.roughness = 1.0
		material.metallic = 0.0
		material.metallic_specular = 0.0
		material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		material.disable_specular_occlusion = true
		if force_unshaded:
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			material.normal_enabled = false
		return material
	if source_material != null:
		return source_material
	return null


static func _make_textured_cutout_material(source_path: String, alpha_scissor_threshold: float) -> Material:
	var shader := load("res://world_vegetation/shaders/vegetation_textured_cutout.gdshader") as Shader
	if shader == null:
		return _make_fast_source_material(source_path, alpha_scissor_threshold, true, true)
	var probe := VegetationType.new()
	probe.source_path = source_path
	var source_material := probe.get_material_for_surface(0)
	var texture: Texture2D = null
	if source_material is BaseMaterial3D:
		texture = (source_material as BaseMaterial3D).albedo_texture
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("alpha_scissor_threshold", clampf(alpha_scissor_threshold, 0.0, 1.0))
	if texture != null:
		material.set_shader_parameter("albedo_texture", texture)
	return material


static func _make_alpha_scissor_pruned_source_mesh(source_path: String, alpha_scissor_threshold: float) -> Mesh:
	var probe := VegetationType.new()
	probe.source_path = source_path
	var source_mesh := probe.get_source_mesh()
	if source_mesh == null or source_mesh.get_surface_count() <= 0:
		return source_mesh
	var source_material := probe.get_material_for_surface(0)
	if not (source_material is BaseMaterial3D):
		return source_mesh
	var texture := (source_material as BaseMaterial3D).albedo_texture
	if texture == null:
		return source_mesh
	var image := texture.get_image()
	if image == null or image.is_empty():
		return source_mesh
	if image.is_compressed():
		var err := image.decompress()
		if err != OK:
			return source_mesh
	var optimized_mesh := ArrayMesh.new()
	var removed_any := false
	for surface_index in range(source_mesh.get_surface_count()):
		var source_arrays := source_mesh.surface_get_arrays(surface_index)
		var optimized_arrays := _prune_alpha_scissor_surface_arrays(source_arrays, image, alpha_scissor_threshold)
		if optimized_arrays.is_empty():
			optimized_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, source_arrays)
		else:
			removed_any = true
			optimized_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, optimized_arrays)
		var material := source_mesh.surface_get_material(surface_index)
		if material != null:
			optimized_mesh.surface_set_material(surface_index, material)
	return optimized_mesh if removed_any else source_mesh


static func _prune_alpha_scissor_surface_arrays(source_arrays: Array, image: Image, alpha_scissor_threshold: float) -> Array:
	if source_arrays.size() <= Mesh.ARRAY_TEX_UV:
		return []
	var vertices: PackedVector3Array = source_arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = source_arrays[Mesh.ARRAY_TEX_UV]
	if vertices.is_empty() or uvs.size() != vertices.size():
		return []
	var source_indices := PackedInt32Array()
	if source_arrays.size() > Mesh.ARRAY_INDEX and source_arrays[Mesh.ARRAY_INDEX] != null:
		source_indices = source_arrays[Mesh.ARRAY_INDEX]
	if source_indices.is_empty():
		source_indices.resize(vertices.size())
		for i in range(vertices.size()):
			source_indices[i] = i
	var new_arrays: Array = []
	new_arrays.resize(Mesh.ARRAY_MAX)
	var new_vertices := PackedVector3Array()
	var new_normals := PackedVector3Array()
	var new_tangents := PackedFloat32Array()
	var new_uvs := PackedVector2Array()
	var new_colors := PackedColorArray()
	var new_indices := PackedInt32Array()
	var source_normals: PackedVector3Array = source_arrays[Mesh.ARRAY_NORMAL] if source_arrays.size() > Mesh.ARRAY_NORMAL and source_arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var source_tangents: PackedFloat32Array = source_arrays[Mesh.ARRAY_TANGENT] if source_arrays.size() > Mesh.ARRAY_TANGENT and source_arrays[Mesh.ARRAY_TANGENT] != null else PackedFloat32Array()
	var source_colors: PackedColorArray = source_arrays[Mesh.ARRAY_COLOR] if source_arrays.size() > Mesh.ARRAY_COLOR and source_arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
	var use_normals := source_normals.size() == vertices.size()
	var use_tangents := source_tangents.size() == vertices.size() * 4
	var use_colors := source_colors.size() == vertices.size()
	var remap := {}
	var removed_count := 0
	for index in range(0, source_indices.size() - 2, 3):
		var a := int(source_indices[index])
		var b := int(source_indices[index + 1])
		var c := int(source_indices[index + 2])
		if a < 0 or b < 0 or c < 0 or a >= vertices.size() or b >= vertices.size() or c >= vertices.size():
			continue
		if _triangle_fully_alpha_rejected(uvs[a], uvs[b], uvs[c], image, alpha_scissor_threshold):
			removed_count += 1
			continue
		new_indices.append(_remap_source_vertex(a, remap, vertices, source_normals, source_tangents, uvs, source_colors, use_normals, use_tangents, use_colors, new_vertices, new_normals, new_tangents, new_uvs, new_colors))
		new_indices.append(_remap_source_vertex(b, remap, vertices, source_normals, source_tangents, uvs, source_colors, use_normals, use_tangents, use_colors, new_vertices, new_normals, new_tangents, new_uvs, new_colors))
		new_indices.append(_remap_source_vertex(c, remap, vertices, source_normals, source_tangents, uvs, source_colors, use_normals, use_tangents, use_colors, new_vertices, new_normals, new_tangents, new_uvs, new_colors))
	if removed_count <= 0 or new_vertices.is_empty() or new_indices.is_empty():
		return []
	new_arrays[Mesh.ARRAY_VERTEX] = new_vertices
	if use_normals:
		new_arrays[Mesh.ARRAY_NORMAL] = new_normals
	if use_tangents:
		new_arrays[Mesh.ARRAY_TANGENT] = new_tangents
	new_arrays[Mesh.ARRAY_TEX_UV] = new_uvs
	if use_colors:
		new_arrays[Mesh.ARRAY_COLOR] = new_colors
	new_arrays[Mesh.ARRAY_INDEX] = new_indices
	return new_arrays


static func _triangle_fully_alpha_rejected(a: Vector2, b: Vector2, c: Vector2, image: Image, alpha_scissor_threshold: float) -> bool:
	var samples := [
		a,
		b,
		c,
		(a + b + c) / 3.0,
		(a + b) * 0.5,
		(b + c) * 0.5,
		(c + a) * 0.5
	]
	for uv_variant in samples:
		var uv: Vector2 = uv_variant
		if _sample_alpha_scissor_uv(image, uv, false) > alpha_scissor_threshold:
			return false
		if _sample_alpha_scissor_uv(image, uv, true) > alpha_scissor_threshold:
			return false
	return true


static func _sample_alpha_scissor_uv(image: Image, uv: Vector2, flip_v: bool) -> float:
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return 1.0
	var sample_v := 1.0 - uv.y if flip_v else uv.y
	var x := clampi(int(fposmod(uv.x, 1.0) * float(width - 1) + 0.5), 0, width - 1)
	var y := clampi(int(fposmod(sample_v, 1.0) * float(height - 1) + 0.5), 0, height - 1)
	return image.get_pixel(x, y).a


static func _remap_source_vertex(
		source_index: int,
		remap: Dictionary,
		source_vertices: PackedVector3Array,
		source_normals: PackedVector3Array,
		source_tangents: PackedFloat32Array,
		source_uvs: PackedVector2Array,
		source_colors: PackedColorArray,
		use_normals: bool,
		use_tangents: bool,
		use_colors: bool,
		new_vertices: PackedVector3Array,
		new_normals: PackedVector3Array,
		new_tangents: PackedFloat32Array,
		new_uvs: PackedVector2Array,
		new_colors: PackedColorArray
) -> int:
	if remap.has(source_index):
		return int(remap[source_index])
	var new_index := new_vertices.size()
	remap[source_index] = new_index
	new_vertices.append(source_vertices[source_index])
	if use_normals:
		new_normals.append(source_normals[source_index])
	if use_tangents:
		var tangent_index := source_index * 4
		new_tangents.append(source_tangents[tangent_index])
		new_tangents.append(source_tangents[tangent_index + 1])
		new_tangents.append(source_tangents[tangent_index + 2])
		new_tangents.append(source_tangents[tangent_index + 3])
	new_uvs.append(source_uvs[source_index])
	if use_colors:
		new_colors.append(source_colors[source_index])
	return new_index


static func _transform_aabb(aabb: AABB, transform: Transform3D) -> AABB:
	var min_v := aabb.position
	var max_v := aabb.position + aabb.size
	var points := [
		Vector3(min_v.x, min_v.y, min_v.z),
		Vector3(max_v.x, min_v.y, min_v.z),
		Vector3(min_v.x, max_v.y, min_v.z),
		Vector3(max_v.x, max_v.y, min_v.z),
		Vector3(min_v.x, min_v.y, max_v.z),
		Vector3(max_v.x, min_v.y, max_v.z),
		Vector3(min_v.x, max_v.y, max_v.z),
		Vector3(max_v.x, max_v.y, max_v.z)
	]
	var transformed := AABB(transform * points[0], Vector3.ZERO)
	for i in range(1, points.size()):
		transformed = transformed.expand(transform * points[i])
	return transformed


static func _make_simple_blob_mesh(
		material: Material,
		bottom_radius: float,
		middle_radius: float,
		top_radius: float,
		height: float,
		segments: int = 8,
		vertex_color: Color = Color(1.0, 1.0, 1.0, 1.0)
) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	if material != null:
		st.set_material(material)

	var bottom_y := 0.0
	var middle_y := height * 0.55
	var top_y := height
	for i in range(segments):
		var next_i := (i + 1) % segments
		var angle_a := TAU * float(i) / float(segments)
		var angle_b := TAU * float(next_i) / float(segments)
		var bottom_a := Vector3(cos(angle_a) * bottom_radius, bottom_y, sin(angle_a) * bottom_radius)
		var bottom_b := Vector3(cos(angle_b) * bottom_radius, bottom_y, sin(angle_b) * bottom_radius)
		var middle_a := Vector3(cos(angle_a) * middle_radius, middle_y, sin(angle_a) * middle_radius)
		var middle_b := Vector3(cos(angle_b) * middle_radius, middle_y, sin(angle_b) * middle_radius)
		var top_a := Vector3(cos(angle_a) * top_radius, top_y, sin(angle_a) * top_radius)
		var top_b := Vector3(cos(angle_b) * top_radius, top_y, sin(angle_b) * top_radius)
		st.set_color(vertex_color)
		st.add_vertex(bottom_a)
		st.add_vertex(bottom_b)
		st.add_vertex(middle_b)
		st.add_vertex(bottom_a)
		st.add_vertex(middle_b)
		st.add_vertex(middle_a)
		st.add_vertex(middle_a)
		st.add_vertex(middle_b)
		st.add_vertex(top_b)
		st.add_vertex(middle_a)
		st.add_vertex(top_b)
		st.add_vertex(top_a)
		var top_center := Vector3(0.0, top_y + 0.02, 0.0)
		st.add_vertex(top_a)
		st.add_vertex(top_b)
		st.add_vertex(top_center)

	return st.commit()


static func create_default():
	var registry_script: Script = load("res://world_vegetation/types/vegetation_registry.gd")
	var registry = registry_script.new() if registry_script else null

	var tree_source := "res://models/tree/1/pine_tree_-_ps1_low_poly.glb"
	var grass_source := "res://models/grass/2/grass_lowpoly.glb"
	var rock_source := "res://models/small_rock/simple_rock_-_ps1_low_poly.glb"
	var tree_source_mesh := _make_alpha_scissor_pruned_source_mesh(tree_source, 0.48)
	var grass_source_transform := _make_grounded_source_transform(grass_source, true)
	# Preserve the authored tree scene transform. AABB-grounding this GLB lifts
	# the visible trunk several meters above the sampled terrain surface.
	var tree_source_transform := _make_imported_source_transform(tree_source)
	var rock_source_transform := _make_imported_grounded_source_transform(rock_source, true)
	var grass_source_material := _make_textured_cutout_material(grass_source, 0.45)
	var tree_source_material := _make_fast_source_material(tree_source, 0.48, true, false)
	var rock_source_material := _make_fast_source_material(rock_source, 0.0, false, false)
	var vegetation_chunk_material := _make_opaque_vertex_material(Color(1.0, 1.0, 1.0, 1.0))

	var grass_green: VegetationType = registry._make_type(
		&"grass_green",
		"Grass Green",
		VegetationType.Category.GRASS,
		grass_source,
		VegetationType.RenderMode.CHUNK_MESH,
		VegetationType.HarvestMode.HAND,
		&"hand",
		1.0,
		5.0,
		VegetationType.SupportRule.GROUND,
		false,
		false,
		true
	)
	grass_green.alpha_scissor_threshold = 0.45
	grass_green.instance_scale = 0.92
	grass_green.support_radius = 0.16
	grass_green.support_height = 0.22
	grass_green.mesh_source_transform = grass_source_transform
	grass_green.material = grass_source_material
	registry.add_type(grass_green)

	var grass_dry: VegetationType = registry._make_type(
		&"grass_dry",
		"Grass Dry",
		VegetationType.Category.GRASS,
		grass_source,
		VegetationType.RenderMode.CHUNK_MESH,
		VegetationType.HarvestMode.HAND,
		&"hand",
		1.0,
		5.0,
		VegetationType.SupportRule.GROUND,
		false,
		false,
		true
	)
	grass_dry.alpha_scissor_threshold = 0.45
	grass_dry.instance_scale = 0.84
	grass_dry.support_radius = 0.16
	grass_dry.support_height = 0.20
	grass_dry.mesh_source_transform = grass_source_transform
	grass_dry.material = grass_source_material
	registry.add_type(grass_dry)

	var grass_tall: VegetationType = registry._make_type(
		&"grass_tall",
		"Grass Tall",
		VegetationType.Category.GRASS,
		grass_source,
		VegetationType.RenderMode.CHUNK_MESH,
		VegetationType.HarvestMode.HAND,
		&"hand",
		1.0,
		6.0,
		VegetationType.SupportRule.GROUND,
		false,
		false,
		true
	)
	grass_tall.alpha_scissor_threshold = 0.45
	grass_tall.instance_scale = 1.12
	grass_tall.support_radius = 0.20
	grass_tall.support_height = 0.30
	grass_tall.mesh_source_transform = grass_source_transform
	grass_tall.material = grass_source_material
	registry.add_type(grass_tall)

	var reed: VegetationType = registry._make_type(
		&"reed",
		"Reed",
		VegetationType.Category.GRASS,
		grass_source,
		VegetationType.RenderMode.CHUNK_MESH,
		VegetationType.HarvestMode.HAND,
		&"hand",
		1.0,
		7.0,
		VegetationType.SupportRule.GROUND,
		false,
		false,
		true
	)
	reed.instance_scale = 1.12
	reed.support_radius = 0.22
	reed.support_height = 0.38
	reed.mesh_source_transform = grass_source_transform
	reed.material = grass_source_material
	registry.add_type(reed)

	var fiber_bush_mesh := _make_simple_blob_mesh(vegetation_chunk_material, 0.46, 0.62, 0.38, 0.82, 8, Color(0.20, 0.34, 0.14, 1.0))
	var small_rock: VegetationType = registry._make_type(
		&"small_rock",
		"Small Rock",
		VegetationType.Category.ROCK,
		rock_source,
		VegetationType.RenderMode.INDIVIDUAL_INSTANCE,
		VegetationType.HarvestMode.HAND,
		&"hand",
		5.0,
		0.0,
		VegetationType.SupportRule.GROUND,
		true,
		false,
		true
	)
	small_rock.instance_scale = 0.92
	small_rock.support_radius = 0.30
	small_rock.support_height = 0.28
	small_rock.mesh_source_transform = rock_source_transform
	small_rock.material = rock_source_material
	small_rock.drops = [
		{"id": "stone", "amount": 2}
	]
	registry.add_type(small_rock)

	var fiber_bush: VegetationType = registry._make_type(
		&"fiber_bush",
		"Fiber Bush",
		VegetationType.Category.BUSH,
		"",
		VegetationType.RenderMode.INDIVIDUAL_INSTANCE,
		VegetationType.HarvestMode.HAND,
		&"hand",
		3.0,
		12.0,
		VegetationType.SupportRule.GROUND,
		true,
		false,
		true
	)
	fiber_bush.instance_scale = 1.35
	fiber_bush.support_radius = 0.62
	fiber_bush.support_height = 0.82
	fiber_bush.drops = [
		{"id": "fiber", "amount": 2}
	]
	fiber_bush.source_mesh = fiber_bush_mesh
	fiber_bush.material = vegetation_chunk_material
	registry.add_type(fiber_bush)

	var berry_bush_mesh := _make_simple_blob_mesh(vegetation_chunk_material, 0.50, 0.70, 0.40, 0.90, 8, Color(0.16, 0.28, 0.12, 1.0))
	var berry_bush: VegetationType = registry._make_type(
		&"berry_bush",
		"Berry Bush",
		VegetationType.Category.BUSH,
		"",
		VegetationType.RenderMode.INDIVIDUAL_INSTANCE,
		VegetationType.HarvestMode.HAND,
		&"hand",
		4.0,
		14.0,
		VegetationType.SupportRule.GROUND,
		true,
		false,
		true
	)
	berry_bush.instance_scale = 1.45
	berry_bush.support_radius = 0.68
	berry_bush.support_height = 0.90
	berry_bush.drops = [
		{"id": "berries", "amount": 2},
		{"id": "sticks", "amount": 1}
	]
	berry_bush.source_mesh = berry_bush_mesh
	berry_bush.material = vegetation_chunk_material
	registry.add_type(berry_bush)

	var stick_bush_mesh := _make_simple_blob_mesh(vegetation_chunk_material, 0.42, 0.56, 0.34, 0.76, 8, Color(0.34, 0.31, 0.16, 1.0))
	var stick_bush: VegetationType = registry._make_type(
		&"stick_bush",
		"Stick Bush",
		VegetationType.Category.BUSH,
		"",
		VegetationType.RenderMode.INDIVIDUAL_INSTANCE,
		VegetationType.HarvestMode.AXE,
		&"axe",
		3.0,
		10.0,
		VegetationType.SupportRule.GROUND,
		true,
		false,
		true
	)
	stick_bush.instance_scale = 1.25
	stick_bush.support_radius = 0.58
	stick_bush.support_height = 0.78
	stick_bush.drops = [
		{"id": "sticks", "amount": 2}
	]
	stick_bush.source_mesh = stick_bush_mesh
	stick_bush.material = vegetation_chunk_material
	registry.add_type(stick_bush)

	var pine_tree: VegetationType = registry._make_type(
		&"pine_tree",
		"Pine Tree",
		VegetationType.Category.TREE,
		tree_source,
		VegetationType.RenderMode.INDIVIDUAL_INSTANCE,
		VegetationType.HarvestMode.AXE,
		&"axe",
		12.0,
		0.0,
		VegetationType.SupportRule.ROOT_POINTS,
		true,
		true,
		false
	)
	pine_tree.instance_scale = 1.0
	pine_tree.support_radius = 1.1
	pine_tree.support_height = 8.0
	pine_tree.source_mesh = tree_source_mesh
	pine_tree.mesh_source_transform = tree_source_transform
	pine_tree.material = tree_source_material
	pine_tree.support_points = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(0.5, 0.0, 0.0),
		Vector3(-0.5, 0.0, 0.0)
	]
	pine_tree.drops = [
		{"id": "wood", "amount": 5},
		{"id": "sap", "amount": 1}
	]
	registry.add_type(pine_tree)

	var dead_tree: VegetationType = registry._make_type(
		&"dead_tree",
		"Dead Tree",
		VegetationType.Category.TREE,
		tree_source,
		VegetationType.RenderMode.INDIVIDUAL_INSTANCE,
		VegetationType.HarvestMode.AXE,
		&"axe",
		8.0,
		0.0,
		VegetationType.SupportRule.ROOT_POINTS,
		true,
		true,
		false
	)
	dead_tree.instance_scale = 0.9
	dead_tree.support_radius = 1.1
	dead_tree.support_height = 7.0
	dead_tree.source_mesh = tree_source_mesh
	dead_tree.mesh_source_transform = tree_source_transform
	dead_tree.material = tree_source_material
	dead_tree.support_points = [
		Vector3(0.0, 0.0, 0.0)
	]
	dead_tree.drops = [
		{"id": "wood", "amount": 3}
	]
	registry.add_type(dead_tree)

	var stump: VegetationType = registry._make_type(
		&"stump",
		"Stump",
		VegetationType.Category.STUMP,
		"",
		VegetationType.RenderMode.INDIVIDUAL_INSTANCE,
		VegetationType.HarvestMode.AXE,
		&"axe",
		5.0,
		0.0,
		VegetationType.SupportRule.GROUND,
		false,
		false,
		false
	)
	stump.instance_scale = 0.70
	stump.support_radius = 0.52
	stump.support_height = 0.55
	stump.drops = [
		{"id": "wood", "amount": 1}
	]
	var stump_material := _make_foliage_material(Color(0.38, 0.28, 0.16, 1.0))
	stump.source_mesh = _make_simple_blob_mesh(stump_material, 0.36, 0.40, 0.34, 0.56, 8, Color(0.38, 0.28, 0.16, 1.0))
	registry.add_type(stump)

	var fallen_log: VegetationType = registry._make_type(
		&"fallen_log",
		"Fallen Log",
		VegetationType.Category.LOG,
		tree_source,
		VegetationType.RenderMode.INDIVIDUAL_INSTANCE,
		VegetationType.HarvestMode.AXE,
		&"axe",
		6.0,
		0.0,
		VegetationType.SupportRule.GROUND,
		true,
		false,
		false
	)
	fallen_log.instance_scale = 1.1
	fallen_log.support_radius = 1.0
	fallen_log.support_height = 1.0
	fallen_log.mesh_source_transform = tree_source_transform
	fallen_log.material = tree_source_material
	fallen_log.drops = [
		{"id": "wood", "amount": 4}
	]
	registry.add_type(fallen_log)

	return registry
