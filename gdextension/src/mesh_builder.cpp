#include "mesh_builder.h"
#include <algorithm>
#include <cstdint>
#include <cmath>
#include <godot_cpp/classes/box_shape3d.hpp>
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
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <unordered_map>
#include <vector>

#include "transvoxel_tables.inc"

using namespace godot;

namespace {
enum class TransvoxelSide : uint8_t {
    LowX = 0,
    HighX = 1,
    LowY = 2,
    HighY = 3,
    LowZ = 4,
    HighZ = 5
};

struct TransvoxelVec3i {
    int x;
    int y;
    int z;
};

struct TransvoxelRotation {
    TransvoxelSide side;
    TransvoxelVec3i uvw_base;
    TransvoxelVec3i u;
    TransvoxelVec3i v;
    TransvoxelVec3i w;
    TransvoxelVec3i plus_x_as_uvw;
    TransvoxelVec3i plus_y_as_uvw;
    TransvoxelVec3i plus_z_as_uvw;
};

static const TransvoxelRotation TRANSVOXEL_ROTATIONS[6] = {
    {TransvoxelSide::LowX,  {0, 0, 1}, {0, 0, -1}, {0, 1, 0}, {1, 0, 0}, {1, 0, 0}, {0, 0, 1}, {0, 1, 0}},
    {TransvoxelSide::HighX, {1, 0, 0}, {0, 0,  1}, {0, 1, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}, {0, 1, 0}},
    {TransvoxelSide::LowY,  {0, 0, 1}, {1, 0,  0}, {0, 0, -1}, {0, 1, 0}, {0, 1, 0}, {1, 0, 0}, {0, 0, 1}},
    {TransvoxelSide::HighY, {0, 1, 0}, {1, 0,  0}, {0, 0, 1}, {0, -1, 0}, {0, 0, 1}, {1, 0, 0}, {0, 0, -1}},
    {TransvoxelSide::LowZ,  {0, 0, 0}, {1, 0,  0}, {0, 1, 0}, {0, 0, 1}, {0, 0, 0}, {1, 0, 0}, {0, 1, 0}},
    {TransvoxelSide::HighZ, {1, 0, 1}, {-1, 0, 0}, {0, 1, 0}, {0, 0, -1}, {1, 0, 1}, {-1, 0, 0}, {0, 1, 0}}
};

static inline const TransvoxelRotation &transvoxel_rotation(TransvoxelSide side) {
    return TRANSVOXEL_ROTATIONS[static_cast<int>(side)];
}

static inline float sample_world_map_height_bilinear(
    const PackedByteArray &heightmap_bytes,
    int image_width,
    int image_height,
    float map_size,
    float height_scale,
    float wx,
    float wz
) {
    if (heightmap_bytes.is_empty() || image_width <= 1 || image_height <= 1 || map_size <= 0.0f || height_scale <= 0.0f) {
        return 0.0f;
    }

    const float half_size = map_size * 0.5f;
    const float fx = std::clamp((wx + half_size) / map_size, 0.0f, 1.0f) * float(image_width - 1);
    const float fz = std::clamp((wz + half_size) / map_size, 0.0f, 1.0f) * float(image_height - 1);
    const int x0 = std::clamp(int(floorf(fx)), 0, image_width - 1);
    const int z0 = std::clamp(int(floorf(fz)), 0, image_height - 1);
    const int x1 = std::clamp(x0 + 1, 0, image_width - 1);
    const int z1 = std::clamp(z0 + 1, 0, image_height - 1);
    const float tx = fx - float(x0);
    const float tz = fz - float(z0);

    const int idx00 = z0 * image_width + x0;
    const int idx10 = z0 * image_width + x1;
    const int idx01 = z1 * image_width + x0;
    const int idx11 = z1 * image_width + x1;
    if (idx00 < 0 || idx11 >= heightmap_bytes.size()) {
        return 0.0f;
    }

    const float h00 = float(heightmap_bytes[idx00]) / 255.0f * height_scale;
    const float h10 = float(heightmap_bytes[idx10]) / 255.0f * height_scale;
    const float h01 = float(heightmap_bytes[idx01]) / 255.0f * height_scale;
    const float h11 = float(heightmap_bytes[idx11]) / 255.0f * height_scale;

    const float h0 = Math::lerp(h00, h10, tx);
    const float h1 = Math::lerp(h01, h11, tx);
    return Math::lerp(h0, h1, tz);
}

static inline Vector3 sample_world_map_height_normal(
    const PackedByteArray &heightmap_bytes,
    int image_width,
    int image_height,
    float map_size,
    float height_scale,
    float wx,
    float wz
) {
    if (heightmap_bytes.is_empty() || image_width <= 1 || image_height <= 1 || map_size <= 0.0f || height_scale <= 0.0f) {
        return Vector3(0.0, 1.0, 0.0);
    }

    const float sample_step = std::max(1.0f, map_size / float(std::max(2, std::max(image_width, image_height))));
    const float h_l = sample_world_map_height_bilinear(heightmap_bytes, image_width, image_height, map_size, height_scale, wx - sample_step, wz);
    const float h_r = sample_world_map_height_bilinear(heightmap_bytes, image_width, image_height, map_size, height_scale, wx + sample_step, wz);
    const float h_d = sample_world_map_height_bilinear(heightmap_bytes, image_width, image_height, map_size, height_scale, wx, wz - sample_step);
    const float h_u = sample_world_map_height_bilinear(heightmap_bytes, image_width, image_height, map_size, height_scale, wx, wz + sample_step);

    Vector3 normal(h_l - h_r, 2.0f * sample_step, h_d - h_u);
    if (normal.length_squared() <= 1.0e-12) {
        return Vector3(0.0, 1.0, 0.0);
    }
    return normal.normalized();
}

struct TransvoxelSamplePoint {
    Vector3 position;
    float density = 0.0f;
};

struct TransvoxelMeshBuffers {
    std::vector<Vector3> vertices;
    std::vector<Vector3> normals;
    std::vector<Vector2> uvs;
    std::vector<Color> colors;
    std::vector<int32_t> indices;

