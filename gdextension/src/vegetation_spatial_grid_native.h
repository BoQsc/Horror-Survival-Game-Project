#ifndef VEGETATION_SPATIAL_GRID_NATIVE_H
#define VEGETATION_SPATIAL_GRID_NATIVE_H

#include <cstdint>
#include <unordered_set>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class VegetationSpatialGridNative : public RefCounted {
    GDCLASS(VegetationSpatialGridNative, RefCounted);

private:
    std::unordered_set<int64_t> chunk_keys;

    static int64_t key_for_coord(const Vector2i &coord);

protected:
    static void _bind_methods();

public:
    VegetationSpatialGridNative();
    ~VegetationSpatialGridNative();

    void clear();
    void set_chunk(const Vector2i &coord);
    void remove_chunk(const Vector2i &coord);
    bool has_chunk(const Vector2i &coord) const;
    int get_chunk_count() const;
    Array query_chunk_coords_in_aabb(const AABB &bounds, int chunk_size) const;
};

}

#endif
