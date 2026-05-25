#include "terrain_grid.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/core/math.hpp>
#include <algorithm>
#include <vector>

namespace godot {

namespace {

struct TerrainCandidate {
    Vector3i coord;
    int dist_sq = 0;
};

} // namespace

void TerrainGrid::_bind_methods() {
    ClassDB::bind_method(D_METHOD("add_chunk", "coord"), &TerrainGrid::add_chunk);
    ClassDB::bind_method(D_METHOD("remove_chunk", "coord"), &TerrainGrid::remove_chunk);
    ClassDB::bind_method(D_METHOD("set_chunk_collision_ready", "coord", "ready"), &TerrainGrid::set_chunk_collision_ready);
    ClassDB::bind_method(D_METHOD("set_chunk_collision_active", "coord", "active"), &TerrainGrid::set_chunk_collision_active);
    ClassDB::bind_method(D_METHOD("has_chunk", "coord"), &TerrainGrid::has_chunk);
    ClassDB::bind_method(D_METHOD("is_collision_ready_at", "position", "chunk_stride"), &TerrainGrid::is_collision_ready_at);
    ClassDB::bind_method(D_METHOD("get_collision_ready_chunk_count"), &TerrainGrid::get_collision_ready_chunk_count);
    ClassDB::bind_method(D_METHOD("get_active_collision_chunk_count"), &TerrainGrid::get_active_collision_chunk_count);
    ClassDB::bind_method(D_METHOD("get_active_chunk_count"), &TerrainGrid::get_active_chunk_count);
    ClassDB::bind_method(D_METHOD("clear"), &TerrainGrid::clear);
    ClassDB::bind_method(D_METHOD("update", "viewer_pos", "render_distance", "is_above_ground", "chunk_stride", "load_chunks_per_frame_limit", "unload_chunks_per_frame_limit"), &TerrainGrid::update);
    ClassDB::bind_method(D_METHOD("get_collision_proximity_update", "center_chunk", "collision_distance", "collision_prewarm_distance", "min_y_layer", "max_y_layer", "shared_collision_body_enabled"), &TerrainGrid::get_collision_proximity_update);
    ClassDB::bind_method(D_METHOD("get_chunk_height_map", "density", "size", "step"), &TerrainGrid::get_chunk_height_map);
}

TerrainGrid::TerrainGrid() {}

TerrainGrid::~TerrainGrid() {
    clear();
}

void TerrainGrid::add_chunk(Vector3i coord) {
    active_chunks.insert(coord);
    collision_ready_chunks.erase(coord);
    active_collision_chunks.erase(coord);
    update_cache_valid = false;
}

void TerrainGrid::remove_chunk(Vector3i coord) {
    active_chunks.erase(coord);
    collision_ready_chunks.erase(coord);
    active_collision_chunks.erase(coord);
    update_cache_valid = false;
}

void TerrainGrid::set_chunk_collision_ready(Vector3i coord, bool ready) {
    if (ready) {
        collision_ready_chunks.insert(coord);
    } else {
        collision_ready_chunks.erase(coord);
    }
}

void TerrainGrid::set_chunk_collision_active(Vector3i coord, bool active) {
    if (active) {
        active_collision_chunks.insert(coord);
    } else {
        active_collision_chunks.erase(coord);
    }
}

bool TerrainGrid::has_chunk(Vector3i coord) {
    return active_chunks.has(coord);
}

bool TerrainGrid::is_collision_ready_at(Vector3 position, int chunk_stride) {
    if (chunk_stride <= 0) {
        return false;
    }

    const int chunk_x = static_cast<int>(Math::floor(position.x / chunk_stride));
    const int chunk_y = static_cast<int>(Math::floor(position.y / chunk_stride));
    const int chunk_z = static_cast<int>(Math::floor(position.z / chunk_stride));

    for (int dy = -1; dy <= 1; ++dy) {
        const Vector3i coord(chunk_x, chunk_y + dy, chunk_z);
        if (collision_ready_chunks.has(coord)) {
            return true;
        }
    }

    return false;
}

int TerrainGrid::get_collision_ready_chunk_count() {
    return collision_ready_chunks.size();
}

int TerrainGrid::get_active_collision_chunk_count() {
    return active_collision_chunks.size();
}

int TerrainGrid::get_active_chunk_count() {
    return active_chunks.size();
}

void TerrainGrid::clear() {
    active_chunks.clear();
    collision_ready_chunks.clear();
    active_collision_chunks.clear();
    update_cache_valid = false;
    cached_load_candidates.clear();
    cached_unload_candidates.clear();
    cached_load_cursor = 0;
    cached_unload_cursor = 0;
    cached_load_candidates_valid = false;
    cached_unload_candidates_valid = false;
}

Dictionary TerrainGrid::update(Vector3 viewer_pos, int render_distance, bool is_above_ground, int chunk_stride, int load_chunks_per_frame_limit, int unload_chunks_per_frame_limit) {
    Dictionary result;
    Array to_load;
    Array to_unload;

    if (load_chunks_per_frame_limit <= 0 && unload_chunks_per_frame_limit <= 0) {
        result["load"] = to_load;
        result["unload"] = to_unload;
        return result;
    }

    int center_x = (int)Math::floor(viewer_pos.x / chunk_stride);
    int center_y = (int)Math::floor(viewer_pos.y / chunk_stride);
    int center_z = (int)Math::floor(viewer_pos.z / chunk_stride);
    Vector3i center_chunk(center_x, center_y, center_z);

    bool cache_changed = !update_cache_valid
        || cached_center_chunk != center_chunk
        || cached_render_distance != render_distance
        || cached_is_above_ground != is_above_ground
        || cached_chunk_stride != chunk_stride;

    if (cache_changed) {
        cached_load_candidates.clear();
        cached_unload_candidates.clear();
        cached_load_cursor = 0;
        cached_unload_cursor = 0;
        cached_load_candidates_valid = false;
        cached_unload_candidates_valid = false;
        cached_center_chunk = center_chunk;
        cached_render_distance = render_distance;
        cached_is_above_ground = is_above_ground;
        cached_chunk_stride = chunk_stride;
        update_cache_valid = true;
    }

    if (unload_chunks_per_frame_limit > 0 && !cached_unload_candidates_valid) {
        double unload_distance_sq = (double)(render_distance + 2) * (double)(render_distance + 2);
        std::vector<TerrainCandidate> unload_candidates;
        unload_candidates.reserve(active_chunks.size());

        // Calculate unloads from the current active set.
        for (const Vector3i &coord : active_chunks) {
            double dx = (double)(coord.x - center_x);
            double dy = (double)(coord.y - center_y);
            double dz = (double)(coord.z - center_z);
            double dist_xz_sq = dx * dx + dz * dz;

            bool should_unload = false;
            bool is_terrain_layer = (coord.y >= -20 && coord.y <= 1);

            if (dist_xz_sq > unload_distance_sq) {
                should_unload = true;
            } else if (!is_terrain_layer && Math::abs(dy) > 3) {
                should_unload = true;
            }

            if (should_unload) {
                TerrainCandidate candidate;
                candidate.coord = coord;
                candidate.dist_sq = (int)dist_xz_sq;
                unload_candidates.push_back(candidate);
            }
        }

        std::stable_sort(unload_candidates.begin(), unload_candidates.end(), [](const TerrainCandidate &a, const TerrainCandidate &b) {
            if (a.dist_sq != b.dist_sq) {
                return a.dist_sq > b.dist_sq;
            }
            if (a.coord.y != b.coord.y) {
                return a.coord.y > b.coord.y;
            }
            if (a.coord.x != b.coord.x) {
                return a.coord.x > b.coord.x;
            }
            return a.coord.z > b.coord.z;
        });

        for (const TerrainCandidate &candidate : unload_candidates) {
            cached_unload_candidates.append(candidate.coord);
        }

        cached_unload_candidates_valid = true;
    }

    if (load_chunks_per_frame_limit > 0 && !cached_load_candidates_valid) {
        // Calculate Loads
        List<int> y_layers;
        if (is_above_ground) {
            y_layers.push_back(0);
        } else {
            y_layers.push_back(center_y - 1);
            y_layers.push_back(center_y);
            y_layers.push_back(center_y + 1);
            if (center_y != 0) {
                y_layers.push_back(0);
            }
        }

        int r = render_distance;
        int r_sq = r * r;
        std::vector<TerrainCandidate> load_candidates;
        for (int x = center_x - r; x <= center_x + r; ++x) {
            for (int z = center_z - r; z <= center_z + r; ++z) {
                double dist_sq = (double)((x - center_x) * (x - center_x) + (z - center_z) * (z - center_z));
                if (dist_sq > r_sq) {
                    continue;
                }

                for (int y : y_layers) {
                    if (y < -20 || y > 40) {
                        continue;
                    }

                    Vector3i coord(x, y, z);
                    if (!active_chunks.has(coord)) {
                        TerrainCandidate candidate;
                        candidate.coord = coord;
                        candidate.dist_sq = (int)dist_sq;
                        load_candidates.push_back(candidate);
                    }
                }
            }
        }

        std::stable_sort(load_candidates.begin(), load_candidates.end(), [](const TerrainCandidate &a, const TerrainCandidate &b) {
            if (a.dist_sq != b.dist_sq) {
                return a.dist_sq < b.dist_sq;
            }
            if (a.coord.y != b.coord.y) {
                return a.coord.y < b.coord.y;
            }
            if (a.coord.x != b.coord.x) {
                return a.coord.x < b.coord.x;
            }
            return a.coord.z < b.coord.z;
        });

        for (const TerrainCandidate &candidate : load_candidates) {
            cached_load_candidates.append(candidate.coord);
        }

        cached_load_candidates_valid = true;
    }

    int load_count = 0;
    int unload_count = 0;
    while (cached_unload_cursor < cached_unload_candidates.size() && unload_count < unload_chunks_per_frame_limit) {
        to_unload.append(cached_unload_candidates[cached_unload_cursor]);
        cached_unload_cursor++;
        unload_count++;
    }

    while (cached_load_cursor < cached_load_candidates.size() && load_count < load_chunks_per_frame_limit) {
        to_load.append(cached_load_candidates[cached_load_cursor]);
        cached_load_cursor++;
        load_count++;
    }

    result["load"] = to_load;
    result["unload"] = to_unload;
    return result;
}

Dictionary TerrainGrid::get_collision_proximity_update(Vector3i center_chunk, int collision_distance, int collision_prewarm_distance, int min_y_layer, int max_y_layer, bool shared_collision_body_enabled) {
    Dictionary result;
    Array enable;
    Array disable;
    Array prewarm;

    const int max_collision_distance = collision_prewarm_distance > collision_distance ? collision_prewarm_distance : collision_distance;
    const int active_distance = shared_collision_body_enabled ? max_collision_distance : collision_distance;
    const int active_distance_sq = active_distance * active_distance;
    const int prewarm_distance = max_collision_distance;
    const int prewarm_distance_sq = prewarm_distance * prewarm_distance;
    const int collision_distance_sq = collision_distance * collision_distance;
    const int min_y = min_y_layer > center_chunk.y - 2 ? min_y_layer : center_chunk.y - 2;
    const int max_y = max_y_layer < center_chunk.y + 2 ? max_y_layer : center_chunk.y + 2;

    HashSet<Vector3i> desired_collision_chunks;

    for (int x = center_chunk.x - active_distance; x <= center_chunk.x + active_distance; ++x) {
        for (int z = center_chunk.z - active_distance; z <= center_chunk.z + active_distance; ++z) {
            const int dx = x - center_chunk.x;
            const int dz = z - center_chunk.z;
            if (dx * dx + dz * dz > active_distance_sq) {
                continue;
            }

            for (int y = min_y; y <= max_y; ++y) {
                const Vector3i coord(x, y, z);
                desired_collision_chunks.insert(coord);
                if (active_chunks.has(coord) && !active_collision_chunks.has(coord)) {
                    enable.append(coord);
                }
            }
        }
    }

    for (const Vector3i &coord : active_collision_chunks) {
        if (!active_chunks.has(coord) || !desired_collision_chunks.has(coord)) {
            disable.append(coord);
        }
    }

    if (!shared_collision_body_enabled && prewarm_distance > collision_distance) {
        for (int x = center_chunk.x - prewarm_distance; x <= center_chunk.x + prewarm_distance; ++x) {
            for (int z = center_chunk.z - prewarm_distance; z <= center_chunk.z + prewarm_distance; ++z) {
                const int dx = x - center_chunk.x;
                const int dz = z - center_chunk.z;
                const int dist_xz_sq = dx * dx + dz * dz;
                if (dist_xz_sq > prewarm_distance_sq || dist_xz_sq <= collision_distance_sq) {
                    continue;
                }

                for (int y = min_y; y <= max_y; ++y) {
                    const Vector3i coord(x, y, z);
                    if (active_chunks.has(coord)) {
                        prewarm.append(coord);
                    }
                }
            }
        }
    }

    result["enable"] = enable;
    result["disable"] = disable;
    result["prewarm"] = prewarm;
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
