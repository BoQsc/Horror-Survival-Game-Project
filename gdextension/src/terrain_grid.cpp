#include "terrain_grid.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/core/math.hpp>
#include <algorithm>
#include <cmath>
#include <vector>

namespace godot {

namespace {

struct TerrainCandidate {
    Vector3i coord;
    int dist_sq = 0;
};

static bool read_mask_byte_pixel(const PackedByteArray &data, int pixel_x, int pixel_y, int width, int height) {
    if (data.is_empty() || width <= 0 || height <= 0) {
        return false;
    }
    const int64_t pixel_count = int64_t(width) * int64_t(height);
    if (pixel_count <= 0) {
        return false;
    }
    const int bytes_per_pixel = std::max(int(data.size() / pixel_count), 1);
    const int64_t byte_index = (int64_t(pixel_y) * int64_t(width) + int64_t(pixel_x)) * int64_t(bytes_per_pixel);
    if (byte_index < 0 || byte_index >= data.size()) {
        return false;
    }
    return int(data[int(byte_index)]) >= 128;
}

static int sample_axis_count(int chunk_stride, int step) {
    if (chunk_stride <= 0 || step <= 0) {
        return 0;
    }
    return (chunk_stride + step - 1) / step;
}

static inline double clamp_double(double value, double min_value, double max_value) {
    return std::max(min_value, std::min(max_value, value));
}

static inline int clamp_int(int value, int min_value, int max_value) {
    return std::max(min_value, std::min(max_value, value));
}

static inline double lerp_double(double a, double b, double t) {
    return a + (b - a) * t;
}

static int read_r8_pixel(const PackedByteArray &data, int width, int height, int x, int y, int channel = 0) {
    if (data.is_empty() || width <= 0 || height <= 0) {
        return 0;
    }
    x = clamp_int(x, 0, width - 1);
    y = clamp_int(y, 0, height - 1);
    const int64_t pixel_count = int64_t(width) * int64_t(height);
    if (pixel_count <= 0) {
        return 0;
    }
    const int bytes_per_pixel = std::max(int(data.size() / pixel_count), 1);
    const int safe_channel = clamp_int(channel, 0, bytes_per_pixel - 1);
    const int64_t byte_index = (int64_t(y) * int64_t(width) + int64_t(x)) * int64_t(bytes_per_pixel) + int64_t(safe_channel);
    if (byte_index < 0 || byte_index >= data.size()) {
        return 0;
    }
    return int(data[int(byte_index)]);
}

static double sample_world_map_height(const PackedByteArray &heightmap_data, int width, int height, double world_x, double world_z, double map_half, double max_height) {
    if (heightmap_data.is_empty() || width <= 0 || height <= 0 || heightmap_data.size() < width * height) {
        return 1.0;
    }
    const double px = clamp_double(world_x + map_half, 0.0, double(width - 1));
    const double pz = clamp_double(world_z + map_half, 0.0, double(height - 1));
    const int x0 = int(std::floor(px));
    const int z0 = int(std::floor(pz));
    const int x1 = std::min(x0 + 1, width - 1);
    const int z1 = std::min(z0 + 1, height - 1);
    const double tx = px - double(x0);
    const double tz = pz - double(z0);
    const double h00 = double(read_r8_pixel(heightmap_data, width, height, x0, z0)) / 255.0;
    const double h10 = double(read_r8_pixel(heightmap_data, width, height, x1, z0)) / 255.0;
    const double h01 = double(read_r8_pixel(heightmap_data, width, height, x0, z1)) / 255.0;
    const double h11 = double(read_r8_pixel(heightmap_data, width, height, x1, z1)) / 255.0;
    const double h0 = lerp_double(h00, h10, tx);
    const double h1 = lerp_double(h01, h11, tx);
    return clamp_double(lerp_double(h0, h1, tz) * max_height, 1.0, 28.0);
}

static bool is_boundary_wall(double world_x, double world_z, double map_half) {
    const double dist_to_edge_x = std::min(world_x + map_half, map_half - world_x);
    const double dist_to_edge_z = std::min(world_z + map_half, map_half - world_z);
    return std::min(dist_to_edge_x, dist_to_edge_z) < 4.0;
}

static double material_height_at(const PackedByteArray &heightmap_data, int width, int height, double world_x, double world_z, double map_half, double max_height) {
    if (is_boundary_wall(world_x, world_z, map_half)) {
        return 28.0;
    }
    return sample_world_map_height(heightmap_data, width, height, world_x, world_z, map_half, max_height);
}

static double world_map_density(double world_x, double world_y, double world_z, double map_height, double map_half) {
    constexpr double edge_margin = 4.0;
    const double dist_to_edge_x = std::min(world_x + map_half, map_half - world_x);
    const double dist_to_edge_z = std::min(world_z + map_half, map_half - world_z);
    const double dist_to_edge = std::min(dist_to_edge_x, dist_to_edge_z);
    if (dist_to_edge <= 0.0) {
        return -10.0;
    }
    if (dist_to_edge < edge_margin) {
        const double wall_blend = 1.0 - (dist_to_edge / edge_margin);
        const double wall_height = lerp_double(28.0, 32.0, wall_blend);
        if (world_y > wall_height) {
            return world_y - wall_height;
        }
        return -10.0 * wall_blend;
    }
    return world_y - map_height;
}

static bool water_active_at(const PackedByteArray &water_data, int width, int height, double world_x, double world_z, double map_half) {
    if (water_data.is_empty() || width <= 0 || height <= 0) {
        return false;
    }
    const int px = clamp_int(int(world_x + map_half), 0, width - 1);
    const int pz = clamp_int(int(world_z + map_half), 0, height - 1);
    return read_r8_pixel(water_data, width, height, px, pz) > 128;
}

static bool excavation_mask_has_point(const PackedByteArray &mask, int grid_size, int local_x, int local_y, int local_z) {
    if (mask.is_empty() || grid_size <= 0) {
        return false;
    }
    const int64_t bit_index = int64_t(local_x) + int64_t(local_y) * int64_t(grid_size) + int64_t(local_z) * int64_t(grid_size) * int64_t(grid_size);
    const int64_t byte_index = bit_index / 8;
    if (byte_index < 0 || byte_index >= mask.size()) {
        return false;
    }
    return ((int(mask[int(byte_index)]) >> int(bit_index % 8)) & 1) != 0;
}

static double fract_double(double value) {
    return value - std::floor(value);
}

static double hash3(double x, double y, double z) {
    double px = fract_double(x * 0.3183099 + 0.1);
    double py = fract_double(y * 0.3183099 + 0.1);
    double pz = fract_double(z * 0.3183099 + 0.1);
    px *= 17.0;
    py *= 17.0;
    pz *= 17.0;
    return fract_double(px * py * pz * (px + py + pz));
}

static double noise3d(double x, double y, double z) {
    const double ix = std::floor(x);
    const double iy = std::floor(y);
    const double iz = std::floor(z);
    const double fx = x - ix;
    const double fy = y - iy;
    const double fz = z - iz;
    const double sx = fx * fx * (3.0 - 2.0 * fx);
    const double sy = fy * fy * (3.0 - 2.0 * fy);
    const double sz = fz * fz * (3.0 - 2.0 * fz);

    const double x00 = lerp_double(hash3(ix, iy, iz), hash3(ix + 1.0, iy, iz), sx);
    const double x10 = lerp_double(hash3(ix, iy + 1.0, iz), hash3(ix + 1.0, iy + 1.0, iz), sx);
    const double y0 = lerp_double(x00, x10, sy);
    const double x01 = lerp_double(hash3(ix, iy, iz + 1.0), hash3(ix + 1.0, iy, iz + 1.0), sx);
    const double x11 = lerp_double(hash3(ix, iy + 1.0, iz + 1.0), hash3(ix + 1.0, iy + 1.0, iz + 1.0), sx);
    const double y1 = lerp_double(x01, x11, sy);
    return lerp_double(y0, y1, sz);
}

static double fbm3d(double x, double y, double z) {
    double total = 0.0;
    double weight = 0.5;
    double px = x;
    double py = y;
    double pz = z;
    for (int i = 0; i < 3; ++i) {
        total += weight * noise3d(px, py, pz);
        px *= 2.0;
        py *= 2.0;
        pz *= 2.0;
        weight *= 0.5;
    }
    return total;
}

static int normalize_world_biome_material(int biome_id) {
    if (biome_id == 0 || biome_id == 3 || biome_id == 4 || biome_id == 5) {
        return biome_id;
    }
    return 0;
}

static int world_map_material_id(
        const PackedByteArray &biome_data,
        int biome_width,
        int biome_height,
        const PackedByteArray &road_data,
        int road_width,
        int road_height,
        double world_x,
        double world_y,
        double world_z,
        double terrain_height,
        double map_half) {
    const double depth = terrain_height - world_y;
    if (depth > 10.0) {
        const double ore_noise = noise3d(world_x * 0.15, world_y * 0.15, world_z * 0.15);
        if (ore_noise > 0.75 && depth > 8.0) {
            return 2;
        }
        const double stone_var = fbm3d(world_x * 0.02, world_y * 0.02, world_z * 0.02);
        if (stone_var > 0.25) {
            return 9;
        }
        return 1;
    }

    const int biome_px = clamp_int(int(world_x + map_half), 0, std::max(biome_width - 1, 0));
    const int biome_pz = clamp_int(int(world_z + map_half), 0, std::max(biome_height - 1, 0));
    const int biome_id = read_r8_pixel(biome_data, biome_width, biome_height, biome_px, biome_pz);
    const int road_px = clamp_int(int(world_x + map_half), 0, std::max(road_width - 1, 0));
    const int road_pz = clamp_int(int(world_z + map_half), 0, std::max(road_height - 1, 0));
    const int road_primary = read_r8_pixel(road_data, road_width, road_height, road_px, road_pz, 0);
    if ((road_primary > 128 || biome_id == 6) && depth < 2.0) {
        return 6;
    }
    return normalize_world_biome_material(biome_id);
}

static void encode_u32_le(uint8_t *dst, uint32_t value) {
    dst[0] = uint8_t(value & 0xffu);
    dst[1] = uint8_t((value >> 8u) & 0xffu);
    dst[2] = uint8_t((value >> 16u) & 0xffu);
    dst[3] = uint8_t((value >> 24u) & 0xffu);
}

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
    ClassDB::bind_method(D_METHOD("set_unload_hysteresis_chunks", "hysteresis_chunks"), &TerrainGrid::set_unload_hysteresis_chunks);
    ClassDB::bind_method(D_METHOD("get_unload_hysteresis_chunks"), &TerrainGrid::get_unload_hysteresis_chunks);
    ClassDB::bind_method(D_METHOD("set_prioritize_stream_candidates", "prioritize"), &TerrainGrid::set_prioritize_stream_candidates);
    ClassDB::bind_method(D_METHOD("get_prioritize_stream_candidates"), &TerrainGrid::get_prioritize_stream_candidates);
    ClassDB::bind_method(D_METHOD("clear"), &TerrainGrid::clear);
    ClassDB::bind_method(D_METHOD("update", "viewer_pos", "render_distance", "is_above_ground", "chunk_stride", "load_chunks_per_frame_limit", "unload_chunks_per_frame_limit"), &TerrainGrid::update);
    ClassDB::bind_method(D_METHOD("get_collision_proximity_update", "center_chunk", "collision_distance", "collision_prewarm_distance", "min_y_layer", "max_y_layer", "shared_collision_body_enabled"), &TerrainGrid::get_collision_proximity_update);
    ClassDB::bind_method(D_METHOD("get_chunk_height_map", "density", "size", "step"), &TerrainGrid::get_chunk_height_map);
    ClassDB::bind_method(D_METHOD("sample_cached_height_map", "height_map", "map_size", "chunk_stride", "step", "chunk_base_y"), &TerrainGrid::sample_cached_height_map);
    ClassDB::bind_method(D_METHOD("get_world_map_road_block_samples", "road_data", "road_width", "road_height", "chunk_origin_x", "chunk_origin_z", "chunk_stride", "step", "world_map_half", "world_map_size"), &TerrainGrid::get_world_map_road_block_samples);
    ClassDB::bind_method(D_METHOD("get_world_map_water_block_samples", "water_data", "water_width", "water_height", "chunk_origin_x", "chunk_origin_z", "chunk_stride", "step", "terrain_heights", "world_map_half", "water_level"), &TerrainGrid::get_world_map_water_block_samples);
    ClassDB::bind_method(D_METHOD("build_world_map_density_payload", "heightmap_data", "heightmap_width", "heightmap_height", "biome_data", "biome_width", "biome_height", "road_data", "road_width", "road_height", "water_data", "water_width", "water_height", "excavation_mask", "coord", "grid_size", "chunk_stride", "chunk_size", "world_map_half", "world_map_max_height", "water_level"), &TerrainGrid::build_world_map_density_payload);
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

void TerrainGrid::set_unload_hysteresis_chunks(int p_hysteresis_chunks) {
    const int clamped = p_hysteresis_chunks > 0 ? p_hysteresis_chunks : 0;
    if (unload_hysteresis_chunks == clamped) {
        return;
    }
    unload_hysteresis_chunks = clamped;
    update_cache_valid = false;
    cached_unload_candidates_valid = false;
}

int TerrainGrid::get_unload_hysteresis_chunks() const {
    return unload_hysteresis_chunks;
}

void TerrainGrid::set_prioritize_stream_candidates(bool p_prioritize) {
    if (prioritize_stream_candidates == p_prioritize) {
        return;
    }
    prioritize_stream_candidates = p_prioritize;
    update_cache_valid = false;
    cached_load_candidates_valid = false;
    cached_unload_candidates_valid = false;
}

bool TerrainGrid::get_prioritize_stream_candidates() const {
    return prioritize_stream_candidates;
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
        const int unload_distance = render_distance + unload_hysteresis_chunks;
        double unload_distance_sq = (double)unload_distance * (double)unload_distance;
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

        if (prioritize_stream_candidates) {
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
        }

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

        if (prioritize_stream_candidates) {
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
        }

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

PackedFloat32Array TerrainGrid::sample_cached_height_map(const PackedFloat32Array &height_map, int map_size, int chunk_stride, int step, double chunk_base_y) {
    PackedFloat32Array heights;
    if (height_map.is_empty() || chunk_stride <= 0 || step <= 0) {
        return heights;
    }

    if (map_size <= 0) {
        map_size = chunk_stride;
    }
    if (map_size <= 0) {
        return heights;
    }

    const int axis_count = sample_axis_count(chunk_stride, step);
    const int sample_count = axis_count * axis_count;
    if (sample_count <= 0) {
        return heights;
    }

    heights.resize(sample_count);
    const float *height_ptr = height_map.ptr();
    float *write_ptr = heights.ptrw();
    int write_index = 0;

    for (int x = 0; x < chunk_stride; x += step) {
        int sample_x = x;
        if (sample_x >= map_size) {
            sample_x = map_size - 1;
        }
        for (int z = 0; z < chunk_stride; z += step) {
            int sample_z = z;
            if (sample_z >= map_size) {
                sample_z = map_size - 1;
            }
            const int source_index = sample_x * map_size + sample_z;
            float local_height = -1000.0f;
            if (source_index >= 0 && source_index < height_map.size()) {
                local_height = height_ptr[source_index];
            }
            write_ptr[write_index++] = local_height > -100.0f ? local_height + float(chunk_base_y) : local_height;
        }
    }

    if (write_index != sample_count) {
        heights.resize(write_index);
    }
    return heights;
}

PackedFloat32Array TerrainGrid::get_world_map_road_block_samples(const PackedByteArray &road_data, int road_width, int road_height, int chunk_origin_x, int chunk_origin_z, int chunk_stride, int step, double world_map_half, double world_map_size) {
    PackedFloat32Array samples;
    if (road_data.is_empty() || road_width <= 0 || road_height <= 0 || chunk_stride <= 0 || step <= 0 || world_map_size <= 0.0) {
        return samples;
    }

    const int axis_count = sample_axis_count(chunk_stride, step);
    const int sample_count = axis_count * axis_count;
    if (sample_count <= 0) {
        return samples;
    }

    samples.resize(sample_count);
    float *write_ptr = samples.ptrw();
    int write_index = 0;

    for (int x = 0; x < chunk_stride; x += step) {
        const double global_x = double(chunk_origin_x + x);
        const double u = (global_x + world_map_half) / world_map_size;
        for (int z = 0; z < chunk_stride; z += step) {
            const double global_z = double(chunk_origin_z + z);
            const double v = (global_z + world_map_half) / world_map_size;
            if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) {
                write_ptr[write_index++] = 0.0f;
                continue;
            }

            const int px = std::clamp(int(Math::floor(u * double(road_width))), 0, road_width - 1);
            const int py = std::clamp(int(Math::floor(v * double(road_height))), 0, road_height - 1);
            write_ptr[write_index++] = read_mask_byte_pixel(road_data, px, py, road_width, road_height) ? 1.0f : 0.0f;
        }
    }

    if (write_index != sample_count) {
        samples.resize(write_index);
    }
    return samples;
}

PackedFloat32Array TerrainGrid::get_world_map_water_block_samples(const PackedByteArray &water_data, int water_width, int water_height, int chunk_origin_x, int chunk_origin_z, int chunk_stride, int step, const PackedFloat32Array &terrain_heights, double world_map_half, double water_level) {
    PackedFloat32Array samples;
    if (water_data.is_empty() || water_width <= 0 || water_height <= 0 || chunk_stride <= 0 || step <= 0 || terrain_heights.is_empty()) {
        return samples;
    }

    const int axis_count = sample_axis_count(chunk_stride, step);
    const int sample_count = axis_count * axis_count;
    if (sample_count <= 0) {
        return samples;
    }

    samples.resize(sample_count);
    float *write_ptr = samples.ptrw();
    const float *height_ptr = terrain_heights.ptr();
    int write_index = 0;
    int sample_index = 0;

    for (int x = 0; x < chunk_stride; x += step) {
        const double global_x = double(chunk_origin_x + x);
        for (int z = 0; z < chunk_stride; z += step) {
            if (sample_index >= terrain_heights.size()) {
                samples.resize(write_index);
                return samples;
            }
            const double terrain_y = double(height_ptr[sample_index++]);
            if (terrain_y < -100.0) {
                write_ptr[write_index++] = 0.0f;
                continue;
            }

            const double global_z = double(chunk_origin_z + z);
            const int px = std::clamp(int(global_x + world_map_half), 0, water_width - 1);
            const int py = std::clamp(int(global_z + world_map_half), 0, water_height - 1);
            const bool water_blocks = read_mask_byte_pixel(water_data, px, py, water_width, water_height) && (terrain_y + 0.5 < water_level);
            write_ptr[write_index++] = water_blocks ? 1.0f : 0.0f;
        }
    }

    if (write_index != sample_count) {
        samples.resize(write_index);
    }
    return samples;
}

Dictionary TerrainGrid::build_world_map_density_payload(
        const PackedByteArray &heightmap_data,
        int heightmap_width,
        int heightmap_height,
        const PackedByteArray &biome_data,
        int biome_width,
        int biome_height,
        const PackedByteArray &road_data,
        int road_width,
        int road_height,
        const PackedByteArray &water_data,
        int water_width,
        int water_height,
        const PackedByteArray &excavation_mask,
        Vector3i coord,
        int grid_size,
        int chunk_stride,
        int chunk_size,
        double world_map_half,
        double world_map_max_height,
        double water_level) {
    Dictionary result;
    if (grid_size <= 0 || chunk_stride <= 0 || chunk_size <= 0 || heightmap_data.is_empty() || heightmap_width <= 0 || heightmap_height <= 0) {
        return result;
    }

    const int64_t sample_count_64 = int64_t(grid_size) * int64_t(grid_size) * int64_t(grid_size);
    if (sample_count_64 <= 0 || sample_count_64 > 16 * 1024 * 1024) {
        return result;
    }
    const int sample_count = int(sample_count_64);

    PackedByteArray terrain_density_bytes;
    PackedByteArray water_density_bytes;
    PackedByteArray material_bytes;
    terrain_density_bytes.resize(sample_count * int(sizeof(float)));
    material_bytes.resize(sample_count * 4);

    float *terrain_density = reinterpret_cast<float *>(terrain_density_bytes.ptrw());
    uint8_t *materials = material_bytes.ptrw();

    const int base_x = coord.x * chunk_stride;
    const int base_y = coord.y * chunk_stride;
    const int base_z = coord.z * chunk_stride;
    const double chunk_min_y = double(coord.y * chunk_stride);
    const double chunk_max_y = chunk_min_y + double(chunk_size);
    bool water_surface_possible = false;
    if (!water_data.is_empty() && water_width > 0 && water_height > 0 && water_level >= chunk_min_y - 0.5 && water_level <= chunk_max_y + 0.5) {
        for (int local_x = 0; local_x < grid_size && !water_surface_possible; ++local_x) {
            const double world_x = double(base_x + local_x);
            for (int local_z = 0; local_z < grid_size; ++local_z) {
                const double world_z = double(base_z + local_z);
                if (water_active_at(water_data, water_width, water_height, world_x, world_z, world_map_half)) {
                    water_surface_possible = true;
                    break;
                }
            }
        }
    }
    float *water_density = nullptr;
    if (water_surface_possible) {
        water_density_bytes.resize(sample_count * int(sizeof(float)));
        water_density = reinterpret_cast<float *>(water_density_bytes.ptrw());
    }

    for (int local_z = 0; local_z < grid_size; ++local_z) {
        const double world_z = double(base_z + local_z);
        for (int local_y = 0; local_y < grid_size; ++local_y) {
            const double world_y = double(base_y + local_y);
            for (int local_x = 0; local_x < grid_size; ++local_x) {
                const double world_x = double(base_x + local_x);
                const int index = local_x + (local_y * grid_size) + (local_z * grid_size * grid_size);
                const double material_height = material_height_at(
                        heightmap_data,
                        heightmap_width,
                        heightmap_height,
                        world_x,
                        world_z,
                        world_map_half,
                        world_map_max_height);

                double density = world_map_density(world_x, world_y, world_z, material_height, world_map_half);
                if (excavation_mask_has_point(excavation_mask, grid_size, local_x, local_y, local_z)) {
                    density = 10.0;
                }
                terrain_density[index] = float(density);
                if (water_density != nullptr) {
                    water_density[index] = water_active_at(water_data, water_width, water_height, world_x, world_z, world_map_half)
                            ? float(world_y - water_level)
                            : 100.0f;
                }

                const int material = world_map_material_id(
                        biome_data,
                        biome_width,
                        biome_height,
                        road_data,
                        road_width,
                        road_height,
                        world_x,
                        world_y,
                        world_z,
                        material_height,
                        world_map_half);
                encode_u32_le(materials + index * 4, uint32_t(material));
            }
        }
    }

    result["density_bytes_terrain"] = terrain_density_bytes;
    result["density_bytes_water"] = water_density_bytes;
    result["material_bytes_terrain"] = material_bytes;
    result["water_surface_possible"] = water_surface_possible;
    return result;
}

} // namespace godot