    void reserve(size_t vertex_guess, size_t index_guess) {
        vertices.reserve(vertex_guess);
        normals.reserve(vertex_guess);
        uvs.reserve(vertex_guess);
        colors.reserve(vertex_guess);
        indices.reserve(index_guess);
    }

    int append_vertex(const Vector3 &position, const Vector2 &uv) {
        const int index = static_cast<int>(vertices.size());
        vertices.push_back(position);
        normals.push_back(Vector3());
        uvs.push_back(uv);
        colors.push_back(Color(0.0, 0.0, 0.0, 1.0));
        return index;
    }

    void add_triangle(int32_t a, int32_t b, int32_t c) {
        indices.push_back(a);
        indices.push_back(b);
        indices.push_back(c);
    }

    void compute_normals() {
        if (vertices.empty() || indices.empty()) {
            normals.assign(vertices.size(), Vector3(0.0, 1.0, 0.0));
            return;
        }

        normals.assign(vertices.size(), Vector3());
        for (size_t i = 0; i + 2 < indices.size(); i += 3) {
            const int32_t ia = indices[i];
            const int32_t ib = indices[i + 1];
            const int32_t ic = indices[i + 2];
            if (ia < 0 || ib < 0 || ic < 0 || ia >= static_cast<int32_t>(vertices.size()) || ib >= static_cast<int32_t>(vertices.size()) || ic >= static_cast<int32_t>(vertices.size())) {
                continue;
            }
            const Vector3 &a = vertices[ia];
            const Vector3 &b = vertices[ib];
            const Vector3 &c = vertices[ic];
            Vector3 normal = (b - a).cross(c - a);
            if (normal.length_squared() <= 1.0e-12) {
                continue;
            }
            normals[ia] += normal;
            normals[ib] += normal;
            normals[ic] += normal;
        }

        for (Vector3 &normal : normals) {
            if (normal.length_squared() <= 1.0e-12) {
                normal = Vector3(0.0, 1.0, 0.0);
            } else {
                normal = normal.normalized();
            }
        }
    }
};

static const TransvoxelSamplePoint TRANSITION_HIGH_RES_FACE_CASE_CONTRIBUTIONS[9] = {
    {Vector3(0, 0, 0), 0x01},
    {Vector3(1, 0, 0), 0x02},
    {Vector3(2, 0, 0), 0x04},
    {Vector3(0, 1, 0), 0x80},
    {Vector3(1, 1, 0), 0x100},
    {Vector3(2, 1, 0), 0x08},
    {Vector3(0, 2, 0), 0x40},
    {Vector3(1, 2, 0), 0x20},
    {Vector3(2, 2, 0), 0x10}
};

static const int REGULAR_CELL_VOXELS[8][3] = {
    {0, 0, 0},
    {1, 0, 0},
    {0, 1, 0},
    {1, 1, 0},
    {0, 0, 1},
    {1, 0, 1},
    {0, 1, 1},
    {1, 1, 1}
};

static const Vector3 TRANSITION_HIGH_RES_FACE_GRID_DELTA[9] = {
    Vector3(0, 0, 0),
    Vector3(1, 0, 0),
    Vector3(2, 0, 0),
    Vector3(0, 1, 0),
    Vector3(1, 1, 0),
    Vector3(2, 1, 0),
    Vector3(0, 2, 0),
    Vector3(1, 2, 0),
    Vector3(2, 2, 0)
};

static const Vector2i TRANSITION_LOW_RES_FACE_GRID_DELTA[4] = {
    Vector2i(0, 0),
    Vector2i(1, 0),
    Vector2i(0, 1),
    Vector2i(1, 1)
};

static inline float interpolate_t(float a, float b, float threshold = 0.0f) {
    const float denom = b - a;
    if (std::fabs(denom) > 1.0e-6f) {
        return std::clamp((threshold - a) / denom, 0.0f, 1.0f);
    }
    return 0.5f;
}

static inline Vector3 lerp_vector3(const Vector3 &a, const Vector3 &b, float t) {
    return a + (b - a) * t;
}

static inline bool transvoxel_side_mask_enabled(int mask, TransvoxelSide side) {
    return (mask & (1 << static_cast<int>(side))) != 0;
}

static inline float sample_transvoxel_density(
      const PackedByteArray &heightmap_bytes,
      int image_width,
      int image_height,
      float map_size,
      float height_scale,
      const Vector3 &position,
      const Dictionary &excavation_masks,
      int chunk_stride
  ) {
      if (chunk_stride > 0 && !excavation_masks.is_empty()) {
          const float stride = float(chunk_stride);
          const int density_grid_size = chunk_stride + 1;
          const int chunk_x = int(Math::floor(position.x / stride));
          const int chunk_y = int(Math::floor(position.y / stride));
          const int chunk_z = int(Math::floor(position.z / stride));
          const Vector3i chunk_coord(chunk_x, chunk_y, chunk_z);
          const Variant mask_variant = excavation_masks.get(chunk_coord, Variant());
          if (mask_variant.get_type() == Variant::PACKED_BYTE_ARRAY) {
              const PackedByteArray mask = mask_variant;
              if (!mask.is_empty()) {
                  const int local_x = int(Math::round(position.x - float(chunk_x * chunk_stride)));
                  const int local_y = int(Math::round(position.y - float(chunk_y * chunk_stride)));
                  const int local_z = int(Math::round(position.z - float(chunk_z * chunk_stride)));
                  if (local_x >= 0 && local_x < density_grid_size && local_y >= 0 && local_y < density_grid_size && local_z >= 0 && local_z < density_grid_size) {
                      const int bit_index = local_x + (local_y * density_grid_size) + (local_z * density_grid_size * density_grid_size);
                      const int byte_index = bit_index >> 3;
                      if (byte_index >= 0 && byte_index < mask.size()) {
                          const uint8_t mask_byte = mask[byte_index];
                          if (((mask_byte >> (bit_index & 7)) & 1u) != 0u) {
                              return -10.0f;
                          }
                      }
                  }
              }
          }
      }
      const float terrain_height = sample_world_map_height_bilinear(
          heightmap_bytes,
          image_width,
          image_height,
          map_size,
        height_scale,
        position.x,
        position.z
    );
    return terrain_height - position.y;
}

static inline Vector3 make_regular_voxel_position(
    const Vector3 &block_base,
    const Vector3 &block_size,
    int subdivisions,
    int x,
    int y,
    int z
) {
    const float inv = 1.0f / float(std::max(1, subdivisions));
    return Vector3(
        block_base.x + block_size.x * (float(x) * inv),
        block_base.y + block_size.y * (float(y) * inv),
        block_base.z + block_size.z * (float(z) * inv)
    );
}

static inline Vector3 make_transition_regular_face_position(
    const Vector3 &block_base,
    const Vector3 &block_size,
    int subdivisions,
    const TransvoxelRotation &rotation,
    int cell_u,
    int cell_v,
    int face_u,
    int face_v
) {
    const float inv = 1.0f / float(std::max(1, subdivisions));
    const float u = float(cell_u + face_u) * inv;
    const float v = float(cell_v + face_v) * inv;
    return Vector3(
        block_base.x + block_size.x * float(rotation.uvw_base.x + rotation.u.x * u + rotation.v.x * v),
        block_base.y + block_size.y * float(rotation.uvw_base.y + rotation.u.y * u + rotation.v.y * v),
        block_base.z + block_size.z * float(rotation.uvw_base.z + rotation.u.z * u + rotation.v.z * v)
    );
}

static inline Vector3 make_transition_high_res_face_position(
    const Vector3 &block_base,
    const Vector3 &block_size,
    int subdivisions,
    const TransvoxelRotation &rotation,
    int cell_u,
    int cell_v,
    int delta_u,
    int delta_v,
    int delta_w
) {
    const float inv = 1.0f / float(std::max(1, subdivisions) * 2);
    const float u = float(2 * cell_u + delta_u);
    const float v = float(2 * cell_v + delta_v);
    const float w = float(delta_w);
    return Vector3(
        block_base.x + block_size.x * float(rotation.uvw_base.x + rotation.u.x * u * inv + rotation.v.x * v * inv + rotation.w.x * w * inv),
        block_base.y + block_size.y * float(rotation.uvw_base.y + rotation.u.y * u * inv + rotation.v.y * v * inv + rotation.w.y * w * inv),
        block_base.z + block_size.z * float(rotation.uvw_base.z + rotation.u.z * u * inv + rotation.v.z * v * inv + rotation.w.z * w * inv)
    );
}

static inline Vector3 make_transition_grid_point_position(
    const Vector3 &block_base,
    const Vector3 &block_size,
    int subdivisions,
    const TransvoxelRotation &rotation,
    int cell_u,
    int cell_v,
    int grid_point_index
) {
    if (grid_point_index < 9) {
        const Vector3 delta = TRANSITION_HIGH_RES_FACE_GRID_DELTA[grid_point_index];
        return make_transition_high_res_face_position(
            block_base,
            block_size,
            subdivisions,
            rotation,
            cell_u,
            cell_v,
            int(delta.x),
            int(delta.y),
            0
        );
    }

    const Vector2i delta = TRANSITION_LOW_RES_FACE_GRID_DELTA[grid_point_index - 9];
    return make_transition_regular_face_position(
        block_base,
        block_size,
        subdivisions,
        rotation,
        cell_u,
        cell_v,
        delta.x,
        delta.y
    );
}

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

