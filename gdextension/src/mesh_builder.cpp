#include "mesh_builder.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

using namespace godot;

MeshBuilder::MeshBuilder() {
}

MeshBuilder::~MeshBuilder() {
}

void MeshBuilder::_bind_methods() {
    ClassDB::bind_method(D_METHOD("build_mesh_native", "data", "stride"), &MeshBuilder::build_mesh_native);
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
