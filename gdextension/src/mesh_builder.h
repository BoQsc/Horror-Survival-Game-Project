#ifndef MESH_BUILDER_H
#define MESH_BUILDER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/box_shape3d.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture3d.hpp>
#include <godot_cpp/classes/concave_polygon_shape3d.hpp>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <string>
#include <unordered_map>

namespace godot {

class MeshBuilder : public RefCounted {
    GDCLASS(MeshBuilder, RefCounted)

protected:
    static void _bind_methods();

private:
    Ref<BoxShape3D> _get_cached_box_shape(const Vector3i& size);
    std::unordered_map<std::string, Ref<BoxShape3D>> _box_shape_cache;

public:
    MeshBuilder();
    ~MeshBuilder();

    // Native implementation of build_mesh
    // Expects: [pos.x, pos.y, pos.z, norm.x, norm.y, norm.z, col.r, col.g, col.b, ...]
    Ref<ArrayMesh> build_mesh_native(const PackedFloat32Array& data, int stride);

	// Native implementation of 3D texture creation
	// Converts raw density bytes directly to ImageTexture3D
	Ref<ImageTexture3D> create_material_texture(const PackedByteArray& data, int width, int height, int depth);

	// Fast check for player-placed material overrides.
	// Returns true if any voxel material byte is >= 100.
	bool has_player_material_overrides(const PackedByteArray& data, int width, int height, int depth);

	// Native implementation of collision shape creation
	// Generates ConcavePolygonShape3D directly from the building mesh vertex + index buffers
	Ref<ConcavePolygonShape3D> build_collision_shape(const PackedFloat32Array& data, int stride);
	Ref<ConcavePolygonShape3D> build_collision_shape_indexed(const PackedByteArray& vertex_bytes, const PackedByteArray& index_bytes, int vertex_count, int index_count);
	
	// Fast conversion from PackedByteArray to PackedFloat32Array
	PackedFloat32Array bytes_to_floats(const PackedByteArray& data);
	
	// Fast ArrayMesh creation specifically for the Building Greedy Mesher
	// Bypasses GDScript Variant loop unpacking 
	Ref<ArrayMesh> build_building_mesh(const PackedByteArray& vertex_bytes, const PackedByteArray& normal_bytes, const PackedByteArray& uv_bytes, const PackedByteArray& index_bytes, int vertex_count, int index_count);

	// Native CPU replacement for the building GPU compute mesher.
	// Builds the same building geometry directly from voxel bytes and metadata.
	Dictionary build_building_mesh_from_voxels(const PackedByteArray& voxel_bytes, const PackedByteArray& voxel_meta, bool use_box_collision, int chunk_size);

	// Packs world-map prefab blocks into per-chunk voxel batches.
	Array pack_world_map_block_batches(const Array& rotated_blocks, const Vector3& spawn_pos, int chunk_size);

	// Packs raw prefab blocks into per-chunk voxel batches while applying rotation natively.
	Array pack_rotated_world_map_block_batches(const Array& prefab_blocks, int rotation, const Vector3& spawn_pos, int chunk_size);

	// Builds merged world-map collision boxes from voxel occupancy.
	Array build_collision_boxes_from_voxels(const PackedByteArray& voxel_bytes, int chunk_size);

	// Applies merged world-map collision boxes to an existing body RID.
	bool apply_world_map_collision_boxes(const RID& body_rid, const Array& collision_boxes);

	// Builds a simple heightfield mesh from a regular height grid.
	// Heights are expected to already be in world space.
	Ref<ArrayMesh> build_heightfield_mesh(const PackedFloat32Array& heights, int width, int depth, float cell_size, float skirt_depth = 0.0f);

	// Builds a Transvoxel-style block mesh directly from a baked world-map heightmap.
	// This is the seam-safe path intended to replace the old heightfield far-ring prototype.
	Ref<ArrayMesh> build_transvoxel_heightfield_mesh(
		const PackedByteArray& heightmap_bytes,
		int image_width,
		int image_height,
		float map_size,
		float height_scale,
		const Vector3& block_base,
		const Vector3& block_size,
		int subdivisions,
		int transition_sides_mask
	);

	// Merges a list of one-surface heightfield meshes into a single mesh.
	// Each entry is expected to be a Dictionary with keys:
	//   mesh: ArrayMesh
	//   offset: Vector3
	Ref<ArrayMesh> merge_heightfield_meshes(const Array& mesh_specs);
};

}

#endif
