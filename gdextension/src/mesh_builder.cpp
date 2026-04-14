#include "mesh_builder.h"
#include <algorithm>
#include <cmath>
#include <godot_cpp/classes/box_shape3d.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <string>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <unordered_map>
#include <vector>

using namespace godot;

namespace {
struct BlockBatchData {
    Vector3i coord;
    std::vector<int32_t> indices;
    std::vector<uint8_t> types;
    std::vector<uint8_t> metas;
};

struct CollisionBoxData {
    Vector3i origin;
    Vector3i size;
};

struct Vector3iHash {
    size_t operator()(const Vector3i &value) const noexcept {
        const size_t hx = std::hash<int>{}(value.x);
        const size_t hy = std::hash<int>{}(value.y);
        const size_t hz = std::hash<int>{}(value.z);
        size_t seed = hx;
        seed ^= hy + 0x9e3779b9 + (seed << 6) + (seed >> 2);
        seed ^= hz + 0x9e3779b9 + (seed << 6) + (seed >> 2);
        return seed;
    }
};

struct Vector3iEqual {
    bool operator()(const Vector3i &lhs, const Vector3i &rhs) const noexcept {
        return lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z;
    }
};

using BlockBatchMap = std::unordered_map<Vector3i, BlockBatchData, Vector3iHash, Vector3iEqual>;

static void append_batch_dictionary(Array &batches, int index, const BlockBatchData &batch) {
    Dictionary batch_dict;
    batch_dict["coord"] = batch.coord;

    PackedInt32Array indices;
    indices.resize(batch.indices.size());
    if (!batch.indices.empty()) {
        int32_t *indices_ptr = indices.ptrw();
        std::copy(batch.indices.begin(), batch.indices.end(), indices_ptr);
    }
    batch_dict["indices"] = indices;

    PackedByteArray types;
    types.resize(batch.types.size());
    if (!batch.types.empty()) {
        uint8_t *types_ptr = types.ptrw();
        std::copy(batch.types.begin(), batch.types.end(), types_ptr);
    }
    batch_dict["types"] = types;

    PackedByteArray metas;
    metas.resize(batch.metas.size());
    if (!batch.metas.empty()) {
        uint8_t *metas_ptr = metas.ptrw();
        std::copy(batch.metas.begin(), batch.metas.end(), metas_ptr);
    }
    batch_dict["metas"] = metas;

    batches[index] = batch_dict;
}

static void append_collision_box_dictionary(Array &boxes, int index, const CollisionBoxData &box) {
    Dictionary box_dict;
    box_dict["origin"] = box.origin;
    box_dict["size"] = box.size;
    boxes[index] = box_dict;
}

static bool try_merge_collision_boxes(const CollisionBoxData &a, const CollisionBoxData &b, CollisionBoxData &out) {
    if (a.origin.y == b.origin.y && a.origin.z == b.origin.z && a.size.y == b.size.y && a.size.z == b.size.z) {
        if (a.origin.x + a.size.x == b.origin.x) {
            out.origin = a.origin;
            out.size = Vector3i(a.size.x + b.size.x, a.size.y, a.size.z);
            return true;
        }
        if (b.origin.x + b.size.x == a.origin.x) {
            out.origin = b.origin;
            out.size = Vector3i(a.size.x + b.size.x, a.size.y, a.size.z);
            return true;
        }
    }

    if (a.origin.x == b.origin.x && a.origin.z == b.origin.z && a.size.x == b.size.x && a.size.z == b.size.z) {
        if (a.origin.y + a.size.y == b.origin.y) {
            out.origin = a.origin;
            out.size = Vector3i(a.size.x, a.size.y + b.size.y, a.size.z);
            return true;
        }
        if (b.origin.y + b.size.y == a.origin.y) {
            out.origin = b.origin;
            out.size = Vector3i(a.size.x, a.size.y + b.size.y, a.size.z);
            return true;
        }
    }

    if (a.origin.x == b.origin.x && a.origin.y == b.origin.y && a.size.x == b.size.x && a.size.y == b.size.y) {
        if (a.origin.z + a.size.z == b.origin.z) {
            out.origin = a.origin;
            out.size = Vector3i(a.size.x, a.size.y, a.size.z + b.size.z);
            return true;
        }
        if (b.origin.z + b.size.z == a.origin.z) {
            out.origin = b.origin;
            out.size = Vector3i(a.size.x, a.size.y, a.size.z + b.size.z);
            return true;
        }
    }

    return false;
}

Vector3i rotate_offset_90(const Vector3i &offset, int rotation) {
    switch (rotation & 3) {
        case 1:
            return Vector3i(-offset.z, offset.y, offset.x);
        case 2:
            return Vector3i(-offset.x, offset.y, -offset.z);
        case 3:
            return Vector3i(offset.z, offset.y, -offset.x);
        default:
            return offset;
    }
}

struct BuildingMeshBuffers {
    std::vector<Vector3> vertices;
    std::vector<Vector3> normals;
    std::vector<Vector2> uvs;
    std::vector<int32_t> indices;

    void reserve_for_voxels(int voxel_count) {
        const int reserve_count = std::max(1024, voxel_count * 64);
        vertices.reserve(reserve_count);
        normals.reserve(reserve_count);
        uvs.reserve(reserve_count);
        indices.reserve(reserve_count);
    }

    int append_vertex(const Vector3 &vertex, const Vector3 &normal, const Vector2 &uv) {
        const int base_index = static_cast<int>(vertices.size());
        vertices.push_back(vertex);
        normals.push_back(normal);
        uvs.push_back(uv);
        return base_index;
    }

    void add_triangle(
        const Vector3 &p0,
        const Vector3 &p1,
        const Vector3 &p2,
        const Vector3 &n0,
        const Vector3 &n1,
        const Vector3 &n2,
        const Vector2 &uv0,
        const Vector2 &uv1,
        const Vector2 &uv2
    ) {
        const int base_index = static_cast<int>(vertices.size());
        vertices.push_back(p0);
        vertices.push_back(p2);
        vertices.push_back(p1);
        normals.push_back(n0);
        normals.push_back(n2);
        normals.push_back(n1);
        uvs.push_back(uv0);
        uvs.push_back(uv2);
        uvs.push_back(uv1);
        indices.push_back(base_index + 0);
        indices.push_back(base_index + 1);
        indices.push_back(base_index + 2);
    }

