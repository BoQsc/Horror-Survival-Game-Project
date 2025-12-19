#ifndef MESH_BUILDER_H
#define MESH_BUILDER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture3d.hpp>
#include <godot_cpp/classes/concave_polygon_shape3d.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

class MeshBuilder : public RefCounted {
    GDCLASS(MeshBuilder, RefCounted)

protected:
    static void _bind_methods();

public:
    MeshBuilder();
    ~MeshBuilder();

    // Native implementation of build_mesh
    // Expects: [pos.x, pos.y, pos.z, norm.x, norm.y, norm.z, col.r, col.g, col.b, ...]
    Ref<ArrayMesh> build_mesh_native(const PackedFloat32Array& data, int stride);

    // Native implementation of 3D texture creation
    // Converts raw density bytes directly to ImageTexture3D
    Ref<ImageTexture3D> create_material_texture(const PackedByteArray& data, int width, int height, int depth);

    // Native implementation of collision shape creation
    // Generates ConcavePolygonShape3D directly from raw vertex data
    Ref<ConcavePolygonShape3D> build_collision_shape(const PackedFloat32Array& data, int stride);
};

}

#endif
