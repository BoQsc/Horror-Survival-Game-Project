#ifndef PREFAB_GEOMETRY_NATIVE_H
#define PREFAB_GEOMETRY_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

namespace godot {

class PrefabGeometryNative : public RefCounted {
	GDCLASS(PrefabGeometryNative, RefCounted)

protected:
	static void _bind_methods();

public:
	PrefabGeometryNative();
	~PrefabGeometryNative();

	Vector3i rotate_offset(const Vector3i &offset, int rotation) const;
	Vector3 rotate_vector3_offset(const Vector3 &offset, int rotation) const;
	Vector3 get_grid_correction(int rotation) const;

	Dictionary build_rotated_bounds_from_offsets(const Array &offsets, int rotation) const;
	Dictionary build_local_rect_from_offsets(const Array &offsets, const Vector3i &declared_size) const;
	Dictionary rotate_local_rect_bounds(const Dictionary &rect, int rotation) const;

	Dictionary parse_local_rect_2d(const Variant &raw_rect, const Dictionary &fallback_rect, const Vector3i &declared_size) const;
	Array parse_local_volumes(const Array &raw_volumes, const Vector3i &declared_size, int min_y, int max_y) const;

	Dictionary build_local_cell_set_from_volumes(const Array &volumes) const;
	Dictionary inflate_local_cell_set(const Dictionary &cell_set, int padding) const;

	Array build_rotated_carve_segments(const Array &local_cells, int rotation) const;
	Array build_rotated_segments_from_volumes(const Array &volumes, int rotation) const;
    Array pick_nearest_candidates(const Array &candidates, int max_count) const;
	int pick_nearest_pending_vegetation_chunk(const Array &pending_chunks, const Vector3 &viewer_pos, int chunk_stride) const;
	Array pick_nearby_vegetation_candidates(const Dictionary &chunk_data, const String &list_key, const String &item_key, const Vector3 &player_pos, int chunk_stride, double collider_distance, int max_count) const;
	Dictionary find_nearest_vegetation_ray_hit(const Dictionary &chunk_data, const String &list_key, const String &kind, const Vector3 &origin, const Vector3 &direction, double max_distance, double radius, double height, bool scale_by_entry) const;
	Dictionary find_nearest_tree_visual_bounds_ray_hit(const Dictionary &chunk_data, const String &list_key, const Vector3 &origin, const Vector3 &direction, double max_distance, const AABB &mesh_bounds, const Transform3D &base_transform, const Vector3 &rotation_fix, double bounds_padding) const;
	Dictionary resolve_tree_body_collision(const Dictionary &chunk_tree_data, const Vector3 &body_origin, double body_radius, double body_height, int chunk_stride, double collision_radius, double collision_height) const;
	Dictionary build_world_map_height_biome_bytes(int map_size, int world_size, int world_seed, double noise_frequency, double terrain_height, double max_height, int grass_material_id, int sand_material_id, int snow_material_id, int gravel_material_id) const;

	Array build_vegetation_instances(const Dictionary &config, const PackedFloat32Array &height_map) const;
	Dictionary build_vegetation_instances_with_render_payload(const Dictionary &config, const PackedFloat32Array &height_map, const Transform3D &render_space_inverse, const AABB &mesh_bounds) const;
	PackedFloat32Array build_noise_samples(const Callable &noise_sampler, int chunk_origin_x, int chunk_origin_z, int chunk_stride, int step, bool use_noise) const;
	Array filter_removed_vegetation_entries(const Array &entries, const Dictionary &removed_lookup) const;
	Dictionary build_global_vegetation_render_payload(const Array &instances, const Transform3D &render_space_inverse, const AABB &mesh_bounds) const;
	Dictionary build_global_vegetation_cluster_render_payload(const Dictionary &payloads, const Array &coord_keys, double bounds_padding) const;
	PackedFloat32Array pack_multimesh_buffer_from_instances(const Array &instances) const;

    Array get_enclosed_below_grade_empty_cells(const Dictionary &solid_cells, const Vector3i &declared_size, int min_y, int grade_y) const;
    Dictionary build_required_below_grade_excavation_cells(const Array &enclosed_cells, const Array &stair_cells, int min_y, int grade_y) const;
	Array find_surface_breach_excavation_cells(const Dictionary &excavated_cells, const Dictionary &surface_rect, int grade_y) const;
};

}

#endif // PREFAB_GEOMETRY_NATIVE_H