    void add_quad(
        const Vector3 &origin,
        const Vector3 &u_axis,
        const Vector3 &v_axis,
        float u_len,
        float v_len,
        const Vector3 &normal
    ) {
        const int base_index = static_cast<int>(vertices.size());
        const Vector3 p0 = origin;
        const Vector3 p1 = origin + u_axis * u_len;
        const Vector3 p2 = origin + u_axis * u_len + v_axis * v_len;
        const Vector3 p3 = origin + v_axis * v_len;

        vertices.push_back(p0);
        vertices.push_back(p3);
        vertices.push_back(p2);
        vertices.push_back(p1);

        normals.push_back(normal);
        normals.push_back(normal);
        normals.push_back(normal);
        normals.push_back(normal);

        // World-projected UVs keep merged building faces tiled across the
        // entire quad. Atlas selection is handled in the material shader.
        const Vector3 u_dir = u_axis.normalized();
        const Vector3 v_dir = v_axis.normalized();
        const float u0 = origin.dot(u_dir);
        const float v0 = origin.dot(v_dir);

        uvs.push_back(Vector2(u0, v0));
        uvs.push_back(Vector2(u0, v0 + v_len));
        uvs.push_back(Vector2(u0 + u_len, v0 + v_len));
        uvs.push_back(Vector2(u0 + u_len, v0));

        indices.push_back(base_index + 0);
        indices.push_back(base_index + 1);
        indices.push_back(base_index + 2);
        indices.push_back(base_index + 0);
        indices.push_back(base_index + 2);
        indices.push_back(base_index + 3);
    }
};

static inline Vector3 rotate_vector_90(const Vector3 &v, uint32_t r) {
    float nx = v.x;
    float nz = v.z;

    if (r == 1u) {
        nx = -v.z;
        nz = v.x;
    } else if (r == 2u) {
        nx = -v.x;
        nz = -v.z;
    } else if (r == 3u) {
        nx = v.z;
        nz = -v.x;
    }
    return Vector3(nx, v.y, nz);
}

static inline Vector3 rotate_local_90(const Vector3 &p, uint32_t r) {
    Vector3 c = p - Vector3(0.5, 0.0, 0.5);
    Vector3 rot_c = rotate_vector_90(c, r);
    return rot_c + Vector3(0.5, 0.0, 0.5);
}

static inline uint8_t get_voxel_3d(const PackedByteArray &voxels, int size_x, int size_y, int size_z, int x, int y, int z) {
    if (x < 0 || y < 0 || z < 0 || x >= size_x || y >= size_y || z >= size_z) {
        return 0u;
    }
    const int index = x + y * size_x + z * size_x * size_y;
    if (index < 0 || index >= voxels.size()) {
        return 0u;
    }
    return voxels[index];
}

static inline bool has_face_type_3d(const PackedByteArray &voxels, int size_x, int size_y, int size_z, int x, int y, int z, int nx, int ny, int nz, uint8_t type) {
    return get_voxel_3d(voxels, size_x, size_y, size_z, x, y, z) == type &&
        get_voxel_3d(voxels, size_x, size_y, size_z, x + nx, y + ny, z + nz) != type;
}

static void add_ramp_cpu(BuildingMeshBuffers &buffers, const Vector3 &pos, uint32_t r) {
    Vector3 l000 = Vector3(0, 0, 0);
    Vector3 l100 = Vector3(1, 0, 0);
    Vector3 l011 = Vector3(0, 1, 1);
    Vector3 l111 = Vector3(1, 1, 1);
    Vector3 l001 = Vector3(0, 0, 1);
    Vector3 l101 = Vector3(1, 0, 1);

    Vector3 p000 = pos + rotate_local_90(l000, r);
    Vector3 p100 = pos + rotate_local_90(l100, r);
    Vector3 p011 = pos + rotate_local_90(l011, r);
    Vector3 p111 = pos + rotate_local_90(l111, r);
    Vector3 p001 = pos + rotate_local_90(l001, r);
    Vector3 p101 = pos + rotate_local_90(l101, r);

    Vector3 slope_n = rotate_vector_90(Vector3(0.0, 1.0, -1.0).normalized(), r);
    Vector3 back_n = rotate_vector_90(Vector3(0, 0, 1), r);
    Vector3 bottom_n = rotate_vector_90(Vector3(0, -1, 0), r);
    Vector3 left_n = rotate_vector_90(Vector3(-1, 0, 0), r);
    Vector3 right_n = rotate_vector_90(Vector3(1, 0, 0), r);

    buffers.add_quad(p000, p011 - p000, p100 - p000, 1.0, 1.0, slope_n);
    buffers.add_quad(p001, p101 - p001, p011 - p001, 1.0, 1.0, back_n);
    buffers.add_quad(p000, p100 - p000, p001 - p000, 1.0, 1.0, bottom_n);
    buffers.add_triangle(p000, p001, p011, left_n, left_n, left_n, Vector2(0, 0), Vector2(1, 0), Vector2(1, 1));
    buffers.add_triangle(p100, p111, p101, right_n, right_n, right_n, Vector2(0, 0), Vector2(1, 1), Vector2(1, 0));
}

static void add_sphere_cpu(BuildingMeshBuffers &buffers, const Vector3 &pos) {
    const Vector3 center = pos + Vector3(0.5, 0.5, 0.5);
    const float radius = 0.5f;
    const int slices = 16;
    const int stacks = 12;

    for (int i = 0; i < stacks; i++) {
        float v0 = float(i) / float(stacks);
        float v1 = float(i + 1) / float(stacks);

        float lat0 = 3.14159f * (-0.5f + v0);
        float z0 = radius * std::sin(lat0);
        float zr0 = radius * std::cos(lat0);

        float lat1 = 3.14159f * (-0.5f + v1);
        float z1 = radius * std::sin(lat1);
        float zr1 = radius * std::cos(lat1);

        for (int j = 0; j < slices; j++) {
            float u0 = float(j) / float(slices);
            float u1 = float(j + 1) / float(slices);

            float lng0 = 2.0f * 3.14159f * u0;
            float x0 = std::cos(lng0);
            float y0 = std::sin(lng0);

            float lng1 = 2.0f * 3.14159f * u1;
            float x1 = std::cos(lng1);
            float y1 = std::sin(lng1);

            Vector3 p00 = center + Vector3(x0 * zr0, z0, y0 * zr0);
            Vector3 p10 = center + Vector3(x1 * zr0, z0, y1 * zr0);
            Vector3 p01 = center + Vector3(x0 * zr1, z1, y0 * zr1);
            Vector3 p11 = center + Vector3(x1 * zr1, z1, y1 * zr1);

            Vector3 n00 = (p00 - center).normalized();
            Vector3 n10 = (p10 - center).normalized();
            Vector3 n01 = (p01 - center).normalized();
            Vector3 n11 = (p11 - center).normalized();

            Vector2 uv00 = Vector2(u0, v0);
            Vector2 uv10 = Vector2(u1, v0);
            Vector2 uv01 = Vector2(u0, v1);
            Vector2 uv11 = Vector2(u1, v1);

            buffers.add_triangle(p00, p01, p11, n00, n01, n11, uv00, uv01, uv11);
            buffers.add_triangle(p00, p11, p10, n00, n11, n10, uv00, uv11, uv10);
        }
    }
}

static void add_stairs_cpu(BuildingMeshBuffers &buffers, const Vector3 &pos, uint32_t r) {
    Vector3 up = Vector3(0, 1, 0);
    Vector3 down = Vector3(0, -1, 0);
    Vector3 front = Vector3(0, 0, -1);
    Vector3 back = Vector3(0, 0, 1);
    Vector3 left = Vector3(-1, 0, 0);
    Vector3 right = Vector3(1, 0, 0);

    Vector3 r_up = rotate_vector_90(up, r);
    Vector3 r_down = rotate_vector_90(down, r);
    Vector3 r_front = rotate_vector_90(front, r);
    Vector3 r_back = rotate_vector_90(back, r);
    Vector3 r_left = rotate_vector_90(left, r);
    Vector3 r_right = rotate_vector_90(right, r);

    const int N_STEPS = 4;
    const float step_size = 1.0f / float(N_STEPS);

    for (int i = 0; i < N_STEPS; i++) {
        float z_start = float(i) * step_size;
        float y_top = float(i + 1) * step_size;
        float y_bot = float(i) * step_size;

        Vector3 p_st = pos + rotate_local_90(Vector3(1.0, y_top, z_start), r);
        Vector3 u_st = rotate_vector_90(Vector3(-1, 0, 0), r);
        Vector3 v_st = rotate_vector_90(Vector3(0, 0, 1), r);
        buffers.add_quad(p_st, u_st, v_st, 1.0, step_size, r_up);

        Vector3 p_sf = pos + rotate_local_90(Vector3(1.0, y_bot, z_start), r);
        Vector3 u_sf = rotate_vector_90(Vector3(-1, 0, 0), r);
        Vector3 v_sf = rotate_vector_90(Vector3(0, 1, 0), r);
        buffers.add_quad(p_sf, u_sf, v_sf, 1.0, step_size, r_front);

        Vector3 p_l = pos + rotate_local_90(Vector3(0.0, 0.0, z_start), r);
        Vector3 u_l = rotate_vector_90(Vector3(0, 0, 1), r);
        Vector3 v_l = rotate_vector_90(Vector3(0, 1, 0), r);
        buffers.add_quad(p_l, u_l, v_l, step_size, y_top, r_left);

        Vector3 p_r = pos + rotate_local_90(Vector3(1.0, 0.0, z_start + step_size), r);
        Vector3 u_r = rotate_vector_90(Vector3(0, 0, -1), r);
        Vector3 v_r = rotate_vector_90(Vector3(0, 1, 0), r);
        buffers.add_quad(p_r, u_r, v_r, step_size, y_top, r_right);
    }

    Vector3 p_bot = pos + rotate_local_90(Vector3(0.0, 0.0, 0.0), r);
    Vector3 u_bot = rotate_vector_90(Vector3(1, 0, 0), r);
    Vector3 v_bot = rotate_vector_90(Vector3(0, 0, 1), r);
    buffers.add_quad(p_bot, u_bot, v_bot, 1.0, 1.0, r_down);

    Vector3 p_back = pos + rotate_local_90(Vector3(0.0, 0.0, 1.0), r);
    Vector3 u_back = rotate_vector_90(Vector3(1, 0, 0), r);
    Vector3 v_back = rotate_vector_90(Vector3(0, 1, 0), r);
    buffers.add_quad(p_back, u_back, v_back, 1.0, 1.0, r_back);
}

static void add_stairs_2step_cpu(BuildingMeshBuffers &buffers, const Vector3 &pos, uint32_t r) {
    Vector3 up = Vector3(0, 1, 0);
    Vector3 down = Vector3(0, -1, 0);
    Vector3 front = Vector3(0, 0, -1);
    Vector3 back = Vector3(0, 0, 1);
    Vector3 left = Vector3(-1, 0, 0);
    Vector3 right = Vector3(1, 0, 0);

    Vector3 r_up = rotate_vector_90(up, r);
    Vector3 r_down = rotate_vector_90(down, r);
    Vector3 r_front = rotate_vector_90(front, r);
    Vector3 r_back = rotate_vector_90(back, r);
    Vector3 r_left = rotate_vector_90(left, r);
    Vector3 r_right = rotate_vector_90(right, r);

    Vector3 p_st1 = pos + rotate_local_90(Vector3(1, 0.5, 0), r);
    Vector3 u_st1 = rotate_vector_90(Vector3(-1, 0, 0), r);
    Vector3 v_st1 = rotate_vector_90(Vector3(0, 0, 1), r);
    buffers.add_quad(p_st1, u_st1, v_st1, 1.0, 0.5, r_up);

    Vector3 p_sf1 = pos + rotate_local_90(Vector3(1, 0, 0), r);
    Vector3 u_sf1 = rotate_vector_90(Vector3(-1, 0, 0), r);
    Vector3 v_sf1 = rotate_vector_90(Vector3(0, 1, 0), r);
    buffers.add_quad(p_sf1, u_sf1, v_sf1, 1.0, 0.5, r_front);

    Vector3 p_st2 = pos + rotate_local_90(Vector3(1, 1.0, 0.5), r);
    Vector3 u_st2 = rotate_vector_90(Vector3(-1, 0, 0), r);
    Vector3 v_st2 = rotate_vector_90(Vector3(0, 0, 1), r);
    buffers.add_quad(p_st2, u_st2, v_st2, 1.0, 0.5, r_up);

    Vector3 p_sf2 = pos + rotate_local_90(Vector3(1, 0.5, 0.5), r);
    Vector3 u_sf2 = rotate_vector_90(Vector3(-1, 0, 0), r);
    Vector3 v_sf2 = rotate_vector_90(Vector3(0, 1, 0), r);
    buffers.add_quad(p_sf2, u_sf2, v_sf2, 1.0, 0.5, r_front);

    Vector3 p_bot = pos + rotate_local_90(Vector3(0, 0, 0), r);
    Vector3 u_bot = rotate_vector_90(Vector3(1, 0, 0), r);
    Vector3 v_bot = rotate_vector_90(Vector3(0, 0, 1), r);
    buffers.add_quad(p_bot, u_bot, v_bot, 1.0, 1.0, r_down);

    Vector3 p_back = pos + rotate_local_90(Vector3(0, 0, 1), r);
    Vector3 u_back = rotate_vector_90(Vector3(1, 0, 0), r);
    Vector3 v_back = rotate_vector_90(Vector3(0, 1, 0), r);
    buffers.add_quad(p_back, u_back, v_back, 1.0, 1.0, r_back);

    Vector3 p_l1 = pos + rotate_local_90(Vector3(0, 0, 0), r);
    Vector3 u_l1 = rotate_vector_90(Vector3(0, 0, 1), r);
    Vector3 v_l1 = rotate_vector_90(Vector3(0, 1, 0), r);
    buffers.add_quad(p_l1, u_l1, v_l1, 0.5, 0.5, r_left);

    Vector3 p_l2 = pos + rotate_local_90(Vector3(0, 0, 0.5), r);
    Vector3 u_l2 = rotate_vector_90(Vector3(0, 0, 1), r);
    Vector3 v_l2 = rotate_vector_90(Vector3(0, 1, 0), r);
    buffers.add_quad(p_l2, u_l2, v_l2, 0.5, 1.0, r_left);

    Vector3 p_r1 = pos + rotate_local_90(Vector3(1, 0, 0.5), r);
    Vector3 u_r1 = rotate_vector_90(Vector3(0, 0, -1), r);
    Vector3 v_r1 = rotate_vector_90(Vector3(0, 1, 0), r);
    buffers.add_quad(p_r1, u_r1, v_r1, 0.5, 0.5, r_right);

    Vector3 p_r2 = pos + rotate_local_90(Vector3(1, 0, 1.0), r);
    Vector3 u_r2 = rotate_vector_90(Vector3(0, 0, -1), r);
    Vector3 v_r2 = rotate_vector_90(Vector3(0, 1, 0), r);
    buffers.add_quad(p_r2, u_r2, v_r2, 0.5, 1.0, r_right);
}

static void add_greedy_horizontal_faces_cpu(BuildingMeshBuffers &buffers, const PackedByteArray &voxels, int size_x, int size_y, int size_z) {
    if (size_x <= 0 || size_y <= 0 || size_z <= 0) {
        return;
    }

    // Horizontal faces cover merged floor surfaces, so keep UVs in world units
    // and let the material repeat naturally across the quad span.
    const float horizontal_uv_scale = 1.0f;
    std::vector<uint8_t> mask;
    mask.resize(size_x * size_z);

    auto emit_faces = [&](bool upward) {
        const Vector3 normal = upward ? Vector3(0, 1, 0) : Vector3(0, -1, 0);
        const Vector3 u_axis = Vector3(1, 0, 0);
        const Vector3 v_axis = upward ? Vector3(0, 0, -1) : Vector3(0, 0, 1);

        for (int y = 0; y < size_y; ++y) {
            std::fill(mask.begin(), mask.end(), uint8_t(0));

            for (int z = 0; z < size_z; ++z) {
                for (int x = 0; x < size_x; ++x) {
                    if (get_voxel_3d(voxels, size_x, size_y, size_z, x, y, z) != 1u) {
                        continue;
                    }

                    const int neighbor_y = upward ? (y + 1) : (y - 1);
                    if (get_voxel_3d(voxels, size_x, size_y, size_z, x, neighbor_y, z) != 1u) {
                        mask[x + z * size_x] = 1u;
                    }
                }
            }

            for (int z = 0; z < size_z; ++z) {
                for (int x = 0; x < size_x; ++x) {
                    const int start_index = x + z * size_x;
                    if (!mask[start_index]) {
                        continue;
                    }

                    int width = 1;
                    while (x + width < size_x && mask[start_index + width]) {
                        ++width;
                    }

                    int height = 1;
                    bool can_extend = true;
                    while (z + height < size_z && can_extend) {
                        for (int dx = 0; dx < width; ++dx) {
                            if (!mask[(x + dx) + (z + height) * size_x]) {
                                can_extend = false;
                                break;
                            }
                        }
                        if (can_extend) {
                            ++height;
                        }
                    }

                    for (int dz = 0; dz < height; ++dz) {
                        for (int dx = 0; dx < width; ++dx) {
                            mask[(x + dx) + (z + dz) * size_x] = 0u;
                        }
                    }

                    const Vector3 origin = upward
                        ? Vector3(x, y + 1, z + height)
                        : Vector3(x, y, z);
                    buffers.add_quad(
                        origin,
                        u_axis,
                        v_axis,
                        float(width) * horizontal_uv_scale,
                        float(height) * horizontal_uv_scale,
                        normal
                    );
                }
            }
        }
    };

    emit_faces(true);
    emit_faces(false);
}

static void add_greedy_vertical_faces_cpu(BuildingMeshBuffers &buffers, const PackedByteArray &voxels, int size_x, int size_y, int size_z) {
    if (size_x <= 0 || size_y <= 0 || size_z <= 0) {
        return;
    }

    auto emit_x_faces = [&](bool positive_x) {
        const Vector3 normal = positive_x ? Vector3(1, 0, 0) : Vector3(-1, 0, 0);
        const Vector3 u_axis = Vector3(0, 0, 1);
        const Vector3 v_axis = positive_x ? Vector3(0, -1, 0) : Vector3(0, 1, 0);
        std::vector<uint8_t> mask;
        mask.resize(size_y * size_z);

        for (int x = 0; x < size_x; ++x) {
            std::fill(mask.begin(), mask.end(), uint8_t(0));

            for (int y = 0; y < size_y; ++y) {
                for (int z = 0; z < size_z; ++z) {
                    if (get_voxel_3d(voxels, size_x, size_y, size_z, x, y, z) != 1u) {
                        continue;
                    }

                    const int neighbor_x = positive_x ? (x + 1) : (x - 1);
                    if (get_voxel_3d(voxels, size_x, size_y, size_z, neighbor_x, y, z) != 1u) {
                        mask[z + y * size_z] = 1u;
                    }
                }
            }

            for (int y = 0; y < size_y; ++y) {
                for (int z = 0; z < size_z; ++z) {
                    const int start_index = z + y * size_z;
                    if (!mask[start_index]) {
                        continue;
                    }

                    int width = 1;
                    while (z + width < size_z && mask[start_index + width]) {
                        ++width;
                    }

                    int height = 1;
                    bool can_extend = true;
                    while (y + height < size_y && can_extend) {
                        for (int dz = 0; dz < width; ++dz) {
                            if (!mask[(z + dz) + (y + height) * size_z]) {
                                can_extend = false;
                                break;
                            }
                        }
                        if (can_extend) {
                            ++height;
                        }
                    }

                    for (int dy = 0; dy < height; ++dy) {
                        for (int dz = 0; dz < width; ++dz) {
                            mask[(z + dz) + (y + dy) * size_z] = 0u;
                        }
                    }

                    const Vector3 origin = positive_x
                        ? Vector3(x + 1, y + height, z)
                        : Vector3(x, y, z);
                    buffers.add_quad(
                        origin,
                        u_axis,
                        v_axis,
                        float(width),
                        float(height),
                        normal
                    );
                }
            }
        }
    };

    auto emit_z_faces = [&](bool positive_z) {
        const Vector3 normal = positive_z ? Vector3(0, 0, 1) : Vector3(0, 0, -1);
        const Vector3 u_axis = Vector3(1, 0, 0);
        const Vector3 v_axis = positive_z ? Vector3(0, 1, 0) : Vector3(0, -1, 0);
        std::vector<uint8_t> mask;
        mask.resize(size_x * size_y);

        for (int z = 0; z < size_z; ++z) {
            std::fill(mask.begin(), mask.end(), uint8_t(0));

            for (int y = 0; y < size_y; ++y) {
                for (int x = 0; x < size_x; ++x) {
                    if (get_voxel_3d(voxels, size_x, size_y, size_z, x, y, z) != 1u) {
                        continue;
                    }

                    const int neighbor_z = positive_z ? (z + 1) : (z - 1);
                    if (get_voxel_3d(voxels, size_x, size_y, size_z, x, y, neighbor_z) != 1u) {
                        mask[x + y * size_x] = 1u;
                    }
                }
            }

            for (int y = 0; y < size_y; ++y) {
                for (int x = 0; x < size_x; ++x) {
                    const int start_index = x + y * size_x;
                    if (!mask[start_index]) {
                        continue;
                    }

                    int width = 1;
                    while (x + width < size_x && mask[start_index + width]) {
                        ++width;
                    }

                    int height = 1;
                    bool can_extend = true;
                    while (y + height < size_y && can_extend) {
                        for (int dx = 0; dx < width; ++dx) {
                            if (!mask[(x + dx) + (y + height) * size_x]) {
                                can_extend = false;
                                break;
                            }
                        }
                        if (can_extend) {
                            ++height;
                        }
                    }

                    for (int dy = 0; dy < height; ++dy) {
                        for (int dx = 0; dx < width; ++dx) {
                            mask[(x + dx) + (y + dy) * size_x] = 0u;
                        }
                    }

                    const Vector3 origin = positive_z
                        ? Vector3(x, y, z + 1)
                        : Vector3(x, y + height, z);
                    buffers.add_quad(
                        origin,
                        u_axis,
                        v_axis,
                        float(width),
                        float(height),
                        normal
                    );
                }
            }
        }
    };

    emit_x_faces(true);
    emit_x_faces(false);
    emit_z_faces(true);
    emit_z_faces(false);
}

}