        uvs.push_back(Vector2(0.0, 0.0));
        uvs.push_back(Vector2(0.0, v_len));
        uvs.push_back(Vector2(u_len, v_len));
        uvs.push_back(Vector2(u_len, 0.0));

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

static void add_greedy_block_faces_cpu(BuildingMeshBuffers &buffers, const PackedByteArray &voxels, int size_x, int size_y, int size_z, int x, int y, int z) {
    const uint8_t type = 1u;
    Vector3 pos = Vector3(x, y, z);

    auto emit_face_run_z = [&](const Vector3 &origin, const Vector3 &u_axis, const Vector3 &v_axis, const Vector3 &normal, float u_len) {
        buffers.add_quad(origin, u_axis, v_axis, u_len, 1.0f, normal);
    };

    if (has_face_type_3d(voxels, size_x, size_y, size_z, x, y, z, 1, 0, 0, type)) {
        if (!has_face_type_3d(voxels, size_x, size_y, size_z, x, y, z - 1, 1, 0, 0, type)) {
            float len = 1.0f;
            for (int k = 1; k < size_z - z; k++) {
                if (has_face_type_3d(voxels, size_x, size_y, size_z, x, y, z + k, 1, 0, 0, type)) {
                    len += 1.0f;
                } else {
                    break;
                }
            }
            emit_face_run_z(pos + Vector3(1, 1, 0), Vector3(0, 0, 1), Vector3(0, -1, 0), Vector3(1, 0, 0), len);
        }
    }

    if (has_face_type_3d(voxels, size_x, size_y, size_z, x, y, z, -1, 0, 0, type)) {
        if (!has_face_type_3d(voxels, size_x, size_y, size_z, x, y, z - 1, -1, 0, 0, type)) {
            float len = 1.0f;
            for (int k = 1; k < size_z - z; k++) {
                if (has_face_type_3d(voxels, size_x, size_y, size_z, x, y, z + k, -1, 0, 0, type)) {
                    len += 1.0f;
                } else {
                    break;
                }
            }
            emit_face_run_z(pos, Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(-1, 0, 0), len);
        }
    }

    if (has_face_type_3d(voxels, size_x, size_y, size_z, x, y, z, 0, 1, 0, type)) {
        if (!has_face_type_3d(voxels, size_x, size_y, size_z, x - 1, y, z, 0, 1, 0, type)) {
            float len = 1.0f;
            for (int k = 1; k < size_x - x; k++) {
                if (has_face_type_3d(voxels, size_x, size_y, size_z, x + k, y, z, 0, 1, 0, type)) {
                    len += 1.0f;
                } else {
                    break;
                }
            }
            emit_face_run_z(pos + Vector3(0, 1, 1), Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0), len);
        }
    }

