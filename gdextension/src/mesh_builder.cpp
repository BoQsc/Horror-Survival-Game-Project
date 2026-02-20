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
    ClassDB::bind_method(D_METHOD("create_material_texture", "data", "width", "height", "depth"), &MeshBuilder::create_material_texture);
    ClassDB::bind_method(D_METHOD("build_collision_shape", "data", "stride"), &MeshBuilder::build_collision_shape);
	
	// Fast conversion methods and custom building mesher
	ClassDB::bind_method(D_METHOD("bytes_to_floats", "data"), &MeshBuilder::bytes_to_floats);
	ClassDB::bind_method(D_METHOD("build_building_mesh", "vertex_bytes", "normal_bytes", "uv_bytes", "index_bytes", "vertex_count", "index_count"), &MeshBuilder::build_building_mesh);
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