MeshBuilder::MeshBuilder() {
}

MeshBuilder::~MeshBuilder() {
    _box_shape_cache.clear();
}

Ref<BoxShape3D> MeshBuilder::_get_cached_box_shape(const Vector3i& size) {
    const std::string key = std::to_string(size.x) + "_" + std::to_string(size.y) + "_" + std::to_string(size.z);
    auto found = _box_shape_cache.find(key);
    if (found != _box_shape_cache.end()) {
        return found->second;
    }

    Ref<BoxShape3D> box_shape;
    box_shape.instantiate();
    box_shape->set_size(Vector3(static_cast<double>(size.x), static_cast<double>(size.y), static_cast<double>(size.z)));
    _box_shape_cache.emplace(key, box_shape);
    return box_shape;
}

void MeshBuilder::_bind_methods() {
	ClassDB::bind_method(D_METHOD("build_mesh_native", "data", "stride"), &MeshBuilder::build_mesh_native);
	ClassDB::bind_method(D_METHOD("create_material_texture", "data", "width", "height", "depth"), &MeshBuilder::create_material_texture);
	ClassDB::bind_method(D_METHOD("has_player_material_overrides", "data", "width", "height", "depth"), &MeshBuilder::has_player_material_overrides);
    ClassDB::bind_method(D_METHOD("build_collision_shape", "data", "stride"), &MeshBuilder::build_collision_shape);
    ClassDB::bind_method(D_METHOD("build_collision_shape_indexed", "vertex_bytes", "index_bytes", "vertex_count", "index_count"), &MeshBuilder::build_collision_shape_indexed);
    ClassDB::bind_method(D_METHOD("build_trimesh_collision_shape_from_faces", "faces"), &MeshBuilder::build_trimesh_collision_shape_from_faces);

	// Fast conversion methods and custom building mesher
    ClassDB::bind_method(D_METHOD("bytes_to_floats", "data"), &MeshBuilder::bytes_to_floats);
    ClassDB::bind_method(D_METHOD("build_building_mesh", "vertex_bytes", "normal_bytes", "uv_bytes", "index_bytes", "vertex_count", "index_count"), &MeshBuilder::build_building_mesh);
    ClassDB::bind_method(D_METHOD("build_building_mesh_from_voxels", "voxel_bytes", "voxel_meta", "use_box_collision", "chunk_size"), &MeshBuilder::build_building_mesh_from_voxels);
    ClassDB::bind_method(D_METHOD("pack_rotated_world_map_block_batches", "prefab_blocks", "rotation", "spawn_pos", "chunk_size"), &MeshBuilder::pack_rotated_world_map_block_batches);
    ClassDB::bind_method(D_METHOD("build_collision_boxes_from_voxels", "voxel_bytes", "chunk_size"), &MeshBuilder::build_collision_boxes_from_voxels);
    ClassDB::bind_method(D_METHOD("apply_world_map_collision_boxes", "body_rid", "collision_boxes"), &MeshBuilder::apply_world_map_collision_boxes);
}

