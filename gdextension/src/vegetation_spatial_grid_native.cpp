#include "vegetation_spatial_grid_native.h"

#include <algorithm>
#include <cmath>

#include <godot_cpp/core/class_db.hpp>

namespace godot {

int64_t VegetationSpatialGridNative::key_for_coord(const Vector2i &coord) {
    const uint64_t x = static_cast<uint32_t>(coord.x);
    const uint64_t y = static_cast<uint32_t>(coord.y);
    return static_cast<int64_t>((x << 32) | y);
}

void VegetationSpatialGridNative::_bind_methods() {
    ClassDB::bind_method(D_METHOD("clear"), &VegetationSpatialGridNative::clear);
    ClassDB::bind_method(D_METHOD("set_chunk", "coord"), &VegetationSpatialGridNative::set_chunk);
    ClassDB::bind_method(D_METHOD("remove_chunk", "coord"), &VegetationSpatialGridNative::remove_chunk);
    ClassDB::bind_method(D_METHOD("has_chunk", "coord"), &VegetationSpatialGridNative::has_chunk);
    ClassDB::bind_method(D_METHOD("get_chunk_count"), &VegetationSpatialGridNative::get_chunk_count);
    ClassDB::bind_method(D_METHOD("query_chunk_coords_in_aabb", "bounds", "chunk_size"), &VegetationSpatialGridNative::query_chunk_coords_in_aabb);
}

VegetationSpatialGridNative::VegetationSpatialGridNative() {}

VegetationSpatialGridNative::~VegetationSpatialGridNative() {
    clear();
}

void VegetationSpatialGridNative::clear() {
    chunk_keys.clear();
}

void VegetationSpatialGridNative::set_chunk(const Vector2i &coord) {
    chunk_keys.insert(key_for_coord(coord));
}

void VegetationSpatialGridNative::remove_chunk(const Vector2i &coord) {
    chunk_keys.erase(key_for_coord(coord));
}

bool VegetationSpatialGridNative::has_chunk(const Vector2i &coord) const {
    return chunk_keys.find(key_for_coord(coord)) != chunk_keys.end();
}

int VegetationSpatialGridNative::get_chunk_count() const {
    return static_cast<int>(chunk_keys.size());
}

Array VegetationSpatialGridNative::query_chunk_coords_in_aabb(const AABB &bounds, int chunk_size) const {
    Array result;
    if (chunk_size <= 0 || chunk_keys.empty()) {
        return result;
    }

    const Vector3 end = bounds.position + bounds.size;
    const float min_x = std::min(bounds.position.x, end.x);
    const float max_x = std::max(bounds.position.x, end.x);
    const float min_z = std::min(bounds.position.z, end.z);
    const float max_z = std::max(bounds.position.z, end.z);
    const int min_cx = static_cast<int>(std::floor(min_x / static_cast<float>(chunk_size)));
    const int max_cx = static_cast<int>(std::floor(max_x / static_cast<float>(chunk_size)));
    const int min_cz = static_cast<int>(std::floor(min_z / static_cast<float>(chunk_size)));
    const int max_cz = static_cast<int>(std::floor(max_z / static_cast<float>(chunk_size)));

    for (int x = min_cx; x <= max_cx; ++x) {
        for (int z = min_cz; z <= max_cz; ++z) {
            const Vector2i coord(x, z);
            if (has_chunk(coord)) {
                result.append(coord);
            }
        }
    }
    return result;
}

}