    if (has_face_type_3d(voxels, size_x, size_y, size_z, x, y, z, 0, -1, 0, type)) {
        if (!has_face_type_3d(voxels, size_x, size_y, size_z, x - 1, y, z, 0, -1, 0, type)) {
            float len = 1.0f;
            for (int k = 1; k < size_x - x; k++) {
                if (has_face_type_3d(voxels, size_x, size_y, size_z, x + k, y, z, 0, -1, 0, type)) {
                    len += 1.0f;
                } else {
                    break;
                }
            }
            emit_face_run_z(pos, Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0), len);
        }
    }

    if (has_face_type_3d(voxels, size_x, size_y, size_z, x, y, z, 0, 0, 1, type)) {
        if (!has_face_type_3d(voxels, size_x, size_y, size_z, x - 1, y, z, 0, 0, 1, type)) {
            float len = 1.0f;
            for (int k = 1; k < size_x - x; k++) {
                if (has_face_type_3d(voxels, size_x, size_y, size_z, x + k, y, z, 0, 0, 1, type)) {
                    len += 1.0f;
                } else {
                    break;
                }
            }
            emit_face_run_z(pos + Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1), len);
        }
    }

    if (has_face_type_3d(voxels, size_x, size_y, size_z, x, y, z, 0, 0, -1, type)) {
        if (!has_face_type_3d(voxels, size_x, size_y, size_z, x - 1, y, z, 0, 0, -1, type)) {
            float len = 1.0f;
            for (int k = 1; k < size_x - x; k++) {
                if (has_face_type_3d(voxels, size_x, size_y, size_z, x + k, y, z, 0, 0, -1, type)) {
                    len += 1.0f;
                } else {
                    break;
                }
            }
            emit_face_run_z(pos + Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, -1), len);
        }
    }
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

	// Fast conversion methods and custom building mesher
    ClassDB::bind_method(D_METHOD("bytes_to_floats", "data"), &MeshBuilder::bytes_to_floats);
    ClassDB::bind_method(D_METHOD("build_building_mesh", "vertex_bytes", "normal_bytes", "uv_bytes", "index_bytes", "vertex_count", "index_count"), &MeshBuilder::build_building_mesh);
    ClassDB::bind_method(D_METHOD("build_building_mesh_from_voxels", "voxel_bytes", "voxel_meta", "use_box_collision", "chunk_size"), &MeshBuilder::build_building_mesh_from_voxels);
    ClassDB::bind_method(D_METHOD("pack_rotated_world_map_block_batches", "prefab_blocks", "rotation", "spawn_pos", "chunk_size"), &MeshBuilder::pack_rotated_world_map_block_batches);
    ClassDB::bind_method(D_METHOD("build_collision_boxes_from_voxels", "voxel_bytes", "chunk_size"), &MeshBuilder::build_collision_boxes_from_voxels);
    ClassDB::bind_method(D_METHOD("apply_world_map_collision_boxes", "body_rid", "collision_boxes"), &MeshBuilder::apply_world_map_collision_boxes);
    ClassDB::bind_method(D_METHOD("build_heightfield_mesh", "heights", "width", "depth", "cell_size", "skirt_depth"), &MeshBuilder::build_heightfield_mesh);
    UtilityFunctions::print("[MeshBuilder] binding build_transvoxel_heightfield_mesh");
    ClassDB::bind_method(D_METHOD("build_transvoxel_heightfield_mesh", "heightmap_bytes", "image_width", "image_height", "map_size", "height_scale", "block_base", "block_size", "subdivisions", "transition_sides_mask", "excavation_masks", "chunk_stride"), &MeshBuilder::build_transvoxel_heightfield_mesh, DEFVAL(Dictionary()), DEFVAL(0));
    UtilityFunctions::print("[MeshBuilder] bound build_transvoxel_heightfield_mesh");
    ClassDB::bind_method(D_METHOD("merge_heightfield_meshes", "mesh_specs"), &MeshBuilder::merge_heightfield_meshes);
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

                if (type != 1u) {
                    continue;
                }

                add_greedy_block_faces_cpu(buffers, voxel_bytes, chunk_size, chunk_size, chunk_size, x, y, z);
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

