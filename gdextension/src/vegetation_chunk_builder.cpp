#include "vegetation_chunk_builder.h"

#include <algorithm>
#include <cmath>

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

namespace {

static inline float clamp01(float value) {
    return std::max(0.0f, std::min(1.0f, value));
}

static inline Color color_for_type(const Dictionary &type_colors, const StringName &type_id, float maturity) {
    Color base = type_colors.get(type_id, Color(0.25f, 0.44f, 0.16f, 1.0f));
    const float maturity_scale = 0.72f + (1.0f - 0.72f) * clamp01(maturity);
    return Color(base.r * maturity_scale, base.g * maturity_scale, base.b * maturity_scale, base.a);
}

} // namespace

void VegetationChunkBuilder::_bind_methods() {
    ClassDB::bind_method(D_METHOD("build_grass_card_mesh", "cells", "type_colors", "half_width", "height"), &VegetationChunkBuilder::build_grass_card_mesh);
    ClassDB::bind_method(D_METHOD("build_source_mesh_instances", "records", "source_arrays", "source_transform", "chunk_origin", "type_colors", "rotation_is_turns"), &VegetationChunkBuilder::build_source_mesh_instances);
}

VegetationChunkBuilder::VegetationChunkBuilder() {}

VegetationChunkBuilder::~VegetationChunkBuilder() {}

Dictionary VegetationChunkBuilder::build_grass_card_mesh(const Array &cells, const Dictionary &type_colors, float half_width, float height) {
    Dictionary result;
    result["visible_count"] = 0;
    result["primitive_count"] = 0;
    result["vertex_count"] = 0;

    if (cells.is_empty() || half_width <= 0.0f || height <= 0.0f) {
        return result;
    }

    int visible_count = 0;
    StringName first_type_id;
    for (int i = 0; i < cells.size(); ++i) {
        Dictionary cell = cells[i];
        if (static_cast<bool>(cell.get("harvested", false))) {
            continue;
        }
        ++visible_count;
        if (first_type_id == StringName()) {
            first_type_id = cell.get("type_id", StringName());
        }
    }

    if (visible_count <= 0) {
        return result;
    }

    const int vertex_count = visible_count * 4;
    const int index_count = visible_count * 6;

    PackedVector3Array vertices;
    PackedVector3Array normals;
    PackedVector2Array uvs;
    PackedColorArray colors;
    PackedInt32Array indices;

    vertices.resize(vertex_count);
    normals.resize(vertex_count);
    uvs.resize(vertex_count);
    colors.resize(vertex_count);
    indices.resize(index_count);

    Vector3 *vertex_ptr = vertices.ptrw();
    Vector3 *normal_ptr = normals.ptrw();
    Vector2 *uv_ptr = uvs.ptrw();
    Color *color_ptr = colors.ptrw();
    int32_t *index_ptr = indices.ptrw();

    int vertex_write = 0;
    int index_write = 0;
    bool has_bounds = false;
    Vector3 bounds_min;
    Vector3 bounds_max;

    for (int i = 0; i < cells.size(); ++i) {
        Dictionary cell = cells[i];
        if (static_cast<bool>(cell.get("harvested", false))) {
            continue;
        }

        const Vector3 local_position = cell.get("local_position", Vector3());
        const float rotation = static_cast<float>(cell.get("rotation", 0.0));
        const float scale = std::max(0.01f, static_cast<float>(cell.get("scale", 1.0)));
        const float maturity = static_cast<float>(cell.get("maturity", 1.0));
        const StringName type_id = cell.get("type_id", StringName());

        const float scaled_half_width = half_width * scale;
        const float scaled_height = height * scale;
        const Vector3 right(std::cos(rotation) * scaled_half_width, 0.0f, std::sin(rotation) * scaled_half_width);
        const Vector3 up(0.0f, scaled_height, 0.0f);
        const Vector3 p0 = local_position - right;
        const Vector3 p1 = local_position + right;
        const Vector3 p2 = local_position + right + up;
        const Vector3 p3 = local_position - right + up;
        Vector3 normal(-right.z, 0.0f, right.x);
        normal.normalize();
        if (normal.length_squared() <= 0.000001f) {
            normal = Vector3(0.0f, 0.0f, 1.0f);
        }
        const Color card_color = color_for_type(type_colors, type_id, maturity);
        const int start_index = vertex_write;

        vertex_ptr[vertex_write] = p0;
        normal_ptr[vertex_write] = normal;
        uv_ptr[vertex_write] = Vector2(0.0f, 1.0f);
        color_ptr[vertex_write] = card_color;
        ++vertex_write;

        vertex_ptr[vertex_write] = p1;
        normal_ptr[vertex_write] = normal;
        uv_ptr[vertex_write] = Vector2(1.0f, 1.0f);
        color_ptr[vertex_write] = card_color;
        ++vertex_write;

        vertex_ptr[vertex_write] = p2;
        normal_ptr[vertex_write] = normal;
        uv_ptr[vertex_write] = Vector2(1.0f, 0.0f);
        color_ptr[vertex_write] = card_color;
        ++vertex_write;

        vertex_ptr[vertex_write] = p3;
        normal_ptr[vertex_write] = normal;
        uv_ptr[vertex_write] = Vector2(0.0f, 0.0f);
        color_ptr[vertex_write] = card_color;
        ++vertex_write;

        index_ptr[index_write++] = start_index;
        index_ptr[index_write++] = start_index + 1;
        index_ptr[index_write++] = start_index + 2;
        index_ptr[index_write++] = start_index;
        index_ptr[index_write++] = start_index + 2;
        index_ptr[index_write++] = start_index + 3;

        const Vector3 points[4] = {p0, p1, p2, p3};
        for (const Vector3 &point : points) {
            if (!has_bounds) {
                bounds_min = point;
                bounds_max = point;
                has_bounds = true;
                continue;
            }
            bounds_min.x = std::min(bounds_min.x, point.x);
            bounds_min.y = std::min(bounds_min.y, point.y);
            bounds_min.z = std::min(bounds_min.z, point.z);
            bounds_max.x = std::max(bounds_max.x, point.x);
            bounds_max.y = std::max(bounds_max.y, point.y);
            bounds_max.z = std::max(bounds_max.z, point.z);
        }
    }

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = vertices;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_TEX_UV] = uvs;
    arrays[Mesh::ARRAY_COLOR] = colors;
    arrays[Mesh::ARRAY_INDEX] = indices;

    result["arrays"] = arrays;
    result["bounds"] = AABB(bounds_min, bounds_max - bounds_min);
    result["has_bounds"] = has_bounds;
    result["visible_count"] = visible_count;
    result["primitive_count"] = visible_count * 2;
    result["vertex_count"] = vertex_count;
    result["first_type_id"] = first_type_id;
    return result;
}