Ref<ArrayMesh> MeshBuilder::build_mesh_native(const PackedFloat32Array& data, int stride) {
    if (data.size() == 0 || stride <= 0) {
        return Ref<ArrayMesh>();
    }

    int vertex_count = data.size() / stride;
    if (vertex_count == 0) {
        return Ref<ArrayMesh>();
    }

    // Direct access for speed
    const float* src = data.ptr();

    PackedVector3Array vertices;
    PackedVector3Array normals;
    PackedColorArray colors;

    vertices.resize(vertex_count);
    normals.resize(vertex_count);
    colors.resize(vertex_count);

    // Write pointers for speed
    Vector3* v_ptr = vertices.ptrw();
    Vector3* n_ptr = normals.ptrw();
    Color* c_ptr = colors.ptrw();

    // Assuming stride is 9: pos(3) + norm(3) + color(3)
    // Optimized: Reinterpret cast for direct memory to struct copy
    // We process 9 floats per vertex: 3 for pos, 3 for norm, 3 for color
    for (int i = 0; i < vertex_count; ++i) {
        int idx = i * stride;

        // Direct cast from float* to Vector3*
        // Position (floats 0,1,2)
        v_ptr[i] = *reinterpret_cast<const Vector3*>(&src[idx]);

        // Normal (floats 3,4,5)
        n_ptr[i] = *reinterpret_cast<const Vector3*>(&src[idx + 3]);

        // Color (floats 6,7,8) - Source is 3 floats [r, g, b]
        // Godot Color struct is 4 floats [r, g, b, a], so we must construct explicit Color
        c_ptr[i] = Color(src[idx + 6], src[idx + 7], src[idx + 8]);
    }

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = vertices;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_COLOR] = colors;

    Ref<ArrayMesh> mesh;
    mesh.instantiate();
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);

    return mesh;
}



