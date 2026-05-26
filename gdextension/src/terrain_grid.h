#ifndef TERRAIN_GRID_H
#define TERRAIN_GRID_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/templates/hash_set.hpp>

namespace godot {

class TerrainGrid : public RefCounted {
    GDCLASS(TerrainGrid, RefCounted);

private:
    HashSet<Vector3i> active_chunks;
    HashSet<Vector3i> collision_ready_chunks;
    HashSet<Vector3i> active_collision_chunks;
    bool update_cache_valid = false;
    Vector3i cached_center_chunk = Vector3i(0, 0, 0);
    int cached_render_distance = -1;
    bool cached_is_above_ground = false;
    int cached_chunk_stride = -1;
    int unload_hysteresis_chunks = 0;
    bool prioritize_stream_candidates = true;
    Array cached_load_candidates;
    Array cached_unload_candidates;
    int cached_load_cursor = 0;
    int cached_unload_cursor = 0;
    bool cached_load_candidates_valid = false;
    bool cached_unload_candidates_valid = false;

protected:
    static void _bind_methods();

public:
    TerrainGrid();
    ~TerrainGrid();

    // Manually register a chunk as active (e.g. after async load)
    void add_chunk(Vector3i coord);
    // Manually remove a chunk (e.g. after unload)
    void remove_chunk(Vector3i coord);
    // Mark whether the chunk's collision body has been created and is ready for raycasts.
    void set_chunk_collision_ready(Vector3i coord, bool ready);
    // Track whether terrain collision is currently enabled for a chunk.
    void set_chunk_collision_active(Vector3i coord, bool active);
    // Check if chunk is tracked
    bool has_chunk(Vector3i coord);
    // Check whether terrain collision is ready around a position.
    bool is_collision_ready_at(Vector3 position, int chunk_stride);
    // Count chunks whose collision bodies are currently ready.
    int get_collision_ready_chunk_count();
    // Count chunks whose collision is currently enabled.
    int get_active_collision_chunk_count();
    // Count chunks tracked by the native terrain grid.
    int get_active_chunk_count();
    void set_unload_hysteresis_chunks(int p_hysteresis_chunks);
    int get_unload_hysteresis_chunks() const;
    void set_prioritize_stream_candidates(bool p_prioritize);
    bool get_prioritize_stream_candidates() const;
    // Clear all tracking
    void clear();

    // Main update function
    // is_above_ground: true = load only Y=0, false = load spherical volume
    Dictionary update(Vector3 viewer_pos, int render_distance, bool is_above_ground, int chunk_stride, int load_chunks_per_frame_limit, int unload_chunks_per_frame_limit);

    // Build terrain collision proximity candidate lists in native code.
    Dictionary get_collision_proximity_update(Vector3i center_chunk, int collision_distance, int collision_prewarm_distance, int min_y_layer, int max_y_layer, bool shared_collision_body_enabled);

    // Optimized height lookup for vegetation (Process entire chunk at once)
    // Returns PackedFloat32Array of heights. If not found, returns -1000.0.
    // Order: x + z * (size / step)
    PackedFloat32Array get_chunk_height_map(const PackedFloat32Array &density, int size, int step);
    PackedFloat32Array get_world_map_road_block_samples(const PackedByteArray &road_data, int road_width, int road_height, int chunk_origin_x, int chunk_origin_z, int chunk_stride, int step, double world_map_half, double world_map_size);
    PackedFloat32Array get_world_map_water_block_samples(const PackedByteArray &water_data, int water_width, int water_height, int chunk_origin_x, int chunk_origin_z, int chunk_stride, int step, const PackedFloat32Array &terrain_heights, double world_map_half, double water_level);
};

}

#endif