Dictionary VegetationChunkBuilder::build_source_mesh_instances(const Array &records, const Array &source_arrays, const Transform3D &source_transform, const Vector3 &chunk_origin, const Dictionary &type_colors, bool rotation_is_turns) {
    Dictionary result;
    result["visible_count"] = 0;
    result["primitive_count"] = 0;
    result["vertex_count"] = 0;

    if (records.is_empty() || source_arrays.size() <= Mesh::ARRAY_VERTEX) {
        return result;
    }

    const PackedVector3Array source_vertices = source_arrays[Mesh::ARRAY_VERTEX];
    if (source_vertices.is_empty()) {
        return result;
    }

    PackedVector3Array source_normals;
    PackedVector2Array source_uvs;
    PackedColorArray source_colors;
    PackedInt32Array source_indices;
    if (source_arrays.size() > Mesh::ARRAY_NORMAL) {
        source_normals = source_arrays[Mesh::ARRAY_NORMAL];
    }
    if (source_arrays.size() > Mesh::ARRAY_TEX_UV) {
        source_uvs = source_arrays[Mesh::ARRAY_TEX_UV];
    }
    if (source_arrays.size() > Mesh::ARRAY_COLOR) {
        source_colors = source_arrays[Mesh::ARRAY_COLOR];
    }
    if (source_arrays.size() > Mesh::ARRAY_INDEX) {
        source_indices = source_arrays[Mesh::ARRAY_INDEX];
    }

    const bool use_normals = source_normals.size() == source_vertices.size();
    const bool use_uvs = source_uvs.size() == source_vertices.size();
    const bool use_colors = source_colors.size() == source_vertices.size();
    const int source_vertex_count = source_vertices.size();
    const int source_index_count = source_indices.is_empty() ? source_vertex_count : source_indices.size();

    int visible_count = 0;
    StringName first_type_id;
    for (int i = 0; i < records.size(); ++i) {
        Dictionary record = records[i];
        if (static_cast<bool>(record.get("harvested", false))) {
            continue;
        }
        ++visible_count;
        if (first_type_id == StringName()) {
            first_type_id = record.get("type_id", StringName());
        }
    }
    if (visible_count <= 0) {
        return result;
    }

    const int total_vertices = visible_count * source_vertex_count;
    const int total_indices = visible_count * source_index_count;
    PackedVector3Array vertices;
    PackedVector3Array normals;
    PackedVector2Array uvs;
    PackedColorArray colors;
    PackedInt32Array indices;
    vertices.resize(total_vertices);
    normals.resize(total_vertices);
    uvs.resize(total_vertices);
    colors.resize(total_vertices);
    indices.resize(total_indices);

    Vector3 *vertex_ptr = vertices.ptrw();
    Vector3 *normal_ptr = normals.ptrw();
    Vector2 *uv_ptr = uvs.ptrw();
    Color *color_ptr = colors.ptrw();
    int32_t *index_ptr = indices.ptrw();
    const Vector3 *source_vertex_ptr = source_vertices.ptr();
    const Vector3 *source_normal_ptr = use_normals ? source_normals.ptr() : nullptr;
    const Vector2 *source_uv_ptr = use_uvs ? source_uvs.ptr() : nullptr;
    const Color *source_color_ptr = use_colors ? source_colors.ptr() : nullptr;
    const int32_t *source_index_ptr = source_indices.is_empty() ? nullptr : source_indices.ptr();

    int vertex_write = 0;
    int index_write = 0;
    bool has_bounds = false;
    Vector3 bounds_min;
    Vector3 bounds_max;
    constexpr double TAU_D = 6.28318530717958647692;

    for (int record_index = 0; record_index < records.size(); ++record_index) {
        Dictionary record = records[record_index];
        if (static_cast<bool>(record.get("harvested", false))) {
            continue;
        }

        Vector3 local_position;
        if (record.has("local_position")) {
            local_position = record.get("local_position", Vector3());
        } else {
            const Vector3 world_position = record.get("position", Vector3());
            local_position = world_position - chunk_origin;
        }
        double rotation = static_cast<double>(record.get("rotation", 0.0));
        if (rotation_is_turns) {
            rotation *= TAU_D;
        }
        const double scale = std::max(0.0001, static_cast<double>(record.get("scale", 1.0)));
        const float maturity = static_cast<float>(record.get("maturity", 1.0));
        const StringName type_id = record.get("type_id", StringName());
        const Color fallback_color = color_for_type(type_colors, type_id, maturity);

        Transform3D transform;
        transform = transform.rotated(Vector3(0.0, 1.0, 0.0), rotation);
        transform = transform.scaled(Vector3(scale, scale, scale));
        transform.origin = local_position;
        const Transform3D full_transform = transform * source_transform;
        const int vertex_offset = vertex_write;

        for (int i = 0; i < source_vertex_count; ++i) {
            const Vector3 transformed_vertex = full_transform.xform(source_vertex_ptr[i]);
            vertex_ptr[vertex_write] = transformed_vertex;
            normal_ptr[vertex_write] = source_normal_ptr ? source_normal_ptr[i] : Vector3(0.0, 1.0, 0.0);
            uv_ptr[vertex_write] = source_uv_ptr ? source_uv_ptr[i] : Vector2();
            color_ptr[vertex_write] = source_color_ptr ? source_color_ptr[i] : fallback_color;

            if (!has_bounds) {
                bounds_min = transformed_vertex;
                bounds_max = transformed_vertex;
                has_bounds = true;
            } else {
                bounds_min.x = std::min(bounds_min.x, transformed_vertex.x);
                bounds_min.y = std::min(bounds_min.y, transformed_vertex.y);
                bounds_min.z = std::min(bounds_min.z, transformed_vertex.z);
                bounds_max.x = std::max(bounds_max.x, transformed_vertex.x);
                bounds_max.y = std::max(bounds_max.y, transformed_vertex.y);
                bounds_max.z = std::max(bounds_max.z, transformed_vertex.z);
            }
            ++vertex_write;
        }

        if (source_index_ptr) {
            for (int i = 0; i < source_index_count; ++i) {
                index_ptr[index_write++] = vertex_offset + source_index_ptr[i];
            }
        } else {
            for (int i = 0; i < source_vertex_count; ++i) {
                index_ptr[index_write++] = vertex_offset + i;
            }
        }
    }

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = vertices;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_TEX_UV] = uvs;
    arrays[Mesh::ARRAY_COLOR] = colors;
    arrays[Mesh::ARRAY_INDEX] = indices;

    result["arrays"] = arrays;
    result["bounds"] = AABB(bounds_min, bounds_max - bounds_min);
    result["has_bounds"] = has_bounds;
    result["visible_count"] = visible_count;
    result["primitive_count"] = total_indices / 3;
    result["vertex_count"] = total_vertices;
    result["first_type_id"] = first_type_id;
    return result;
}

}
