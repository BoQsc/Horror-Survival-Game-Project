#include "terrain_grid.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/core/math.hpp>

namespace godot {

void TerrainGrid::_bind_methods() {
    ClassDB::bind_method(D_METHOD("add_chunk", "coord"), &TerrainGrid::add_chunk);
    ClassDB::bind_method(D_METHOD("remove_chunk", "coord"), &TerrainGrid::remove_chunk);
    ClassDB::bind_method(D_METHOD("has_chunk", "coord"), &TerrainGrid::has_chunk);
    ClassDB::bind_method(D_METHOD("clear"), &TerrainGrid::clear);
    ClassDB::bind_method(D_METHOD("update", "viewer_pos", "render_distance", "is_above_ground", "chunk_stride"), &TerrainGrid::update);
    ClassDB::bind_method(D_METHOD("get_chunk_height_map", "density", "size", "step"), &TerrainGrid::get_chunk_height_map);
}

TerrainGrid::TerrainGrid() {}

TerrainGrid::~TerrainGrid() {}

void TerrainGrid::add_chunk(Vector3i coord) {
    active_chunks.insert(coord);
}

void TerrainGrid::remove_chunk(Vector3i coord) {
    active_chunks.erase(coord);
}

bool TerrainGrid::has_chunk(Vector3i coord) {
    return active_chunks.has(coord);
}

void TerrainGrid::clear() {
    active_chunks.clear();
}

Dictionary TerrainGrid::update(Vector3 viewer_pos, int render_distance, bool is_above_ground, int chunk_stride) {
    Dictionary result;
    Array to_load;
    Array to_unload;

    int center_x = (int)Math::floor(viewer_pos.x / chunk_stride);
    int center_y = (int)Math::floor(viewer_pos.y / chunk_stride);
    int center_z = (int)Math::floor(viewer_pos.z / chunk_stride);

    // 1. Calculate Unloads
    // We iterate active_chunks (HashSet iteration is fast)
    // Godot CPP HashSet iterator usage:
    List<Vector3i> remove_list;
    
    for (const Vector3i &coord : active_chunks) {
        // Distance check
        double dx = (double)(coord.x - center_x);
        double dy = (double)(coord.y - center_y);
        double dz = (double)(coord.z - center_z);
        double dist_xz = Math::sqrt(dx * dx + dz * dz);

        bool should_unload = false;
        
        // Match GDScript logic: "Never unload terrain layers from MIN_Y_LAYER (-20) to 1 within horizontal range"
        // This is a "Column Protection" rule
        bool is_terrain_layer = (coord.y >= -20 && coord.y <= 1);
        
        if (dist_xz > render_distance + 2) {
            should_unload = true;
        } else if (!is_terrain_layer && Math::abs(dy) > 3) {
            // For non-terrain layers (flying high or deep underground clutter?), unload if vertical dist is large
            should_unload = true;
        }

        if (should_unload) {
            to_unload.append(coord);
            remove_list.push_back(coord);
        }
    }

    // Remove unloaded chunks from internal set immediately (so load check knows they are gone? No, load check checks existence)
    // Actually, we usually want to sync this with the main thread.
    // But if we return "to_unload", the main thread will remove them.
    // Should we remove them from 'active_chunks' here?
    // If we do, and the main thread fails to unload, we are out of sync.
    // Better to let Main Thread call 'remove_chunk' explicitly.
    // However, for the 'load' step below, we need to know what IS active.
    // Let's assume the main thread will handle the unloads.
    
    // 2. Calculate Loads
    // Iterate volume
    
    // Define Y layers to scan
    // GDScript: if is_above_ground, load only Y=0. Else load center_y -1, 0, +1, and 0.
    List<int> y_layers;
    if (is_above_ground) {
        y_layers.push_back(0);
    } else {
        y_layers.push_back(center_y - 1);
        y_layers.push_back(center_y);
        y_layers.push_back(center_y + 1);
        if (center_y != 0) y_layers.push_back(0); // Always keep Y=0 loaded?
    }

    // Square loop around center
    int r = render_distance;
    
    for (int x = center_x - r; x <= center_x + r; ++x) {
        for (int z = center_z - r; z <= center_z + r; ++z) {
            // Circular check
            double dist_sq = (double)((x - center_x) * (x - center_x) + (z - center_z) * (z - center_z));
            if (dist_sq > r * r) continue;

            for (int y : y_layers) {
                if (y < -20 || y > 40) continue; // Bounds check

                Vector3i coord(x, y, z);
                if (!active_chunks.has(coord)) {
                    to_load.append(coord);
                    
                    // Limit load count per frame? 
                    // No, return ALL candidates, let GDScript throttle.
                    // Or we can throttle here?
                    // Better to return all candidates and let GDScript pick the first N.
                }
            }
        }
    }

    result["load"] = to_load;
    result["unload"] = to_unload;
    return result;
}

// namespace godot continue

PackedFloat32Array TerrainGrid::get_chunk_height_map(const PackedFloat32Array &density, int size, int step) {
    PackedFloat32Array heights;
    int density_size = 33; // Default for 32 stride + 1 padding
    if (density.size() < density_size * density_size * density_size) {
        // Safety check, return empty or full of errors?
        // Just return empty, script can check size
        return heights;
    }
    
    // Reserve memory
    int grid_points_side = (size + step - 1) / step; // ceil div? No, range is exclusive in GDScript: 0, 2, ... < 32. Count = 16.
    // GDScript: range(0, 32, 2) -> 0, 2, ..., 30. (16 points)
    grid_points_side = (size + step - 1) / step; 
    
    // But exact count is `(size - 1) / step + 1` if inclusive?
    // range(0, size, step): count = ceil(size/step).
    int count = 0;
    for (int i = 0; i < size; i+=step) count++;
    
    heights.resize(count * count);
    
    int write_idx = 0;
    
    for (int x = 0; x < size; x += step) {
        for (int z = 0; z < size; z += step) {
            float height = -1000.0f;
            
            // Scan Y column from top to bottom
            float prev_dens = 1.0f;
            
            // Indexing: local_x + (local_z * 33 * 33) + (iy * 33)
            int col_offset = x + (z * density_size * density_size);
            
            for (int iy = density_size - 1; iy >= 0; iy--) {
                int index = col_offset + (iy * density_size);
                float d = density[index];
                
                if (d < 0.0f) {
                    // Surface found
                    float local_h;
                    if (iy < density_size - 1) {
                         float t = prev_dens / (prev_dens - d);
                         local_h = (float)(iy + 1) - t;
                    } else {
                         local_h = (float)iy;
                    }
                    height = local_h;
                    break; 
                }
                prev_dens = d;
            }
            heights[write_idx++] = height;
        }
    }
    
    return heights;
}


} // namespace godot