Ref<ImageTexture3D> MeshBuilder::create_material_texture(const PackedByteArray& data, int width, int height, int depth) {
    Ref<ImageTexture3D> tex;

    int total_voxels = width * height * depth;
    if (data.size() < total_voxels * 4) {
        return tex;
    }

    const uint8_t* raw_ptr = data.ptr();
    TypedArray<Image> images;

    for (int z = 0; z < depth; ++z) {
        PackedByteArray slice_data;
        slice_data.resize(width * height);
        uint8_t* slice_ptr = slice_data.ptrw();

        int z_offset = z * width * height;

        for (int i = 0; i < width * height; ++i) {
            int src_idx = (z_offset + i) * 4;
            slice_ptr[i] = raw_ptr[src_idx];
        }

        Ref<Image> img;
        img.instantiate();
        img->set_data(width, height, false, Image::FORMAT_R8, slice_data);
        images.append(img);
    }

    tex.instantiate();
    tex->create(Image::FORMAT_R8, width, height, depth, false, images);

    return tex;
}

bool MeshBuilder::has_player_material_overrides(const PackedByteArray& data, int width, int height, int depth) {
    if (width <= 0 || height <= 0 || depth <= 0) {
        return false;
    }

    const int total_voxels = width * height * depth;
    if (data.size() < total_voxels * 4) {
        return false;
    }

    const uint8_t *raw_ptr = data.ptr();
    for (int i = 0; i < total_voxels; ++i) {
        if (raw_ptr[i * 4] >= 100) {
            return true;
        }
    }

    return false;
}