Ref<ArrayMesh> MeshBuilder::build_heightfield_mesh(const PackedFloat32Array& heights, int width, int depth, float cell_size, float skirt_depth) {
    Ref<ArrayMesh> mesh;

    if (width < 2 || depth < 2 || cell_size <= 0.0f) {
        return mesh;
    }

    const int expected = width * depth;
    if (heights.size() < expected) {
        return mesh;
    }

    PackedVector3Array vertices;
    PackedVector3Array normals;
    PackedVector2Array uvs;
    PackedInt32Array indices;

    vertices.resize(expected);
    normals.resize(expected);
    uvs.resize(expected);
    indices.resize((width - 1) * (depth - 1) * 6);

    const float *height_ptr = heights.ptr();
    Vector3 *vertex_ptr = vertices.ptrw();
    Vector3 *normal_ptr = normals.ptrw();
    Vector2 *uv_ptr = uvs.ptrw();
    int32_t *index_ptr = indices.ptrw();

    auto sample_height = [&](int x, int z) -> float {
        x = std::clamp(x, 0, width - 1);
        z = std::clamp(z, 0, depth - 1);
        return height_ptr[z * width + x];
    };

    auto compute_normal = [&](int x, int z) -> Vector3 {
        const float left = sample_height(x - 1, z);
        const float right = sample_height(x + 1, z);
        const float down = sample_height(x, z - 1);
        const float up = sample_height(x, z + 1);
        Vector3 normal(left - right, 2.0f * cell_size, down - up);
        return normal.normalized();
    };

    int v = 0;
    for (int z = 0; z < depth; ++z) {
        const float vz = static_cast<float>(z) * cell_size;
        const float uv_z = depth > 1 ? static_cast<float>(z) / static_cast<float>(depth - 1) : 0.0f;
        for (int x = 0; x < width; ++x) {
            const float vx = static_cast<float>(x) * cell_size;
            const float vy = height_ptr[z * width + x];
            const float uv_x = width > 1 ? static_cast<float>(x) / static_cast<float>(width - 1) : 0.0f;

            vertex_ptr[v] = Vector3(vx, vy, vz);
            normal_ptr[v] = compute_normal(x, z);
            uv_ptr[v] = Vector2(uv_x, uv_z);
            ++v;
        }
    }

    int i = 0;
    for (int z = 0; z < depth - 1; ++z) {
        for (int x = 0; x < width - 1; ++x) {
            const int top_left = z * width + x;
            const int top_right = top_left + 1;
            const int bottom_left = (z + 1) * width + x;
            const int bottom_right = bottom_left + 1;

            index_ptr[i++] = top_left;
            index_ptr[i++] = bottom_left;
            index_ptr[i++] = top_right;

            index_ptr[i++] = top_right;
            index_ptr[i++] = bottom_left;
            index_ptr[i++] = bottom_right;
        }
    }

    auto append_skirt_quad = [&](int top_a, int top_b, float dir_x, float dir_z) {
        const Vector3 top_a_pos = vertices[top_a];
        const Vector3 top_b_pos = vertices[top_b];
        const Vector3 bottom_a_pos = top_a_pos + Vector3(0.0, -skirt_depth, 0.0);
        const Vector3 bottom_b_pos = top_b_pos + Vector3(0.0, -skirt_depth, 0.0);
        const Vector3 skirt_normal = Vector3(dir_x, 0.0, dir_z).normalized();
        const int base = static_cast<int>(vertices.size());

        vertices.push_back(top_a_pos);
        vertices.push_back(bottom_a_pos);
        vertices.push_back(top_b_pos);
        vertices.push_back(bottom_b_pos);

        normals.push_back(skirt_normal);
        normals.push_back(skirt_normal);
        normals.push_back(skirt_normal);
        normals.push_back(skirt_normal);

        uvs.push_back(Vector2(0.0, 0.0));
        uvs.push_back(Vector2(0.0, 1.0));
        uvs.push_back(Vector2(1.0, 0.0));
        uvs.push_back(Vector2(1.0, 1.0));

        indices.push_back(base + 0);
        indices.push_back(base + 1);
        indices.push_back(base + 2);
        indices.push_back(base + 2);
        indices.push_back(base + 1);
        indices.push_back(base + 3);
    };

    if (skirt_depth > 0.0f) {
        for (int x = 0; x < width - 1; ++x) {
            append_skirt_quad(x, x + 1, 0.0, -1.0);
            const int south_row = (depth - 1) * width;
            append_skirt_quad(south_row + x + 1, south_row + x, 0.0, 1.0);
        }
        for (int z = 0; z < depth - 1; ++z) {
            append_skirt_quad(z * width, (z + 1) * width, -1.0, 0.0);
            append_skirt_quad(z * width + (width - 1), (z + 1) * width + (width - 1), 1.0, 0.0);
        }
    }

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = vertices;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_TEX_UV] = uvs;
    arrays[Mesh::ARRAY_INDEX] = indices;

    mesh.instantiate();
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    return mesh;
}

