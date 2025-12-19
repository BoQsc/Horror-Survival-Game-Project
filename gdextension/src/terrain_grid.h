#ifndef TERRAIN_GRID_H
#define TERRAIN_GRID_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/node3d.hpp>
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

protected:
    static void _bind_methods();

public:
    TerrainGrid();
    ~TerrainGrid();

    // Manually register a chunk as active (e.g. after async load)
    void add_chunk(Vector3i coord);
    // Manually remove a chunk (e.g. after unload)
    void remove_chunk(Vector3i coord);
    // Check if chunk is tracked
    bool has_chunk(Vector3i coord);
    // Clear all tracking
    void clear();

    // Main update function
    // is_above_ground: true = load only Y=0, false = load spherical volume
    Dictionary update(Vector3 viewer_pos, int render_distance, bool is_above_ground, int chunk_stride);

    // Optimized height lookup for vegetation (Process entire chunk at once)
    // Returns PackedFloat32Array of heights. If not found, returns -1000.0.
    // Order: x + z * (size / step)
    PackedFloat32Array get_chunk_height_map(const PackedFloat32Array &density, int size, int step);
};

}

#endif