Ref<ConcavePolygonShape3D> MeshBuilder::build_collision_shape(const PackedFloat32Array& data, int stride) {
    Ref<ConcavePolygonShape3D> shape;

    int vertex_count = data.size() / stride;
    if (vertex_count == 0 || vertex_count % 3 != 0) {
        return shape;
    }

    // ConcavePolygonShape3D expects a list of faces (triangles), which is just a flat array of Vector3
    // Since our data is [pos, norm, col, ...], we need to extract just pos.
    PackedVector3Array faces;
    faces.resize(vertex_count);

    const float* src = data.ptr();
    Vector3* dst = faces.ptrw();

    // Optimized extraction loop
    for (int i = 0; i < vertex_count; ++i) {
        // Direct float access is faster than creating Vector3 temporary objects repeatedly
        int idx = i * stride;
        dst[i].x = src[idx];
        dst[i].y = src[idx + 1];
        dst[i].z = src[idx + 2];
    }

    shape.instantiate();
    shape->set_faces(faces);

    return shape;
}

Ref<ConcavePolygonShape3D> MeshBuilder::build_collision_shape_indexed(const PackedByteArray& vertex_bytes, const PackedByteArray& index_bytes, int vertex_count, int index_count) {
    Ref<ConcavePolygonShape3D> shape;

    if (vertex_count <= 0 || index_count <= 0 || (index_count % 3) != 0) {
        return shape;
    }

    if (vertex_bytes.size() < vertex_count * 12 || index_bytes.size() < index_count * 4) {
        return shape;
    }

    // ConcavePolygonShape3D expects a flat triangle face list. The building mesh
    // stores unique vertices plus an index buffer, so expand the indices here.
    PackedVector3Array faces;
    faces.resize(index_count);

    const float* vertex_ptr = reinterpret_cast<const float*>(vertex_bytes.ptr());
    const int32_t* index_ptr = reinterpret_cast<const int32_t*>(index_bytes.ptr());
    Vector3* dst = faces.ptrw();

    for (int i = 0; i < index_count; ++i) {
        int vertex_index = index_ptr[i];
        if (vertex_index < 0 || vertex_index >= vertex_count) {
            return Ref<ConcavePolygonShape3D>();
        }

        const int src_idx = vertex_index * 3;
        dst[i].x = vertex_ptr[src_idx];
        dst[i].y = vertex_ptr[src_idx + 1];
        dst[i].z = vertex_ptr[src_idx + 2];
    }

    shape.instantiate();
    shape->set_faces(faces);

    return shape;
}

Ref<ConcavePolygonShape3D> MeshBuilder::build_trimesh_collision_shape_from_faces(const PackedVector3Array& faces) {
    Ref<ConcavePolygonShape3D> shape;

    if (faces.size() < 3 || (faces.size() % 3) != 0) {
        return shape;
    }

    shape.instantiate();
    shape->set_faces(faces);
    return shape;
}

PackedFloat32Array MeshBuilder::bytes_to_floats(const PackedByteArray& data) {
    PackedFloat32Array floats;
    int count = data.size();
    floats.resize(count);

    const uint8_t* src = data.ptr();
    float* dst = floats.ptrw();

    for (int i = 0; i < count; ++i) {
        dst[i] = static_cast<float>(src[i]);
    }

    return floats;
}

Ref<ArrayMesh> MeshBuilder::build_building_mesh(const PackedByteArray& vertex_bytes, const PackedByteArray& normal_bytes, const PackedByteArray& uv_bytes, const PackedByteArray& index_bytes, int vertex_count, int index_count) {
    if (vertex_count <= 0 || index_count <= 0) {
        return Ref<ArrayMesh>();
    }

    PackedVector3Array vertices;
    PackedVector3Array normals;
    PackedVector2Array uvs;
    PackedInt32Array indices;

    vertices.resize(vertex_count);
    normals.resize(vertex_count);
    uvs.resize(vertex_count);
    indices.resize(index_count);

    Vector3* v_ptr = vertices.ptrw();
    Vector3* n_ptr = normals.ptrw();
    Vector2* uv_ptr = uvs.ptrw();
    int32_t* idx_ptr = indices.ptrw();

    const float* src_v = reinterpret_cast<const float*>(vertex_bytes.ptr());
    const float* src_n = reinterpret_cast<const float*>(normal_bytes.ptr());
    const float* src_uv = reinterpret_cast<const float*>(uv_bytes.ptr());
    const int32_t* src_idx = reinterpret_cast<const int32_t*>(index_bytes.ptr());

    // 1. Unpack Vertices (vec3)
    for (int i = 0; i < vertex_count; ++i) {
        v_ptr[i] = Vector3(src_v[i * 3], src_v[i * 3 + 1], src_v[i * 3 + 2]);
    }

    // 2. Unpack Normals (vec3)
    for (int i = 0; i < vertex_count; ++i) {
        n_ptr[i] = Vector3(src_n[i * 3], src_n[i * 3 + 1], src_n[i * 3 + 2]);
    }

    // 3. Unpack UVs (vec2)
    for (int i = 0; i < vertex_count; ++i) {
        uv_ptr[i] = Vector2(src_uv[i * 2], src_uv[i * 2 + 1]);
    }

	// 4. Unpack Indices (int32)
	for (int i = 0; i < index_count; ++i) {
		idx_ptr[i] = src_idx[i];
	}

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = vertices;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_TEX_UV] = uvs;
    arrays[Mesh::ARRAY_INDEX] = indices;

    Ref<ArrayMesh> mesh;
    mesh.instantiate();
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);

    return mesh;
}