Ref<ArrayMesh> MeshBuilder::build_transvoxel_heightfield_mesh(
      const PackedByteArray& heightmap_bytes,
      int image_width,
      int image_height,
      float map_size,
      float height_scale,
      const Vector3& block_base,
      const Vector3& block_size,
      int subdivisions,
      int transition_sides_mask,
      const Dictionary& excavation_masks,
      int chunk_stride
  ) {
    Ref<ArrayMesh> mesh;

    if (heightmap_bytes.is_empty() || image_width < 2 || image_height < 2) {
        return mesh;
    }
    if (map_size <= 0.0f || height_scale <= 0.0f) {
        return mesh;
    }
    if (subdivisions < 1 || block_size.x <= 0.0f || block_size.y <= 0.0f || block_size.z <= 0.0f) {
        return mesh;
    }

    TransvoxelMeshBuffers buffers;
    const int estimated_cells = subdivisions * subdivisions * subdivisions;
    const size_t estimated_vertices = size_t(std::max(1024, estimated_cells * 12));
    const size_t estimated_indices = size_t(std::max(2048, estimated_cells * 18));
    buffers.reserve(estimated_vertices, estimated_indices);

      auto sample_density = [&](const Vector3& position) -> float {
          return sample_transvoxel_density(
              heightmap_bytes,
              image_width,
              image_height,
              map_size,
              height_scale,
              position,
              excavation_masks,
              chunk_stride
          );
      };

    auto append_regular_cell = [&](int cell_x, int cell_y, int cell_z) {
        TransvoxelSamplePoint points[8];
        for (int i = 0; i < 8; ++i) {
            const int vx = cell_x + REGULAR_CELL_VOXELS[i][0];
            const int vy = cell_y + REGULAR_CELL_VOXELS[i][1];
            const int vz = cell_z + REGULAR_CELL_VOXELS[i][2];
            points[i].position = make_regular_voxel_position(block_base, block_size, subdivisions, vx, vy, vz);
            points[i].density = sample_density(points[i].position);
        }

        int case_number = 0;
        for (int i = 0; i < 8; ++i) {
            if (points[i].density > 0.0f) {
                case_number |= (1 << i);
            }
        }

        const unsigned char cell_class = regularCellClass[case_number];
        const RegularCellData& triangulation_info = regularCellData[cell_class];
        const unsigned short* vertices_data = regularVertexData[case_number];
        const int vertex_count = triangulation_info.GetVertexCount();
        int local_vertex_indices[12] = {};

        for (int i = 0; i < vertex_count; ++i) {
            const uint16_t packed = vertices_data[i];
            const int voxel_a = (packed >> 4) & 0x0F;
            const int voxel_b = packed & 0x0F;
            const float t = interpolate_t(points[voxel_a].density, points[voxel_b].density, 0.0f);
            const Vector3 position = lerp_vector3(points[voxel_a].position, points[voxel_b].position, t);
            const Vector2 uv(
                (position.x - block_base.x) / block_size.x,
                (position.z - block_base.z) / block_size.z
            );
            local_vertex_indices[i] = buffers.append_vertex(position, uv);
        }

        const int triangle_count = triangulation_info.GetTriangleCount();
        for (int t = 0; t < triangle_count; ++t) {
            const int v1 = triangulation_info.vertexIndex[3 * t + 0];
            const int v2 = triangulation_info.vertexIndex[3 * t + 1];
            const int v3 = triangulation_info.vertexIndex[3 * t + 2];
            buffers.add_triangle(
                local_vertex_indices[v1],
                local_vertex_indices[v3],
                local_vertex_indices[v2]
            );
        }
    };

    auto append_transition_side = [&](TransvoxelSide side) {
        if (!transvoxel_side_mask_enabled(transition_sides_mask, side)) {
            return;
        }

        const TransvoxelRotation& rotation = transvoxel_rotation(side);
        for (int cell_u = 0; cell_u < subdivisions; ++cell_u) {
            for (int cell_v = 0; cell_v < subdivisions; ++cell_v) {
                TransvoxelSamplePoint points[13];
                for (int i = 0; i < 13; ++i) {
                    const Vector3 position = make_transition_grid_point_position(
                        block_base,
                        block_size,
                        subdivisions,
                        rotation,
                        cell_u,
                        cell_v,
                        i
                    );
                    points[i].position = position;
                    points[i].density = sample_density(position);
                }

                int case_number = 0;
                for (const auto& contribution : TRANSITION_HIGH_RES_FACE_CASE_CONTRIBUTIONS) {
                    const int du = int(contribution.position.x);
                    const int dv = int(contribution.position.y);
                    const int idx = dv * 3 + du;
                    if (points[idx].density > 0.0f) {
                        case_number += int(contribution.density);
                    }
                }

                const unsigned char raw_cell_class = transitionCellClass[case_number];
                const unsigned char cell_class = raw_cell_class & 0x7F;
                const bool invert_triangulation = (raw_cell_class & 0x80) != 0;
                const TransitionCellData& triangulation_info = transitionCellData[cell_class];
                const unsigned short* vertices_data = transitionVertexData[case_number];
                const int vertex_count = triangulation_info.GetVertexCount();
                int local_vertex_indices[12] = {};

                for (int i = 0; i < vertex_count; ++i) {
                    const uint16_t packed = vertices_data[i];
                    const int grid_a = (packed >> 4) & 0x0F;
                    const int grid_b = packed & 0x0F;
                    const float t = interpolate_t(points[grid_a].density, points[grid_b].density, 0.0f);
                    const Vector3 position = lerp_vector3(points[grid_a].position, points[grid_b].position, t);
                    const Vector2 uv(
                        (position.x - block_base.x) / block_size.x,
                        (position.z - block_base.z) / block_size.z
                    );
                    local_vertex_indices[i] = buffers.append_vertex(position, uv);
                }

                const int triangle_count = triangulation_info.GetTriangleCount();
                for (int t = 0; t < triangle_count; ++t) {
                    const int v1 = triangulation_info.vertexIndex[3 * t + 0];
                    const int v2 = triangulation_info.vertexIndex[3 * t + 1];
                    const int v3 = triangulation_info.vertexIndex[3 * t + 2];
                    if (invert_triangulation) {
                        buffers.add_triangle(
                            local_vertex_indices[v3],
                            local_vertex_indices[v1],
                            local_vertex_indices[v2]
                        );
                    } else {
                        buffers.add_triangle(
                            local_vertex_indices[v1],
                            local_vertex_indices[v3],
                            local_vertex_indices[v2]
                        );
                    }
                }
            }
        }
    };

    for (int cell_x = 0; cell_x < subdivisions; ++cell_x) {
        for (int cell_y = 0; cell_y < subdivisions; ++cell_y) {
            for (int cell_z = 0; cell_z < subdivisions; ++cell_z) {
                append_regular_cell(cell_x, cell_y, cell_z);
            }
        }
    }

    append_transition_side(TransvoxelSide::LowX);
    append_transition_side(TransvoxelSide::HighX);
    append_transition_side(TransvoxelSide::LowY);
    append_transition_side(TransvoxelSide::HighY);
    append_transition_side(TransvoxelSide::LowZ);
    append_transition_side(TransvoxelSide::HighZ);

    if (buffers.vertices.empty() || buffers.indices.empty()) {
        return mesh;
    }

    for (size_t i = 0; i < buffers.vertices.size(); ++i) {
        const Vector3 &position = buffers.vertices[i];
        buffers.normals[i] = sample_world_map_height_normal(
            heightmap_bytes,
            image_width,
            image_height,
            map_size,
            height_scale,
            position.x,
            position.z
        );
    }

    PackedVector3Array vertices;
    PackedVector3Array normals;
    PackedVector2Array uvs;
    PackedColorArray colors;
    PackedInt32Array indices;
    vertices.resize(buffers.vertices.size());
    normals.resize(buffers.normals.size());
    uvs.resize(buffers.uvs.size());
    colors.resize(buffers.colors.size());
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
    if (!buffers.colors.empty()) {
        std::copy(buffers.colors.begin(), buffers.colors.end(), colors.ptrw());
    }
    if (!buffers.indices.empty()) {
        std::copy(buffers.indices.begin(), buffers.indices.end(), indices.ptrw());
    }

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = vertices;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_TEX_UV] = uvs;
    arrays[Mesh::ARRAY_COLOR] = colors;
    arrays[Mesh::ARRAY_INDEX] = indices;

    mesh.instantiate();
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    return mesh;
}

