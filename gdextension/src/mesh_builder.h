#ifndef MESH_BUILDER_H
#define MESH_BUILDER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

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
};

}

#endif