Dictionary MeshBuilder::build_building_mesh_from_voxels(const PackedByteArray& voxel_bytes, const PackedByteArray& voxel_meta, bool use_box_collision, int chunk_size) {
    Dictionary result;

    if (chunk_size <= 0) {
        return result;
    }

    const int voxel_count = chunk_size * chunk_size * chunk_size;
    if (voxel_bytes.size() < voxel_count || voxel_meta.size() < voxel_count) {
        return result;
    }

    BuildingMeshBuffers buffers;
    buffers.reserve_for_voxels(voxel_count);

    add_greedy_horizontal_faces_cpu(buffers, voxel_bytes, chunk_size, chunk_size, chunk_size);
    add_greedy_vertical_faces_cpu(buffers, voxel_bytes, chunk_size, chunk_size, chunk_size);

    for (int z = 0; z < chunk_size; ++z) {
        for (int y = 0; y < chunk_size; ++y) {
            for (int x = 0; x < chunk_size; ++x) {
                const int idx = x + y * chunk_size + z * chunk_size * chunk_size;
                const uint8_t type = voxel_bytes[idx];
                if (type == 0u) {
                    continue;
                }

                const Vector3 pos = Vector3(x, y, z);
                if (type == 2u) {
                    const uint32_t meta = voxel_meta[idx];
                    add_ramp_cpu(buffers, pos, meta);
                    continue;
                }

                if (type == 3u) {
                    add_sphere_cpu(buffers, pos);
                    continue;
                }

                if (type == 4u) {
                    const uint32_t meta = voxel_meta[idx];
                    add_stairs_cpu(buffers, pos, meta);
                    continue;
                }

                if (type == 5u) {
                    const uint32_t meta = voxel_meta[idx];
                    add_stairs_2step_cpu(buffers, pos, meta);
                    continue;
                }

                if (type == 1u) {
                    continue;
                }
            }
        }
    }

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);

    Ref<ArrayMesh> mesh;
    if (!buffers.vertices.empty()) {
        PackedVector3Array vertices;
        PackedVector3Array normals;
        PackedVector2Array uvs;
        PackedInt32Array indices;

        vertices.resize(buffers.vertices.size());
        normals.resize(buffers.normals.size());
        uvs.resize(buffers.uvs.size());
        indices.resize(buffers.indices.size());

        if (!buffers.vertices.empty()) {
            std::copy(buffers.vertices.begin(), buffers.vertices.end(), vertices.ptrw());
        }
        if (!buffers.normals.empty()) {
            std::copy(buffers.normals.begin(), buffers.normals.end(), normals.ptrw());
        }
        if (!buffers.uvs.empty()) {
            std::copy(buffers.uvs.begin(), buffers.uvs.end(), uvs.ptrw());
        }
        if (!buffers.indices.empty()) {
            std::copy(buffers.indices.begin(), buffers.indices.end(), indices.ptrw());
        }

        arrays[Mesh::ARRAY_VERTEX] = vertices;
        arrays[Mesh::ARRAY_NORMAL] = normals;
        arrays[Mesh::ARRAY_TEX_UV] = uvs;
        arrays[Mesh::ARRAY_INDEX] = indices;

        mesh.instantiate();
        mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    }

    Ref<ConcavePolygonShape3D> collision_shape;
    if (!use_box_collision && mesh.is_valid() && buffers.indices.size() > 0 && buffers.vertices.size() > 0) {
        PackedVector3Array faces;
        faces.resize(buffers.indices.size());
        Vector3 *faces_ptr = faces.ptrw();
        for (size_t i = 0; i < buffers.indices.size(); ++i) {
            const int32_t vertex_index = buffers.indices[i];
            if (vertex_index < 0 || vertex_index >= static_cast<int32_t>(buffers.vertices.size())) {
                return result;
            }
            faces_ptr[i] = buffers.vertices[vertex_index];
        }
        collision_shape.instantiate();
        collision_shape->set_faces(faces);
    }

    Array collision_boxes;
    if (use_box_collision) {
        collision_boxes = build_collision_boxes_from_voxels(voxel_bytes, chunk_size);
    }

    result["mesh"] = mesh;
    result["shape"] = collision_shape;
    result["collision_boxes"] = collision_boxes;
    result["arrays"] = Array();
    return result;
}

Array MeshBuilder::pack_world_map_block_batches(const Array& rotated_blocks, const Vector3& spawn_pos, int chunk_size) {
    Array batches;
    if (rotated_blocks.is_empty() || chunk_size <= 0) {
        return batches;
    }

    BlockBatchMap batches_by_coord;
    batches_by_coord.reserve(rotated_blocks.size());

    for (int i = 0; i < rotated_blocks.size(); ++i) {
        Variant block_variant = rotated_blocks[i];
        if (block_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }

        Dictionary block = block_variant;
        Vector3i rotated_offset = block.get("offset", Vector3i());
        Vector3 block_global_pos = spawn_pos + Vector3(rotated_offset);

        int global_x = static_cast<int>(Math::floor(block_global_pos.x));
        int global_y = static_cast<int>(Math::floor(block_global_pos.y));
        int global_z = static_cast<int>(Math::floor(block_global_pos.z));

        Vector3i chunk_coord(
            static_cast<int>(Math::floor(block_global_pos.x / static_cast<double>(chunk_size))),
            static_cast<int>(Math::floor(block_global_pos.y / static_cast<double>(chunk_size))),
            static_cast<int>(Math::floor(block_global_pos.z / static_cast<double>(chunk_size)))
        );

        int local_x = global_x % chunk_size;
        int local_y = global_y % chunk_size;
        int local_z = global_z % chunk_size;
        if (local_x < 0) local_x += chunk_size;
        if (local_y < 0) local_y += chunk_size;
        if (local_z < 0) local_z += chunk_size;

        int local_index = local_x + local_y * chunk_size + local_z * chunk_size * chunk_size;

        BlockBatchData &batch = batches_by_coord[chunk_coord];
        batch.coord = chunk_coord;
        batch.indices.push_back(local_index);
        batch.types.push_back(uint8_t(int(block.get("type", 0))));
        batch.metas.push_back(uint8_t(int(block.get("meta", 0))));
    }

    batches.resize(static_cast<int>(batches_by_coord.size()));
    int batch_index = 0;
    for (const auto &entry : batches_by_coord) {
        append_batch_dictionary(batches, batch_index, entry.second);
        batch_index++;
    }

    return batches;
}