Ref<ArrayMesh> MeshBuilder::merge_heightfield_meshes(const Array& mesh_specs) {
    Ref<ArrayMesh> merged_mesh;
    PackedVector3Array vertices;
    PackedVector3Array normals;
    PackedVector2Array uvs;
    PackedInt32Array indices;

    for (int i = 0; i < mesh_specs.size(); ++i) {
        Dictionary spec = mesh_specs[i];
        Ref<ArrayMesh> mesh = spec.get("mesh", Ref<ArrayMesh>());
        if (mesh.is_null() || mesh->get_surface_count() == 0) {
            continue;
        }

        const Vector3 offset = spec.get("offset", Vector3());
        Array arrays = mesh->surface_get_arrays(0);
        if (arrays.is_empty()) {
            continue;
        }

        PackedVector3Array mesh_vertices = arrays[Mesh::ARRAY_VERTEX];
        PackedVector3Array mesh_normals = arrays[Mesh::ARRAY_NORMAL];
        PackedVector2Array mesh_uvs = arrays[Mesh::ARRAY_TEX_UV];
        PackedInt32Array mesh_indices = arrays[Mesh::ARRAY_INDEX];

        if (mesh_vertices.is_empty() || mesh_indices.is_empty()) {
            continue;
        }

        const int base = vertices.size();
        for (int v = 0; v < mesh_vertices.size(); ++v) {
            vertices.push_back(mesh_vertices[v] + offset);
        }

        if (mesh_normals.size() == mesh_vertices.size()) {
            normals.append_array(mesh_normals);
        } else {
            for (int v = 0; v < mesh_vertices.size(); ++v) {
                normals.push_back(Vector3(0.0, 1.0, 0.0));
            }
        }

        if (mesh_uvs.size() == mesh_vertices.size()) {
            uvs.append_array(mesh_uvs);
        } else {
            for (int v = 0; v < mesh_vertices.size(); ++v) {
                uvs.push_back(Vector2());
            }
        }

        for (int idx = 0; idx < mesh_indices.size(); ++idx) {
            indices.push_back(mesh_indices[idx] + base);
        }
    }

    if (vertices.is_empty() || indices.is_empty()) {
        return merged_mesh;
    }

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = vertices;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_TEX_UV] = uvs;
    arrays[Mesh::ARRAY_INDEX] = indices;

    merged_mesh.instantiate();
    merged_mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    return merged_mesh;
}