Array MeshBuilder::pack_rotated_world_map_block_batches(const Array& prefab_blocks, int rotation, const Vector3& spawn_pos, int chunk_size) {
    Array batches;
    if (prefab_blocks.is_empty() || chunk_size <= 0) {
        return batches;
    }

    rotation = ((rotation % 4) + 4) % 4;
    BlockBatchMap batches_by_coord;
    batches_by_coord.reserve(prefab_blocks.size());

    for (int i = 0; i < prefab_blocks.size(); ++i) {
        Variant block_variant = prefab_blocks[i];
        if (block_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }

        Dictionary block = block_variant;
        Vector3i offset = block.get("offset", Vector3i());
        Vector3i rotated_offset = rotate_offset_90(offset, rotation);
        int block_type = block.get("type", 0);
        int block_meta = block.get("meta", 0);

        if (block_type == 4 || (block_type == 2 && block_meta >= 1 && block_meta <= 3)) {
            block_meta = (block_meta + rotation) % 4;
        }

        Vector3 block_global_pos = spawn_pos + Vector3(rotated_offset);

        int global_x = static_cast<int>(Math::floor(block_global_pos.x));
        int global_y = static_cast<int>(Math::floor(block_global_pos.y));
        int global_z = static_cast<int>(Math::floor(block_global_pos.z));

        Vector3i chunk_coord(
            static_cast<int>(Math::floor(block_global_pos.x / static_cast<double>(chunk_size))),
            static_cast<int>(Math::floor(block_global_pos.y / static_cast<double>(chunk_size))),
            static_cast<int>(Math::floor(block_global_pos.z / static_cast<double>(chunk_size)))
        );

        int local_x = global_x % chunk_size;
        int local_y = global_y % chunk_size;
        int local_z = global_z % chunk_size;
        if (local_x < 0) local_x += chunk_size;
        if (local_y < 0) local_y += chunk_size;
        if (local_z < 0) local_z += chunk_size;

        int local_index = local_x + local_y * chunk_size + local_z * chunk_size * chunk_size;

        BlockBatchData &batch = batches_by_coord[chunk_coord];
        batch.coord = chunk_coord;
        batch.indices.push_back(local_index);
        batch.types.push_back(uint8_t(block_type));
        batch.metas.push_back(uint8_t(block_meta));
    }

    batches.resize(static_cast<int>(batches_by_coord.size()));
    int batch_index = 0;
    for (const auto &entry : batches_by_coord) {
        append_batch_dictionary(batches, batch_index, entry.second);
        batch_index++;
    }

    return batches;
}

Array MeshBuilder::build_collision_boxes_from_voxels(const PackedByteArray& voxel_bytes, int chunk_size) {
    Array boxes;
    if (voxel_bytes.is_empty() || chunk_size <= 0) {
        return boxes;
    }

    const int volume = chunk_size * chunk_size * chunk_size;
    if (voxel_bytes.size() < volume) {
        return boxes;
    }

    PackedByteArray visited;
    visited.resize(volume);
    visited.fill(0);
    std::vector<CollisionBoxData> box_list;
    box_list.reserve(64);

    const uint8_t *voxels = voxel_bytes.ptr();
    uint8_t *visited_ptr = visited.ptrw();

    for (int y = 0; y < chunk_size; ++y) {
        for (int z = 0; z < chunk_size; ++z) {
            for (int x = 0; x < chunk_size; ++x) {
                const int idx = x + y * chunk_size + z * chunk_size * chunk_size;
                if (visited_ptr[idx] != 0 || voxels[idx] == 0) {
                    continue;
                }

                int x_end = x;
                while (x_end + 1 < chunk_size) {
                    const int next_idx = (x_end + 1) + y * chunk_size + z * chunk_size * chunk_size;
                    if (visited_ptr[next_idx] != 0 || voxels[next_idx] == 0) {
                        break;
                    }
                    ++x_end;
                }

                int z_end = z;
                while (z_end + 1 < chunk_size) {
                    bool can_expand_z = true;
                    for (int xi = x; xi <= x_end; ++xi) {
                        const int row_idx = xi + y * chunk_size + (z_end + 1) * chunk_size * chunk_size;
                        if (visited_ptr[row_idx] != 0 || voxels[row_idx] == 0) {
                            can_expand_z = false;
                            break;
                        }
                    }
                    if (!can_expand_z) {
                        break;
                    }
                    ++z_end;
                }

                int y_end = y;
                while (y_end + 1 < chunk_size) {
                    bool can_expand_y = true;
                    for (int zz = z; zz <= z_end && can_expand_y; ++zz) {
                        for (int xi = x; xi <= x_end; ++xi) {
                            const int layer_idx = xi + (y_end + 1) * chunk_size + zz * chunk_size * chunk_size;
                            if (visited_ptr[layer_idx] != 0 || voxels[layer_idx] == 0) {
                                can_expand_y = false;
                                break;
                            }
                        }
                    }
                    if (!can_expand_y) {
                        break;
                    }
                    ++y_end;
                }

                for (int yy = y; yy <= y_end; ++yy) {
                    for (int zz = z; zz <= z_end; ++zz) {
                        for (int xx = x; xx <= x_end; ++xx) {
                            visited_ptr[xx + yy * chunk_size + zz * chunk_size * chunk_size] = 1;
                        }
                    }
                }

                CollisionBoxData box;
                box.origin = Vector3i(x, y, z);
                box.size = Vector3i(x_end - x + 1, y_end - y + 1, z_end - z + 1);
                box_list.push_back(box);
            }
        }
    }

    bool merged_any = true;
    while (merged_any) {
        merged_any = false;
        for (size_t i = 0; i < box_list.size() && !merged_any; ++i) {
            for (size_t j = i + 1; j < box_list.size(); ++j) {
                CollisionBoxData merged_box;
                if (try_merge_collision_boxes(box_list[i], box_list[j], merged_box)) {
                    box_list[i] = merged_box;
                    box_list.erase(box_list.begin() + static_cast<std::ptrdiff_t>(j));
                    merged_any = true;
                    break;
                }
            }
        }
    }

    boxes.resize(static_cast<int>(box_list.size()));
    for (size_t i = 0; i < box_list.size(); ++i) {
        append_collision_box_dictionary(boxes, static_cast<int>(i), box_list[i]);
    }

    return boxes;
}

bool MeshBuilder::apply_world_map_collision_boxes(const RID& body_rid, const Array& collision_boxes) {
    if (!body_rid.is_valid()) {
        return false;
    }

    PhysicsServer3D *physics_server = PhysicsServer3D::get_singleton();
    if (!physics_server) {
        return false;
    }

    const int shape_count = physics_server->body_get_shape_count(body_rid);
    for (int shape_idx = shape_count - 1; shape_idx >= 0; --shape_idx) {
        physics_server->body_remove_shape(body_rid, shape_idx);
    }

    if (collision_boxes.is_empty()) {
        return true;
    }

    for (int i = 0; i < collision_boxes.size(); ++i) {
        Variant box_variant = collision_boxes[i];
        if (box_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }

        Dictionary box_data = box_variant;
        Vector3i origin = box_data.get("origin", Vector3i());
        Vector3i size = box_data.get("size", Vector3i(1, 1, 1));
        if (size.x <= 0 || size.y <= 0 || size.z <= 0) {
            continue;
        }

        Ref<BoxShape3D> box_shape = _get_cached_box_shape(size);
        if (box_shape.is_null()) {
            continue;
        }

        Transform3D box_transform(Basis(), Vector3(origin) + Vector3(size) * 0.5);
        physics_server->body_add_shape(body_rid, box_shape->get_rid(), box_transform);
    }

    return true;
}
